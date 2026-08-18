# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret/openrouter"

# The SSE parser is deliberately transport-ignorant: it is fed raw chunks with
# boundaries wherever the network put them and yields one data payload per
# server-sent event. Comment lines (OpenRouter keep-alives) are noise.
class SSEParserTest < Minitest::Test
  def parse(*chunks)
    parser = Terret::OpenRouter::SSE::Parser.new
    out = []
    chunks.each { |c| parser.feed(c) { |data| out << data } }
    out
  end

  def test_yields_one_payload_per_event
    out = parse("data: {\"a\":1}\n\ndata: {\"b\":2}\n\n")
    assert_equal ['{"a":1}', '{"b":2}'], out
  end

  def test_reassembles_events_split_across_chunk_boundaries
    out = parse("data: {\"a\"", ":1}\n\nda", "ta: [DONE]\n\n")
    assert_equal ['{"a":1}', "[DONE]"], out
  end

  def test_ignores_comment_keepalives_and_other_fields
    out = parse(": OPENROUTER PROCESSING\n\nevent: ping\nid: 7\ndata: {\"a\":1}\n\n")
    assert_equal ['{"a":1}'], out
  end

  def test_tolerates_crlf_line_endings
    out = parse("data: {\"a\":1}\r\n\r\n")
    assert_equal ['{"a":1}'], out
  end

  def test_joins_multi_line_data_per_the_sse_spec
    out = parse("data: line1\ndata: line2\n\n")
    assert_equal ["line1\nline2"], out
  end

  def test_holds_an_unterminated_event_until_its_blank_line_arrives
    parser = Terret::OpenRouter::SSE::Parser.new
    out = []
    parser.feed("data: {\"a\":1}") { |d| out << d }
    assert_empty out
    parser.feed("\n\n") { |d| out << d }
    assert_equal ['{"a":1}'], out
  end
end

# Translation from the provider-neutral vocabulary to OpenRouter's
# OpenAI-compatible wire format, and back. Pure functions, no I/O.
class TranslateTest < Minitest::Test
  L = Terret::LLM

  def test_request_body_carries_model_system_stream_and_usage_accounting
    req = L::Request.new(model: "openai/gpt-5-mini", system: "Be terse.",
                         messages: [], tools: [])
    body = Terret::OpenRouter::Translate.request_body(req)

    assert_equal "openai/gpt-5-mini", body[:model]
    assert_equal({ role: "system", content: "Be terse." }, body[:messages].first)
    assert body[:stream]
    refute body.key?(:tools)
  end

  def test_request_body_omits_the_system_message_when_blank
    req = L::Request.new(model: "m", system: "", messages: [], tools: [])
    assert_empty Terret::OpenRouter::Translate.request_body(req)[:messages]
  end

  def test_full_tool_history_round_trips_to_wire_shape
    call = L::ToolCall.new(id: "tc1", name: "weather", args: { city: "CDMX" })
    req = L::Request.new(
      model: "m", system: nil, tools: [],
      messages: [
        L::Message.new(role: :user, parts: [L::Text.new(text: "Weather?")]),
        L::Message.new(role: :assistant, parts: [L::Text.new(text: "Checking."), call]),
        L::Message.new(role: :tool, parts: [
          L::ToolResult.new(id: "tc1", content: "22C", error: nil)
        ]),
        L::Message.new(role: :assistant, parts: [L::Text.new(text: "It is 22C.")])
      ]
    )

    messages = Terret::OpenRouter::Translate.request_body(req)[:messages]
    assert_equal(
      [
        { role: "user", content: "Weather?" },
        { role: "assistant", content: "Checking.",
          tool_calls: [{ id: "tc1", type: "function",
                         function: { name: "weather", arguments: '{"city":"CDMX"}' } }] },
        { role: "tool", tool_call_id: "tc1", content: "22C" },
        { role: "assistant", content: "It is 22C." }
      ], messages
    )
  end

  def test_tool_result_errors_are_shown_to_the_model_as_errors
    req = L::Request.new(
      model: "m", system: nil, tools: [],
      messages: [L::Message.new(role: :tool, parts: [
        L::ToolResult.new(id: "tc1", content: nil, error: "policy: denied")
      ])]
    )
    msg = Terret::OpenRouter::Translate.request_body(req)[:messages].first
    assert_equal "Error: policy: denied", msg[:content]
  end

  def test_tool_schemas_become_function_declarations
    schema = { name: "weather", description: "Weather lookup",
               parameters: { type: "object", properties: { city: { type: "string" } } } }
    req = L::Request.new(model: "m", system: nil, messages: [], tools: [schema])

    body = Terret::OpenRouter::Translate.request_body(req)
    assert_equal [{ type: "function", function: schema }], body[:tools]
  end
end

# The accumulator turns parsed streaming chunks into vocabulary StreamEvents
# and the final assistant Message. Pure, fed one chunk hash at a time.
class AccumulatorTest < Minitest::Test
  L = Terret::LLM

  def drive(chunks)
    acc = Terret::OpenRouter::Accumulator.new
    events = []
    chunks.each { |c| acc.feed(c) { |ev| events << ev } }
    message = acc.finalize { |ev| events << ev }
    [events, message, acc]
  end

  def delta(d, finish: nil) = { choices: [{ delta: d, finish_reason: finish }] }

  def test_text_deltas_stream_through_and_assemble_the_message
    events, message, = drive([
      delta({ role: "assistant", content: "Hel" }),
      delta({ content: "lo." }),
      delta({}, finish: "stop")
    ])

    assert_equal [L::TextDelta.new(text: "Hel"), L::TextDelta.new(text: "lo."),
                  L::MessageStop.new(stop_reason: :end_turn)], events
    assert_equal :assistant, message.role
    assert_equal "Hello.", message.text
  end

  def test_tool_calls_accumulate_across_argument_fragments
    events, message, = drive([
      delta({ content: "Checking." }),
      delta({ tool_calls: [{ index: 0, id: "tc1", type: "function",
                             function: { name: "weather", arguments: "" } }] }),
      delta({ tool_calls: [{ index: 0, function: { arguments: '{"city":' } }] }),
      delta({ tool_calls: [{ index: 0, function: { arguments: '"CDMX"}' } }] }),
      delta({}, finish: "tool_calls")
    ])

    call = events.grep(L::ToolCallEnd).first.tool_call
    assert_equal L::ToolCall.new(id: "tc1", name: "weather", args: { city: "CDMX" }), call
    assert_equal :tool_use, events.grep(L::MessageStop).first.stop_reason
    assert_equal [L::Text.new(text: "Checking."), call], message.parts
  end

  def test_parallel_tool_calls_are_kept_apart_by_index
    events, message, = drive([
      delta({ tool_calls: [{ index: 0, id: "tc1", function: { name: "weather", arguments: "{}" } },
                           { index: 1, id: "tc2", function: { name: "calendar", arguments: "" } }] }),
      delta({ tool_calls: [{ index: 1, function: { arguments: '{"day":"today"}' } }] }),
      delta({}, finish: "tool_calls")
    ])

    calls = events.grep(L::ToolCallEnd).map(&:tool_call)
    assert_equal %w[weather calendar], calls.map(&:name)
    assert_equal({}, calls[0].args)
    assert_equal({ day: "today" }, calls[1].args)
    assert_equal calls, message.tool_calls
  end

  def test_usage_chunks_become_usage_events
    events, = drive([
      delta({ content: "hi" }, finish: "stop"),
      { usage: { prompt_tokens: 12, completion_tokens: 3, total_tokens: 15, cost: 0.0001 },
        choices: [] }
    ])

    usage = events.grep(L::Usage).first
    assert_equal 12, usage.prompt_tokens
    assert_equal 3, usage.completion_tokens
    assert_in_delta 0.0001, usage.cost
  end

  def test_error_chunks_become_stream_errors_and_mark_the_accumulator
    events, _message, acc = drive([
      delta({ content: "partial" }),
      { error: { code: 502, message: "upstream fell over" }, choices: [] }
    ])

    err = events.grep(L::StreamError).first
    assert_equal "upstream fell over", err.message
    assert_equal 502, err.code
    assert acc.error
  end
end

# The adapter over an injected transport: request shaping, auth, retry on
# 429/5xx before bytes stream, hard errors through, SSE all the way down.
class AdapterTest < Minitest::Test
  L = Terret::LLM

  TOOL_TURN_SSE = <<~SSE
    : OPENROUTER PROCESSING

    data: {"choices":[{"delta":{"role":"assistant","content":"Checking."},"finish_reason":null}]}

    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"tc1","type":"function","function":{"name":"weather","arguments":"{\\"city\\":\\"CDMX\\"}"}}]},"finish_reason":null}]}

    data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":12,"completion_tokens":9,"cost":0.0001}}

    data: [DONE]

  SSE

  # Matches the real transport contract: the connection is only open for the
  # duration of the block, so status and chunks are yielded, not returned.
  FakeTransport = Struct.new(:responses, :requests) do
    def call(url:, headers:, body:)
      requests << { url: url, headers: headers, body: JSON.parse(body, symbolize_names: true) }
      response = responses.shift or raise "FakeTransport exhausted"
      yield response[0], response[1]
    end
  end

  def adapter(responses, api_key: "sk-or-test")
    transport = FakeTransport.new(responses, [])
    a = Terret::OpenRouter::Adapter.new(api_key: api_key, transport: transport,
                                        max_attempts: 3, sleeper: ->(_s) {})
    [a, transport]
  end

  def request
    L::Request.new(model: "openai/gpt-5-mini", system: "Be terse.",
                   messages: [L::Message.new(role: :user, parts: [L::Text.new(text: "Weather?")])],
                   tools: [])
  end

  def test_streams_a_tool_turn_and_returns_the_assistant_message
    a, transport = adapter([[200, [TOOL_TURN_SSE]]])
    events = []
    message = a.stream(request) { |ev| events << ev }

    assert_equal [L::TextDelta, L::Usage, L::ToolCallEnd, L::MessageStop], events.map(&:class)
    assert_equal :tool_use, events.last.stop_reason
    assert_equal "Checking.", message.text
    assert_equal({ city: "CDMX" }, message.tool_calls.first.args)

    sent = transport.requests.first
    assert_equal "https://openrouter.ai/api/v1/chat/completions", sent[:url]
    assert_equal "Bearer sk-or-test", sent[:headers]["Authorization"]
    assert_equal "application/json", sent[:headers]["Content-Type"]
    assert_equal "openai/gpt-5-mini", sent[:body][:model]
    assert sent[:body][:stream]
  end

  def test_attribution_headers_use_the_current_openrouter_names
    transport = FakeTransport.new(
      [[200, ["data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"]]], []
    )
    a = Terret::OpenRouter::Adapter.new(api_key: "sk-or-test", transport: transport,
                                        referer: "https://terret.org", title: "Terret")
    a.stream(request) { |_ev| }

    headers = transport.requests.first[:headers]
    assert_equal "https://terret.org", headers["HTTP-Referer"]
    # renamed upstream from the historic X-Title (openrouter.ai/docs/quickstart)
    assert_equal "Terret", headers["X-OpenRouter-Title"]
    refute headers.key?("X-Title")
  end

  def test_retries_on_429_then_succeeds
    a, transport = adapter([
      [429, ['{"error":{"message":"rate limited"}}']],
      [200, ["data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"]]
    ])
    message = a.stream(request) { |_ev| }

    assert_equal "hi", message.text
    assert_equal 2, transport.requests.length
  end

  def test_hard_http_errors_raise_without_retry
    a, transport = adapter([[401, ['{"error":{"message":"bad key"}}']]])
    err = assert_raises(L::AdapterError) { a.stream(request) { |_ev| } }

    assert_equal 401, err.status
    assert_match(/bad key/, err.message)
    assert_equal 1, transport.requests.length
  end

  def test_mid_stream_errors_surface_then_raise_without_retry
    body = "data: {\"choices\":[{\"delta\":{\"content\":\"par\"},\"finish_reason\":null}]}\n\n" \
           "data: {\"error\":{\"code\":502,\"message\":\"upstream fell over\"},\"choices\":[]}\n\n"
    a, transport = adapter([[200, [body]]])
    events = []
    err = assert_raises(L::AdapterError) { a.stream(request) { |ev| events << ev } }

    assert_match(/upstream fell over/, err.message)
    assert_equal 1, events.grep(L::StreamError).length
    assert_equal 1, transport.requests.length
  end

  def test_missing_api_key_raises_before_any_request
    a, transport = adapter([[200, [""]]], api_key: nil)
    ENV.delete("OPENROUTER_API_KEY")
    assert_raises(L::AdapterError) { a.stream(request) { |_ev| } }
    assert_empty transport.requests
  end
end

# The plugin form: a config row mounts the adapter into ctx.llm behind the
# "openrouter" provider name, reversibly. Plus the M2 acceptance shape: a
# multi-step tool turn through the whole stack over a canned wire.
class PluginTest < Minitest::Test
  STEP_ONE_SSE = <<~SSE
    data: {"choices":[{"delta":{"content":"Checking."},"finish_reason":null}]}

    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"tc1","type":"function","function":{"name":"weather","arguments":"{\\"city\\":\\"CDMX\\"}"}}]},"finish_reason":"tool_calls"}]}

    data: {"usage":{"prompt_tokens":10,"completion_tokens":8,"cost":0.0002},"choices":[]}

    data: [DONE]

  SSE

  STEP_TWO_SSE = <<~SSE
    data: {"choices":[{"delta":{"content":"It is 22C in CDMX."},"finish_reason":"stop"}]}

    data: [DONE]

  SSE

  def boot(transport)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service,
        config: { roles: { main: "openrouter/openai/gpt-5-mini" } } },
      { id: "loop",     plugin: Terret::Loop },
      { id: "openrouter", plugin: Terret::OpenRouter::Plugin,
        config: { api_key: "sk-or-test", transport: transport } }
    ])
    [loader.boot!, loader]
  end

  def test_config_row_mounts_the_adapter_and_unload_removes_it
    ctx, loader = boot(AdapterTest::FakeTransport.new([], []))
    adapter, model = ctx[:llm].resolve(:main)

    assert_kind_of Terret::OpenRouter::Adapter, adapter
    assert_equal "openai/gpt-5-mini", model

    loader.unload!("openrouter")
    assert_raises(KeyError) { ctx[:llm].resolve(:main) }
  end

  def test_a_multi_step_tool_turn_completes_through_the_whole_stack
    transport = AdapterTest::FakeTransport.new(
      [[200, [STEP_ONE_SSE]], [200, [STEP_TWO_SSE]]], []
    )
    ctx, = boot(transport)
    ctx.with_owner("weather-plugin") do
      ctx[:tools].register(name: "weather", description: "Weather lookup",
                           params: { type: "object", properties: { city: { type: "string" } } }) do |city:|
        "22C in #{city}"
      end
    end

    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    status = ctx[:loop].run_turn(agent, "Weather in CDMX?")

    assert_equal :completed, status
    chunkless = session.events.map(&:type).reject { |t| t == "assistant/chunk" }
    assert_equal %w[
      session/created
      turn/start
      step/start user/message assistant/message
      tool/call tool/result step/end
      step/start assistant/message step/end
      turn/end
    ], chunkless

    first_step_end = session.events.find { |e| e.type == "step/end" }
    assert_equal({ prompt_tokens: 10, completion_tokens: 8, cost: 0.0002 },
                 first_step_end.payload[:usage])

    second_request = transport.requests.last[:body]
    tool_msg = second_request[:messages].find { |m| m[:role] == "tool" }
    assert_equal "22C in CDMX", tool_msg[:content]
    assert_equal "tc1", tool_msg[:tool_call_id]
  end
end

# The default transport against a real socket: a loopback HTTP/1.1 server
# serving an SSE body. Skips only when async-http is not installed (the rest
# of this suite stays dependency-free by injecting fakes).
class AsyncTransportTest < Minitest::Test
  def setup
    begin
      require "async/http"
    rescue LoadError
      skip "async-http not installed"
    end
    require_relative "../lib/terret/openrouter/async_transport"
    require "socket"
  end

  def serve(*writes)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      sock = server.accept
      request = +""
      request << sock.readpartial(4096) until request.include?("\r\n\r\n")
      length = request[/content-length: (\d+)/i, 1].to_i
      body_read = request.split("\r\n\r\n", 2)[1].bytesize
      sock.read(length - body_read) if length > body_read
      writes.each { |w| sock.write(w) }
      sock.close
      server.close
      request
    end
    [port, thread]
  end

  def test_yields_status_and_streams_the_body_within_the_open_connection
    body = "data: {\"a\":1}\n\ndata: [DONE]\n\n"
    port, thread = serve(
      "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: #{body.bytesize}\r\n\r\n",
      body
    )

    transport = Terret::OpenRouter::AsyncTransport.new(timeout: 5)
    result = transport.call(
      url: "http://127.0.0.1:#{port}/api/v1/chat/completions",
      headers: { "Authorization" => "Bearer sk-or-test", "Content-Type" => "application/json" },
      body: "{}"
    ) { |status, chunks| [status, chunks.to_a.join] }

    assert_equal [200, body], result
    request = thread.value
    assert_match %r{\APOST /api/v1/chat/completions}, request
    assert_match(/authorization: Bearer sk-or-test/i, request)
  end

  def test_connection_failures_before_any_bytes_are_retryable
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close

    transport = Terret::OpenRouter::AsyncTransport.new(timeout: 2)
    assert_raises(Terret::LLM::RetryableError) do
      transport.call(url: "http://127.0.0.1:#{port}/x", headers: {}, body: "{}") { |_s, _c| }
    end
  end
end

# The live lane (plan §11): a real request through the default transport.
# Opt-in only — it spends money and needs the network.
#
#   TERRET_LIVE=1 OPENROUTER_API_KEY=... ruby gems/terret-openrouter/test/openrouter_test.rb
class LiveSmokeTest < Minitest::Test
  def test_a_real_model_completes_a_tool_turn
    unless ENV["TERRET_LIVE"] && ENV["OPENROUTER_API_KEY"]
      skip "live lane: set TERRET_LIVE=1 and OPENROUTER_API_KEY"
    end

    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service,
        config: { roles: { main: "openrouter/#{ENV.fetch('TERRET_MODEL', 'openai/gpt-5-mini')}" } } },
      { id: "loop",     plugin: Terret::Loop },
      { id: "openrouter", plugin: Terret::OpenRouter::Plugin, config: {} }
    ])
    ctx = loader.boot!
    ctx.with_owner("live-tools") do
      ctx[:tools].register(
        name: "weather", description: "Current weather for a city",
        params: { type: "object", properties: { city: { type: "string" } },
                  required: ["city"] }
      ) { |city:| "22C, clear skies in #{city}" }
      ctx[:prompt].register_section("identity", priority: 1) do
        "You are a terse assistant. Use the weather tool when asked about weather."
      end
    end

    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    status = ctx[:loop].run_turn(agent, "What's the weather in Mexico City right now?")

    assert_equal :completed, status
    types = session.events.map(&:type)
    assert_includes types, "tool/call"
    assert_includes types, "tool/result"
    final = session.events.reverse.find { |e| e.type == "assistant/message" }
    refute_empty Terret::LLM::Message.new(role: :assistant, parts: final.payload[:parts]).text
  end
end
