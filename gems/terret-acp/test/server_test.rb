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

  def boot(script:, extra_rows: [], max_agents: nil)
    Hames.reset_events!
    Terret.declare_events!

    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop",     plugin: Terret::Loop, config: max_agents ? { max_agents: max_agents } : {} },
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

    # Finding 9: this roots the server read loop as a CHILD of `task` (so the
    # test can drive frames concurrently), whereas Service#serve runs the read
    # loop in the top task itself. Both root turn tasks on the top task so they
    # outlive the read loop; the real serve topology is covered end to end by
    # terret-acp/test/cli_test.rb.
    def serve(ctx, task)
      @reader = task.async do
        while (line = @client_in.gets)
          @received << JSON.parse(line, symbolize_names: true)
        end
      rescue IOError
        nil # the test closed the read end (close_reader); stop collecting
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

    # The editor closes the end it reads from, so the server's next write hits a
    # broken pipe. Used to exercise the writer's SystemCallError rescue.
    def close_reader
      @client_in.close unless @client_in.closed?
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

  # -- the writer does not stall the shared event bus (blocking finding) ------

  # An output whose write parks forever, standing in for an editor that has
  # stopped reading. If project wrote through this directly (as it did before
  # the bounded-queue decoupling), it would park Sessions#fan_out's drainer and
  # stall every agent's session/event dispatch process-wide.
  class BlockingWriter
    attr_reader :entered

    def initialize
      @entered = false
      @released = false
      @held = Async::Notification.new
    end

    def write(_frame)
      @entered = true
      @held.wait until @released # parks every write until the test releases at teardown
    end

    def flush = nil

    def release
      @released = true
      @held.signal
    end
  end

  def test_a_withholding_editor_does_not_stall_another_sessions_stream
    ctx = boot(script: [{ text: "AAAAAAAAAAAAAAAA" }, { text: "BBBBBBBBBBBBBBBB" }])
    Sync do |task|
      # Session A: pre-created so we can drive it without reading its (blocked)
      # output; the server re-attaches to the live agent.
      a = ctx[:sessions].create
      ctx[:loop].spawn_agent(session_id: a.id)
      a_in_r, a_in_w = IO.pipe
      a_in_w.sync = true
      a_out = BlockingWriter.new
      server_a = Terret::ACP::Server.new(ctx: ctx, input: a_in_r, output: a_out, runner_task: task)
      task.async { server_a.run }

      # Session B: an ordinary duplex we read.
      dx_b = Duplex.new
      dx_b.serve(ctx, task)
      sid_b = new_session(dx_b, id: 1)

      # Wake A's turn; its first chunk parks A's writer (fix) — or, before the
      # fix, the whole event-bus drainer synchronously inside project.
      a_in_w.write("#{JSON.generate(jsonrpc: '2.0', id: 1, method: 'session/prompt',
                                    params: { sessionId: a.id,
                                              prompt: [{ type: 'text', text: 'go' }] })}\n")
      await { a_out.entered } # A is parked on its blocked pipe

      # The discriminating assertion: B's NOTIFICATIONS still flow. Before the
      # fix, A parks the drainer, so B's session/update events never dispatch
      # (its prompt response would still arrive from the turn task, but its
      # streamed chunks would not).
      dx_b.send(jsonrpc: "2.0", id: 2, method: "session/prompt",
                params: { sessionId: sid_b, prompt: [{ type: "text", text: "go" }] })
      await { dx_b.updates.any? { |u| u[:sessionUpdate] == "agent_message_chunk" } }
      await { dx_b.response(2) }
      assert_equal "end_turn", dx_b.response(2)[:result][:stopReason]
    ensure
      # A winds down gracefully: releasing the writer lets it drain, closing A's
      # input EOFs its read loop. Then tear down B, and stop any straggler.
      a_out&.release
      a_in_w&.close unless a_in_w&.closed?
      dx_b&.disconnect
      dx_b&.drain
      task.children.each(&:stop)
    end
  end

  # -- a turn outlives the editor disconnecting (test gap) -------------------

  def test_a_turn_completes_after_the_editor_disconnects
    ctx = boot(script: two_step_script)
    gate = Async::Queue.new
    register_weather(ctx) { |city:| gate.dequeue; "22C in #{city}" }
    sid = nil
    Sync do |task|
      dx = Duplex.new
      dx.serve(ctx, task)
      sid = new_session(dx)

      dx.send(jsonrpc: "2.0", id: 2, method: "session/prompt",
              params: { sessionId: sid, prompt: [{ type: "text", text: "weather?" }] })
      await { dx.update_kinds.include?("tool_call") } # parked in the tool

      # The editor vanishes: close its read end so the writer's next frame hits
      # a broken pipe (SystemCallError), then its write end so the read loop
      # reaches EOF. The turn — rooted off the read loop — must still finish.
      dx.close_reader
      dx.disconnect
      gate.enqueue(nil)

      await { ctx[:sessions].fetch(sid).events.any? { |e| e.type == "turn/end" } }
      task.children.each(&:stop)
    end

    turn_end = ctx[:sessions].fetch(sid).events.reverse_each.find { |e| e.type == "turn/end" }
    assert_equal "completed", turn_end.payload[:status], "the turn ran to completion despite the disconnect"
    agent = ctx[:loop].agent("agent-#{sid}")
    refute_nil agent, "the agent survives a disconnect"
    refute_equal :done, agent.status
  end

  # -- a second in-flight prompt is refused (test gap) -----------------------

  def test_a_second_prompt_while_one_is_in_flight_is_refused
    ctx = boot(script: two_step_script)
    gate = Async::Queue.new
    register_weather(ctx) { |city:| gate.dequeue; "22C in #{city}" }
    Sync do |task|
      dx = Duplex.new
      dx.serve(ctx, task)
      sid = new_session(dx)

      dx.send(jsonrpc: "2.0", id: 2, method: "session/prompt",
              params: { sessionId: sid, prompt: [{ type: "text", text: "weather?" }] })
      await { dx.update_kinds.include?("tool_call") } # first turn underway

      dx.send(jsonrpc: "2.0", id: 3, method: "session/prompt",
              params: { sessionId: sid, prompt: [{ type: "text", text: "again?" }] })
      await { dx.response(3) }
      assert_equal(-32600, dx.response(3)[:error][:code], "a prompt already in flight is refused")

      gate.enqueue(nil)
      await { dx.response(2) }
      assert_equal "end_turn", dx.response(2)[:result][:stopReason], "the first prompt still completes"
      dx.disconnect
      dx.drain
    end
  end

  # -- an empty prompt is invalid params (test gap for finding 5) -------------

  def test_a_prompt_with_no_actionable_content_is_invalid_params
    ctx = boot(script: [])
    Sync do |task|
      dx = Duplex.new
      dx.serve(ctx, task)
      sid = new_session(dx)

      # A non-empty prompt whose only block is a type we do not handle renders
      # to no text — invalid params, not an empty turn.
      dx.send(jsonrpc: "2.0", id: 2, method: "session/prompt",
              params: { sessionId: sid, prompt: [{ type: "image", data: "…" }] })
      await { dx.response(2) }
      assert_equal(-32602, dx.response(2)[:error][:code])
      dx.disconnect
      dx.drain
    end
  end

  # -- session/new past the cap leaks no durable session (finding 2) ----------

  def test_session_new_past_the_agent_cap_leaks_no_durable_session
    ctx = boot(script: [], max_agents: 1)
    Sync do |task|
      dx = Duplex.new
      dx.serve(ctx, task)
      new_session(dx, id: 1) # fills the single-agent cap

      dx.send(jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/w", mcpServers: [] })
      await { dx.response(2) }
      assert_equal(-32603, dx.response(2)[:error][:code], "the second session/new is refused past the cap")

      # The refusal spawns before it creates, so it left no orphaned durable
      # session — exactly the one from the first session/new exists.
      assert_equal 1, ctx[:sessions].session_ids.length
      dx.disconnect
      dx.drain
    end
  end

  # -- resume/reattach synthesizes the opening tool_call (findings 3 + 8) -----

  # Stage the log of a turn that died mid-tool: opened, one step, a model reply
  # owing a weather call, its tool/call durable, no result. That is what a
  # process death leaves behind and what resumable? recognizes.
  def stage_open_turn(ctx)
    session = ctx[:sessions].create
    sid = session.id
    ctx[:sessions].append(sid, "turn/start", { agent: "agent-#{sid}" })
    ctx[:sessions].append(sid, "step/start", { n: 1 })
    ctx[:sessions].append(sid, "user/message", { text: "weather?" })
    ctx[:sessions].append(sid, "assistant/message",
                          { parts: [Terret::LLM.encode_part(WEATHER_CALL.call)] })
    ctx[:sessions].append(sid, "tool/call", { id: "tc1", name: "weather", args: { city: "CDMX" } })
    ctx[:loop].spawn_agent(session_id: sid)
    sid
  end

  def test_resume_reattach_synthesizes_a_tool_call_before_its_update
    ctx = boot(script: [{ text: "It is 22C in CDMX." }]) # the step after the owed tool completes
    register_weather(ctx)
    sid = stage_open_turn(ctx)
    Sync do |task|
      dx = Duplex.new
      dx.serve(ctx, task)

      # A prompt against the reattached session resumes its open turn.
      dx.send(jsonrpc: "2.0", id: 1, method: "session/prompt",
              params: { sessionId: sid, prompt: [{ type: "text", text: "still there?" }] })
      await { dx.response(1) }
      assert_equal "end_turn", dx.response(1)[:result][:stopReason]

      # The tool/call was durable before this connection existed, so this editor
      # never received its tool_call — the server must synthesize one (pending)
      # ahead of the tool_call_update, or the editor gets an update for an id it
      # never saw opened.
      kinds = dx.update_kinds
      call = kinds.index("tool_call")
      update = kinds.index("tool_call_update")
      refute_nil call, "a tool_call was synthesized for the reattached editor"
      assert call < update, "the synthesized tool_call precedes its update"

      tool_call = dx.updates.find { |u| u[:sessionUpdate] == "tool_call" }
      assert_equal "tc1", tool_call[:toolCallId]
      assert_equal "weather", tool_call[:title], "the tool name is read from the log"
      assert_equal "other", tool_call[:kind]

      done = dx.updates.find { |u| u[:sessionUpdate] == "tool_call_update" }
      assert_equal "tc1", done[:toolCallId]
      assert_equal "completed", done[:status]
      dx.disconnect
      dx.drain
    end
  end
end
