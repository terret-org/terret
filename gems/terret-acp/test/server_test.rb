# frozen_string_literal: true

require "minitest/autorun"
require "json"

# The protocol engine needs the async gem (the read loop parks the fiber, turn
# tasks root on the reactor). Follow the ws/openrouter convention: skip the
# whole suite when it is absent.
ASYNC_AVAILABLE = begin
  require "async"
  require "async/queue"
  true
rescue LoadError
  false
end

require_relative "../lib/terret/acp" if ASYNC_AVAILABLE

# The ACP server over an in-memory IO.pipe duplex, with the test as the editor.
# The whole proof is here (docs/acp.md): the handshake, session/new spawning a
# durable agent, a prompt that pends the whole turn while session/update
# notifications stream, cancel landing on Agent#cancel, and the failure modes
# an editor can provoke never taking the read loop down.
class ServerTest < Minitest::Test
  def setup
    skip "async not installed" unless ASYNC_AVAILABLE
  end

  # -- harness ---------------------------------------------------------------

  def boot(script:, extra_rows: [])
    Hames.reset_events!
    Terret.declare_events!

    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop",     plugin: Terret::Loop },
      { id: "acp",      plugin: Terret::ACP::Service },
      *extra_rows
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))
    ctx
  end

  WEATHER_CALL = -> { Terret::LLM::ToolCall.new(id: "tc1", name: "weather", args: { city: "CDMX" }) }

  def two_step_script
    [
      { text: "Checking the weather.", tool_calls: [WEATHER_CALL.call] },
      { text: "It is 22C in CDMX." }
    ]
  end

  def register_weather(ctx, &handler)
    handler ||= ->(city:) { "22C in #{city}" }
    ctx.with_owner("weather-plugin") do
      ctx[:tools].register(name: "weather", description: "Weather lookup",
                           params: { city: "string" }, &handler)
    end
  end

  # An in-memory duplex of two real pipes: the client writes frames the server
  # reads (client_out -> server_in), and the server writes frames a reader task
  # collects (server_out -> client_in). Under the async scheduler both gets
  # calls park the fiber, so this is one reactor with the test on one end.
  class Duplex
    attr_reader :received

    def initialize
      @server_in, @client_out = IO.pipe
      @client_in, @server_out = IO.pipe
      [@client_out, @server_out].each { |io| io.sync = true }
      @received = []
    end

    def serve(ctx, task)
      @reader = task.async do
        while (line = @client_in.gets)
          @received << JSON.parse(line, symbolize_names: true)
        end
      end
      @server = task.async do
        Terret::ACP::Server.new(ctx: ctx, input: @server_in, output: @server_out,
                                runner_task: task).run
      end
    end

    def send(hash) = @client_out.write("#{JSON.generate(hash)}\n")
    def send_raw(line) = @client_out.write(line)

    # The editor disconnects: closing the write end EOFs the server read loop.
    def disconnect
      @client_out.close unless @client_out.closed?
    end

    # After a disconnect, let the server finish, then EOF the reader so the
    # enclosing Sync block can return.
    def drain
      @server&.wait
      @server_out.close unless @server_out.closed?
      @reader&.wait
      [@client_in, @server_in].each { |io| io.close unless io.closed? }
    end

    # -- assertion helpers --
    def response(id) = @received.find { |f| f[:id] == id && (f.key?(:result) || f.key?(:error)) }
    def updates = @received.select { |f| f[:method] == "session/update" }.map { |f| f[:params][:update] }
    def update_kinds = updates.map { |u| u[:sessionUpdate] }
  end

  # Bounded wait: poll the observable outcome. On timeout, stop the task's
  # children so a failing await fails the test rather than hanging the process.
  def await(timeout = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Async::Task.current.children&.each(&:stop)
        raise "await timed out"
      end

      sleep 0.002
    end
  end

  def new_session(dx, id: 1, cwd: "/work")
    dx.send(jsonrpc: "2.0", id: id, method: "session/new", params: { cwd: cwd, mcpServers: [] })
    await { dx.response(id) }
    dx.response(id)[:result][:sessionId]
  end

  # -- pure mappings (docs/acp.md, "Resolved in Task 7") ---------------------

  def server_for_mapping
    Terret::ACP::Server.allocate
  end

  def test_stop_reason_maps_every_turn_status
    s = server_for_mapping
    assert_equal "end_turn", s.send(:stop_reason, :completed)
    assert_equal "end_turn", s.send(:stop_reason, :empty)
    assert_equal "cancelled", s.send(:stop_reason, :cancelled)
    assert_equal "refusal", s.send(:stop_reason, :rejected)
    assert_nil s.send(:stop_reason, :failed), "a failed turn answers a -32603 error, not a stop reason"
  end

  def test_tool_kind_maps_the_std_roster_and_falls_to_other
    s = server_for_mapping
    assert_equal "read", s.send(:tool_kind, "Read")
    assert_equal "search", s.send(:tool_kind, "Grep")
    assert_equal "edit", s.send(:tool_kind, "Write")
    assert_equal "execute", s.send(:tool_kind, "Bash")
    assert_equal "execute", s.send(:tool_kind, "terminal_open")
    assert_equal "fetch", s.send(:tool_kind, "WebFetch")
    assert_equal "other", s.send(:tool_kind, "Task")
    assert_equal "other", s.send(:tool_kind, "mcp__files__search")
  end

  # -- handshake -------------------------------------------------------------

  def test_initialize_echoes_protocol_version_capabilities_and_no_auth
    ctx = boot(script: [])
    Sync do |task|
      dx = Duplex.new
      dx.serve(ctx, task)
      dx.send(jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 })
      await { dx.response(1) }

      result = dx.response(1)[:result]
      assert_equal 1, result[:protocolVersion]
      assert_equal({}, result[:agentCapabilities])
      assert_equal [], result[:authMethods]
      dx.disconnect
      dx.drain
    end
  end

  def test_session_new_spawns_a_durable_agent_and_answers_a_session_id
    ctx = boot(script: [])
    Sync do |task|
      dx = Duplex.new
      dx.serve(ctx, task)
      sid = new_session(dx)

      assert_includes ctx[:sessions].session_ids, sid
      refute_nil ctx[:loop].agent("agent-#{sid}"), "session/new spawns an agent keyed agent-<sid>"
      dx.disconnect
      dx.drain
    end
  end

  def test_session_new_requires_cwd_and_mcp_servers
    ctx = boot(script: [])
    Sync do |task|
      dx = Duplex.new
      dx.serve(ctx, task)
      dx.send(jsonrpc: "2.0", id: 1, method: "session/new", params: { mcpServers: [] })
      dx.send(jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/work" })
      await { dx.response(1) && dx.response(2) }

      assert_equal(-32602, dx.response(1)[:error][:code], "a missing cwd is invalid params")
      assert_equal(-32602, dx.response(2)[:error][:code], "a missing mcpServers is invalid params")
      dx.disconnect
      dx.drain
    end
  end

  # -- session/prompt --------------------------------------------------------

  def test_a_prompt_streams_updates_in_order_then_answers_end_turn
    ctx = boot(script: two_step_script)
    register_weather(ctx)
    Sync do |task|
      dx = Duplex.new
      dx.serve(ctx, task)
      sid = new_session(dx)

      dx.send(jsonrpc: "2.0", id: 2, method: "session/prompt",
              params: { sessionId: sid, prompt: [{ type: "text", text: "weather in CDMX?" }] })
      await { dx.response(2) }

      # The pending prompt answers end_turn once the whole turn closed.
      assert_equal "end_turn", dx.response(2)[:result][:stopReason]

      # agent_message_chunk before the tool_call, then tool_call before its
      # update, then the second step's chunk — the turn's order, projected.
      kinds = dx.update_kinds
      first_chunk = kinds.index("agent_message_chunk")
      call = kinds.index("tool_call")
      done = kinds.index("tool_call_update")
      assert first_chunk < call, "assistant text streams before the tool call"
      assert call < done, "a tool_call opens before its tool_call_update closes it"

      tool_call = dx.updates.find { |u| u[:sessionUpdate] == "tool_call" }
      assert_equal "tc1", tool_call[:toolCallId]
      assert_equal "weather", tool_call[:title]
      assert_equal "other", tool_call[:kind]
      assert_equal "pending", tool_call[:status]

      update = dx.updates.find { |u| u[:sessionUpdate] == "tool_call_update" }
      assert_equal "tc1", update[:toolCallId]
      assert_equal "completed", update[:status]
      assert_equal "22C in CDMX", update[:content].first[:content][:text]

      # the assistant text reassembles from its chunks
      text = dx.updates.select { |u| u[:sessionUpdate] == "agent_message_chunk" }
                       .map { |u| u[:content][:text] }.join
      assert_equal "Checking the weather.It is 22C in CDMX.", text
      dx.disconnect
      dx.drain
    end
  end

  def test_the_prompt_stays_pending_until_the_turn_ends
    ctx = boot(script: two_step_script)
    gate = Async::Queue.new
    register_weather(ctx) { |city:| gate.dequeue; "22C in #{city}" }
    Sync do |task|
      dx = Duplex.new
      dx.serve(ctx, task)
      sid = new_session(dx)

      dx.send(jsonrpc: "2.0", id: 2, method: "session/prompt",
              params: { sessionId: sid, prompt: [{ type: "text", text: "weather?" }] })
      await { dx.update_kinds.include?("tool_call") } # turn is underway, parked in the tool
      assert_nil dx.response(2), "the prompt must not answer while the turn is still running"

      gate.enqueue(nil)
      await { dx.response(2) }
      assert_equal "end_turn", dx.response(2)[:result][:stopReason]
      dx.disconnect
      dx.drain
    end
  end

  def test_a_failed_turn_answers_a_jsonrpc_error_not_a_stop_reason
    # Step 1 calls a tool; the script has no step 2, so the follow-up model
    # request exhausts the FakeAdapter and the turn raises.
    ctx = boot(script: [{ text: "one", tool_calls: [WEATHER_CALL.call] }])
    register_weather(ctx)
    Sync do |task|
      dx = Duplex.new
      dx.serve(ctx, task)
      sid = new_session(dx)

      dx.send(jsonrpc: "2.0", id: 2, method: "session/prompt",
              params: { sessionId: sid, prompt: [{ type: "text", text: "go" }] })
      await { dx.response(2) }

      assert_equal(-32603, dx.response(2)[:error][:code])
      dx.disconnect
      dx.drain
    end
  end

  # -- session/cancel --------------------------------------------------------

  def test_cancel_mid_turn_ends_the_turn_and_answers_cancelled
    ctx = boot(script: two_step_script)
    gate = Async::Queue.new
    register_weather(ctx) { |city:| gate.dequeue; "22C in #{city}" }
    Sync do |task|
      dx = Duplex.new
      dx.serve(ctx, task)
      sid = new_session(dx)
      agent = ctx[:loop].agent("agent-#{sid}")

      dx.send(jsonrpc: "2.0", id: 2, method: "session/prompt",
              params: { sessionId: sid, prompt: [{ type: "text", text: "weather?" }] })
      await { dx.update_kinds.include?("tool_call") } # parked in the tool

      dx.send(jsonrpc: "2.0", method: "session/cancel", params: { sessionId: sid })
      await { agent.cancelled? } # the notification landed on Agent#cancel
      gate.enqueue(nil) # let the parked tool finish; the boundary honors the cancel

      await { dx.response(2) }
      assert_equal "cancelled", dx.response(2)[:result][:stopReason]
      dx.disconnect
      dx.drain
    end
  end

  def test_cancel_request_cancels_the_pending_prompt
    ctx = boot(script: two_step_script)
    gate = Async::Queue.new
    register_weather(ctx) { |city:| gate.dequeue; "22C in #{city}" }
    Sync do |task|
      dx = Duplex.new
      dx.serve(ctx, task)
      sid = new_session(dx)
      agent = ctx[:loop].agent("agent-#{sid}")

      dx.send(jsonrpc: "2.0", id: 42, method: "session/prompt",
              params: { sessionId: sid, prompt: [{ type: "text", text: "weather?" }] })
      await { dx.update_kinds.include?("tool_call") }

      dx.send(jsonrpc: "2.0", method: "$/cancel_request", params: { requestId: 42 })
      await { agent.cancelled? }
      gate.enqueue(nil)

      await { dx.response(42) }
      assert_equal "cancelled", dx.response(42)[:result][:stopReason]
      dx.disconnect
      dx.drain
    end
  end

  # -- failure modes ---------------------------------------------------------

  def test_a_malformed_request_answers_an_error_and_the_loop_survives
    ctx = boot(script: [])
    Sync do |task|
      dx = Duplex.new
      dx.serve(ctx, task)
      dx.send_raw("{ this is not json\n")
      await { dx.received.any? { |f| f.dig(:error, :code) == -32700 } }

      # the loop read on: a well-formed request after the garbage still answers
      dx.send(jsonrpc: "2.0", id: 9, method: "initialize", params: { protocolVersion: 1 })
      await { dx.response(9) }
      assert_equal 1, dx.response(9)[:result][:protocolVersion]
      dx.disconnect
      dx.drain
    end
  end

  def test_an_unknown_method_answers_method_not_found
    ctx = boot(script: [])
    Sync do |task|
      dx = Duplex.new
      dx.serve(ctx, task)
      dx.send(jsonrpc: "2.0", id: 3, method: "session/load", params: {})
      await { dx.response(3) }

      assert_equal(-32601, dx.response(3)[:error][:code])
      dx.disconnect
      dx.drain
    end
  end

  def test_disconnect_leaves_the_agent_parked_not_disposed
    ctx = boot(script: [])
    sid = nil
    Sync do |task|
      dx = Duplex.new
      dx.serve(ctx, task)
      sid = new_session(dx)
      dx.disconnect
      dx.drain
    end

    agent = ctx[:loop].agent("agent-#{sid}")
    refute_nil agent, "a disconnect must not dispose the agent (docs/acp.md, M6 lifecycle)"
    refute_equal :done, agent.status, "the agent is parked, not torn down"
  end
end
