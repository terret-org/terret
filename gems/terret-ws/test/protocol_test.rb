# frozen_string_literal: true

require "minitest/autorun"
require "json"

# The protocol engine needs the async gem (bounded-queue wakeups, tasks).
# Follow the openrouter convention: skip the whole suite when it is absent.
ASYNC_AVAILABLE = begin
  require "async"
  require "async/queue"
  true
rescue LoadError
  false
end

require_relative "../lib/terret/ws" if ASYNC_AVAILABLE
require_relative "../../terret-mcp/lib/terret/mcp" if ASYNC_AVAILABLE

class ProtocolTest < Minitest::Test
  def setup
    skip "async not installed" unless ASYNC_AVAILABLE
  end

  # -- harness ---------------------------------------------------------------

  def boot(script:, extra_rows: [], store: Terret::Store::Memory)
    Hames.reset_events!
    Terret.declare_events!

    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: store },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop",     plugin: Terret::Loop },
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

  # In-memory stand-in for a websocket: the test is the client.
  class FakeSocket
    attr_reader :written

    def initialize
      @in = Async::Queue.new
      @written = []
      @closed = false
    end

    def client_send(hash) = @in.enqueue(JSON.generate(hash))
    def client_close = @in.enqueue(nil)

    # -- Connection's io contract --
    def read = @closed ? nil : @in.dequeue
    def write(text) = @written << JSON.parse(text, symbolize_names: true)

    def close(*)
      return if @closed

      @closed = true
      @in.enqueue(nil)
    end

    def closed? = @closed

    # -- assertion helpers --
    def events = @written.select { |f| f.key?(:seq) }
    def event_types(chunkless: true)
      t = events.map { |f| f[:type] }
      chunkless ? t.reject { |x| x == "assistant/chunk" } : t
    end
    def protocol_frames = @written.reject { |f| f.key?(:seq) }
  end

  # Terret::Store::Memory#read never yields, so the shipped tests never
  # actually exercise handle_subscribe's buffer-while-replaying branch
  # concurrently -- `buffered` is always empty at flush time. This forces a
  # real fiber yield mid-replay-read (as a JSONL/SQLite backend genuinely
  # would). Signaling exactly when the read begins -- rather than just
  # sleeping and hoping a concurrent task lands inside the window -- is what
  # makes the race deterministic: `task.async` runs its block immediately up
  # to its first yield, so an unsignaled append would complete before the
  # reader fiber is even scheduled to dispatch the subscribe frame.
  class SlowStore < Terret::Store::Memory
    class << self
      attr_accessor :reading_notification
    end

    def read(session_id, from_seq: 0)
      self.class.reading_notification&.signal
      sleep 0.01
      super
    end
  end

  # Turn tasks hang off the given task (the test root), never the connection —
  # exactly how Service#attach roots them on the server.
  def runner(ctx, root)
    ->(agent, text) { root.async { ctx[:loop].run_turn(agent, text) } }
  end

  def resumer(ctx, root)
    ->(agent) { root.async { ctx[:loop].resume_turn(agent) } }
  end

  def connect(ctx, agent, root, queue_limit: 256)
    sock = FakeSocket.new
    conn = Terret::WS::Connection.new(ctx: ctx, agent: agent, io: sock,
                                      runner: runner(ctx, root), resumer: resumer(ctx, root),
                                      queue_limit: queue_limit)
    conn_task = root.async { conn.run }
    [sock, conn, conn_task]
  end

  APPROVALS_ROW = { id: "approvals", plugin: Terret::Tools::Approvals }.freeze

  DEPLOY_CALL = -> { Terret::LLM::ToolCall.new(id: "tc7", name: "deploy", args: { env: "prod" }) }

  def register_deploy(ctx)
    ctx.with_owner("deploy-plugin") do
      ctx[:tools].register(name: "deploy", description: "Ship it",
                           params: { env: "string" }, mutating: true,
                           approval: :always) { |env:| "deployed to #{env}" }
    end
  end

  # Stage the log of a turn that died mid-flight: opened, one step, a model
  # reply owing a deploy call, and no result. That is what a process death
  # leaves behind, and what resumable? recognizes.
  def stage_open_turn(ctx, requested: false)
    session = ctx[:sessions].create
    sid = session.id
    ctx[:sessions].append(sid, "turn/start", { agent: "agent-#{sid}" })
    ctx[:sessions].append(sid, "step/start", { n: 1 })
    ctx[:sessions].append(sid, "user/message", { text: "ship it" })
    ctx[:sessions].append(sid, "assistant/message",
                          { parts: [Terret::LLM.encode_part(DEPLOY_CALL.call)] })
    ctx[:sessions].append(sid, "tool/call", { id: "tc7", name: "deploy", args: { env: "prod" } })
    if requested
      ctx[:sessions].append(sid, "approval/requested",
                            { call_id: "tc7", name: "deploy", args: { env: "prod" } })
    end
    [ctx[:loop].spawn_agent(session_id: sid), session]
  end

  # Bounded wait: poll the observable outcome instead of assuming fiber
  # scheduling. On timeout, stop the enclosing task's children first — a
  # StandardError alone doesn't stop siblings (async 2.44.1), so without
  # this a failing await hangs the process instead of failing the test.
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

  def spawn_agent(ctx)
    session = ctx[:sessions].create
    [ctx[:loop].spawn_agent(session_id: session.id), session]
  end

  # -- tests -----------------------------------------------------------------

  def test_hello_arrives_first_with_the_current_last_seq
    ctx = boot(script: [{ text: "hi" }])
    agent, session = spawn_agent(ctx)

    Sync do |task|
      sock, _conn, = connect(ctx, agent, task)
      await { sock.written.any? }

      hello = sock.written.first
      assert_equal({ type: "hello", proto: 1, session_id: session.id, last_seq: 0 }, hello)
      assert_empty sock.events # nothing streams before subscribe
      sock.client_close
    end
  end

  def test_golden_frame_order_for_a_plain_turn
    ctx = boot(script: [{ text: "Hello there." }])
    agent, session = spawn_agent(ctx)

    Sync do |task|
      sock, = connect(ctx, agent, task)
      sock.client_send(type: "subscribe", from_seq: 0)
      sock.client_send(type: "inject", text: "hi", wake: true)
      await { sock.event_types.include?("turn/end") }

      assert_equal %w[
        session/created
        turn/start
        step/start user/message assistant/message step/end
        turn/end
      ], sock.event_types

      # chunks reassemble to the exact text, and seqs are gapless from 0
      chunks = sock.events.select { |f| f[:type] == "assistant/chunk" }.map { |f| f[:payload][:text] }.join
      assert_equal "Hello there.", chunks
      assert_equal (0...sock.events.size).to_a, sock.events.map { |f| f[:seq] }
      assert_equal session.id, sock.events.first[:session_id]
      sock.client_close
    end
  end

  def test_golden_frame_order_for_a_multi_step_tool_turn
    ctx = boot(script: two_step_script)
    register_weather(ctx)
    agent, = spawn_agent(ctx)

    Sync do |task|
      sock, = connect(ctx, agent, task)
      sock.client_send(type: "subscribe", from_seq: 0)
      sock.client_send(type: "inject", text: "What's the weather in CDMX?", wake: true)
      await { sock.event_types.include?("turn/end") }

      assert_equal %w[
        session/created
        turn/start
        step/start user/message assistant/message
        tool/call tool/result step/end
        step/start assistant/message step/end
        turn/end
      ], sock.event_types
      assert_equal "completed", sock.events.last[:payload][:status]
      sock.client_close
    end
  end

  def test_a_steer_injected_mid_turn_lands_in_the_next_step
    ctx = boot(script: two_step_script)
    gate = Async::Queue.new
    register_weather(ctx) do |city:|
      gate.dequeue # hold the turn mid-tool so the steer provably lands mid-turn
      "22C in #{city}"
    end
    agent, = spawn_agent(ctx)

    Sync do |task|
      sock, = connect(ctx, agent, task)
      sock.client_send(type: "subscribe", from_seq: 0)
      sock.client_send(type: "inject", text: "weather?", wake: true)
      await { sock.event_types(chunkless: false).include?("tool/call") }

      sock.client_send(type: "inject", text: "actually, celsius please", wake: false)
      await { !agent.inbox_empty? } # the frame has landed in the inbox
      gate.enqueue(nil)
      await { sock.event_types.include?("turn/end") }

      assert_equal %w[
        session/created
        turn/start
        step/start user/message assistant/message
        tool/call tool/result step/end
        step/start context/injected assistant/message step/end
        turn/end
      ], sock.event_types
      steer = sock.events.select { |f| f[:type] == "context/injected" }.last
      assert_equal "actually, celsius please", steer[:payload][:text]
      sock.client_close
    end
  end

  def test_a_waking_inject_on_a_busy_agent_queues_instead_of_double_running
    ctx = boot(script: two_step_script)
    gate = Async::Queue.new
    register_weather(ctx) { |city:| gate.dequeue; "22C in #{city}" }
    agent, session = spawn_agent(ctx)

    Sync do |task|
      sock, = connect(ctx, agent, task)
      sock.client_send(type: "subscribe", from_seq: 0)
      sock.client_send(type: "inject", text: "weather?", wake: true)
      await { sock.event_types(chunkless: false).include?("tool/call") }

      sock.client_send(type: "inject", text: "and bring an umbrella", wake: true)
      await { !agent.inbox_empty? }
      gate.enqueue(nil)
      await { sock.event_types.include?("turn/end") }

      assert_equal 1, session.events.count { |e| e.type == "turn/start" },
                   "a waking inject during a turn steers; it must not start a second turn"
      sock.client_close
    end
  end

  def test_a_denied_tool_surfaces_as_an_error_result_in_the_stream
    ctx = boot(script: two_step_script)
    register_weather(ctx)
    ctx.with_owner("policy") do
      ctx.on("tools/pre_execute") do |call, next_|
        call.name == "weather" ? Terret::Tools::Veto.new(reason: "weather is classified") : next_.(call)
      end
    end
    agent, = spawn_agent(ctx)

    Sync do |task|
      sock, = connect(ctx, agent, task)
      sock.client_send(type: "subscribe", from_seq: 0)
      sock.client_send(type: "inject", text: "weather?", wake: true)
      await { sock.event_types.include?("turn/end") }

      denied = sock.events.find { |f| f[:type] == "tool/result" }
      assert_equal "weather is classified", denied[:payload][:error]
      sock.client_close
    end
  end

  def test_an_unknown_frame_gets_bad_frame_and_the_connection_survives
    ctx = boot(script: [{ text: "hi" }])
    agent, = spawn_agent(ctx)

    Sync do |task|
      sock, = connect(ctx, agent, task)
      sock.client_send(type: "launch_missiles")
      await { sock.protocol_frames.any? { |f| f[:code] == "bad_frame" } }

      refute sock.closed?
      sock.client_send(type: "subscribe", from_seq: 0)
      await { sock.events.any? { |f| f[:type] == "session/created" } }
      sock.client_close
    end
  end

  def test_resubscribing_replays_without_duplicating_the_tail
    ctx = boot(script: [{ text: "one" }, { text: "two" }])
    agent, session = spawn_agent(ctx)
    ctx[:loop].run_turn(agent, "first")

    Sync do |task|
      sock, = connect(ctx, agent, task)
      sock.client_send(type: "subscribe", from_seq: 0)
      await { sock.event_types.include?("turn/end") }
      first_count = sock.events.size

      # resubscribe mid-connection from a later point; then a live turn tails on
      sock.client_send(type: "subscribe", from_seq: first_count)
      sock.client_send(type: "inject", text: "second", wake: true)
      await { sock.events.count { |f| f[:type] == "turn/end" } >= 2 }

      seqs = sock.events.map { |f| f[:seq] }
      assert_equal seqs.uniq.sort, seqs.uniq.sort # sanity
      new_frames = sock.events.drop(first_count)
      assert_equal (first_count..new_frames.last[:seq]).to_a, new_frames.map { |f| f[:seq] },
                   "replay-then-tail must be gapless and duplicate-free from from_seq"
      assert_equal session.id, new_frames.first[:session_id]
      sock.client_close
    end
  end

  def test_repeated_overflow_still_delivers_exactly_one_lagged_error
    ctx = boot(script: [{ text: "a reply long enough to spill many chunk frames" }])
    agent, session = spawn_agent(ctx)

    Sync do |task|
      sock, = connect(ctx, agent, task, queue_limit: 3)
      sock.client_send(type: "subscribe", from_seq: 0)
      sock.client_send(type: "inject", text: "hi", wake: true)
      await { sock.closed? }

      lagged = sock.written.select { |f| f[:code] == "lagged" }
      assert_equal 1, lagged.size, "exactly one lagged error frame must survive repeated overflows"
      assert_equal "lagged", sock.written.last[:code], "the drop reason must be the last thing written"
      # the loop finished untouched: the log has the whole turn
      assert_equal "turn/end", session.events.last.type
      assert_equal "completed", session.events.last.payload[:status]
    end
  end

  def test_replay_then_tail_stays_gapless_when_the_store_read_yields
    SlowStore.reading_notification = Async::Notification.new
    ctx = boot(script: [{ text: "hi" }], store: SlowStore)
    agent, session = spawn_agent(ctx)

    Sync do |task|
      sock, = connect(ctx, agent, task)
      sock.client_send(type: "subscribe", from_seq: 0)
      # Wait for handle_subscribe's sessions.read to actually be inside
      # SlowStore's forced yield before appending, so the append lands
      # strictly during the replay read -- the interleaving
      # Terret::Store::Memory can never produce on its own, and exactly what
      # the buffer-then-flip dance in handle_subscribe exists to survive
      # without a gap or a duplicate.
      task.async do
        SlowStore.reading_notification.wait
        ctx[:sessions].append(session.id, "context/injected", { text: "concurrent" })
      end

      await { sock.events.any? { |f| f[:type] == "context/injected" } }

      seqs = sock.events.map { |f| f[:seq] }
      assert_equal seqs.uniq, seqs, "duplicate seq delivered"
      assert_equal (0..seqs.max).to_a, seqs.sort, "gap in delivered seqs"
      sock.client_close
    end
  end

  def test_a_long_replay_is_flow_controlled_not_dropped
    ctx = boot(script: [])
    agent, session = spawn_agent(ctx)
    50.times { |i| ctx[:sessions].append(session.id, "user/message", { text: "m#{i}" }) }

    Sync do |task|
      sock, = connect(ctx, agent, task, queue_limit: 8)
      sock.client_send(type: "subscribe", from_seq: 0)
      await { sock.events.size >= 51 } # session/created + 50 messages

      assert_equal (0..50).to_a, sock.events.map { |f| f[:seq] }
      refute sock.closed?
      assert_empty sock.protocol_frames.select { |f| f[:code] == "lagged" }
      sock.client_close
    end
  end

  def test_a_future_from_seq_filters_the_live_tail
    ctx = boot(script: [{ text: "hi" }])
    agent, session = spawn_agent(ctx)

    Sync do |task|
      sock, = connect(ctx, agent, task)
      sock.client_send(type: "subscribe", from_seq: 1000)
      sock.client_send(type: "inject", text: "hello", wake: true)
      await { session.events.any? { |e| e.type == "turn/end" } }

      assert_empty sock.events, "events below the requested from_seq must not leak"
      sock.client_send(type: "subscribe", from_seq: 0)
      await { sock.events.any? { |f| f[:type] == "turn/end" } }
      sock.client_close
    end
  end

  def test_cancel_racing_a_tool_result_keeps_the_result_and_cancels_the_turn
    ctx = boot(script: two_step_script)
    gate = Async::Queue.new
    register_weather(ctx) { |city:| gate.dequeue; "22C in #{city}" }
    agent, = spawn_agent(ctx)

    Sync do |task|
      sock, = connect(ctx, agent, task)
      sock.client_send(type: "subscribe", from_seq: 0)
      sock.client_send(type: "inject", text: "weather?", wake: true)
      await { sock.event_types(chunkless: false).include?("tool/call") }

      sock.client_send(type: "cancel", reason: "changed my mind")
      await { agent.cancelled? } # the frame landed before the result exists
      gate.enqueue(nil)
      await { sock.event_types.include?("turn/end") }

      assert_equal %w[
        session/created
        turn/start
        step/start user/message assistant/message
        tool/call tool/result step/end
        turn/end
      ], sock.event_types
      turn_end = sock.events.last
      assert_equal "cancelled", turn_end[:payload][:status]
      assert_equal "changed my mind", turn_end[:payload][:reason]
      sock.client_close
    end
  end

  def test_cancel_with_no_turn_running_answers_not_running
    ctx = boot(script: [{ text: "hi" }])
    agent, = spawn_agent(ctx)

    Sync do |task|
      sock, = connect(ctx, agent, task)
      sock.client_send(type: "cancel")
      await { sock.protocol_frames.any? { |f| f[:code] == "not_running" } }

      refute sock.closed?
      sock.client_close
    end
  end

  # A verdict is only accepted against a standing request now, so the round
  # trip stages two of them; the frames and their durable payloads are
  # unchanged.
  def test_approve_and_deny_append_durable_resolutions
    ctx = boot(script: [{ text: "hi" }], extra_rows: [APPROVALS_ROW])
    agent, session = spawn_agent(ctx)
    ctx[:sessions].append(session.id, "approval/requested", { call_id: "tc1", name: "a", args: {} })
    ctx[:sessions].append(session.id, "approval/requested", { call_id: "tc2", name: "b", args: {} })

    Sync do |task|
      sock, = connect(ctx, agent, task)
      sock.client_send(type: "subscribe", from_seq: 0)
      sock.client_send(type: "approve", call_id: "tc1")
      sock.client_send(type: "deny", call_id: "tc2", reason: "too spicy")
      await { sock.events.count { |f| f[:type] == "approval/resolved" } == 2 }

      approved, denied = sock.events.select { |f| f[:type] == "approval/resolved" }
      assert_equal({ call_id: "tc1", verdict: "approved" }, approved[:payload])
      assert_equal({ call_id: "tc2", verdict: "denied", reason: "too spicy" }, denied[:payload])
      # durable, not just visible: the log has both
      assert_equal 2, session.events.count { |e| e.type == "approval/resolved" }
      sock.client_close
    end
  end

  def test_a_wake_on_a_resumable_turn_resumes_it_with_the_text_riding_along
    Sync do |task|
      ctx = boot(script: [{ text: "Caught up." }])
      ctx.with_owner("deploy-plugin") do
        ctx[:tools].register(name: "deploy", description: "Ship it",
                             params: { env: "string" }) { |env:| "deployed to #{env}" }
      end
      agent, session = stage_open_turn(ctx)

      sock, = connect(ctx, agent, task)
      sock.client_send({ type: "inject", text: "you back?", wake: true })
      await { session.events.any? { |e| e.type == "turn/end" } }

      assert_equal 1, session.events.count { |e| e.type == "turn/start" }, "resume, not a new turn"
      assert_equal "deployed to prod",
                   session.events.find { |e| e.type == "tool/result" }.payload[:content]
      injected = session.events.find { |e| e.type == "context/injected" }
      assert_equal "you back?", injected.payload[:text], "the wake text rides the resumed turn"
      sock.client_close
    end
  end

  def test_two_racing_wakes_lose_no_text
    Sync do |task|
      # A sleeping tool parks the first turn's fiber mid-step, so the second
      # wake frame is provably dispatched while a turn is live. Whichever way
      # it loses -- steered by handle_inject or requeued by the runner's
      # rescue -- its text must reach the log, and there must be one turn.
      slow_call = Terret::LLM::ToolCall.new(id: "tcs", name: "slow", args: {})
      ctx = boot(script: [{ text: "Working.", tool_calls: [slow_call] }, { text: "All done." }])
      ctx.with_owner("slow-plugin") do
        ctx[:tools].register(name: "slow", description: "Takes a moment",
                             params: {}) { sleep(0.02) || "done" }
      end
      agent, session = spawn_agent(ctx)
      sock, = connect(ctx, agent, task)

      sock.client_send({ type: "inject", text: "first", wake: true })
      sock.client_send({ type: "inject", text: "second", wake: true })
      await { session.events.any? { |e| e.type == "turn/end" } && agent.status == :idle }

      texts = session.events.select { |e| %w[user/message context/injected].include?(e.type) }
                            .map { |e| [e.type, e.payload[:text]] }
      assert_includes texts, ["user/message", "first"]
      assert_includes texts, ["context/injected", "second"],
                      "the raced wake's text must ride the winner's next step, not drop"
      assert_equal 1, session.events.count { |e| e.type == "turn/start" }
      sock.client_close
    end
  end

  # handle_inject's own status check makes the socket-level race above resolve
  # as a steer on this runtime: task.async starts the turn synchronously, so
  # the second frame always observes :running. The runner's requeue is the
  # guard for every other caller, and for a runtime where that scheduling
  # changes — so it is exercised against the Service's own lambda, the only
  # place a turn can be asked for while one is live.
  def test_the_runner_requeues_a_raced_wake_instead_of_dropping_it
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
      { id: "ws",       plugin: Terret::WS::Service, config: { tokens: { "s1" => "t" } } }
    ])
    ctx = loader.boot!
    slow_call = Terret::LLM::ToolCall.new(id: "tcs", name: "slow", args: {})
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(
      [{ text: "Working.", tool_calls: [slow_call] }, { text: "All done." }]
    ))
    ctx.with_owner("slow-plugin") do
      ctx[:tools].register(name: "slow", description: "Takes a moment", params: {}) { sleep(0.02) || "done" }
    end
    agent, session = spawn_agent(ctx)

    Sync do |task|
      run = ctx[:ws].send(:runner, task)
      run.call(agent, "first")
      await { agent.status == :running }
      run.call(agent, "second") # loses the race: a turn is already live
      await { session.events.any? { |e| e.type == "turn/end" } }

      texts = session.events.select { |e| %w[user/message context/injected].include?(e.type) }
                            .map { |e| [e.type, e.payload[:text]] }
      assert_includes texts, ["context/injected", "second"],
                      "a raced wake requeues its text; it must never be dropped"
      assert_equal 1, session.events.count { |e| e.type == "turn/start" }
    end
  end

  def test_approve_without_the_approvals_row_answers_unsupported
    Sync do |task|
      ctx = boot(script: [])
      agent, session = spawn_agent(ctx)
      sock, = connect(ctx, agent, task)
      sock.client_send({ type: "approve", call_id: "x" })
      await { sock.protocol_frames.any? { |f| f[:code] == "unsupported" } }
      refute session.events.map(&:type).include?("approval/resolved")
      sock.client_close
    end
  end

  def test_an_approve_for_nothing_pending_answers_stale_call_and_appends_nothing
    Sync do |task|
      ctx = boot(script: [], extra_rows: [APPROVALS_ROW])
      agent, session = spawn_agent(ctx)
      sock, = connect(ctx, agent, task)
      sock.client_send({ type: "approve", call_id: "ghost" })
      await { sock.protocol_frames.any? { |f| f[:code] == "stale_call" } }
      refute session.events.map(&:type).include?("approval/resolved")
      sock.client_close
    end
  end

  def test_park_approve_execute_over_the_socket
    Sync do |task|
      ctx = boot(script: [{ text: "Deploying.", tool_calls: [DEPLOY_CALL.call] }, { text: "Done." }],
                 extra_rows: [APPROVALS_ROW])
      register_deploy(ctx)
      agent, session = spawn_agent(ctx)
      sock, = connect(ctx, agent, task)
      sock.client_send({ type: "subscribe", from_seq: 0 })

      sock.client_send({ type: "inject", text: "ship it", wake: true })
      await { agent.status == :waiting_approval }
      await { sock.event_types.include?("approval/requested") }

      sock.client_send({ type: "approve", call_id: "tc7" })
      await { session.events.any? { |e| e.type == "turn/end" } }
      assert_equal "deployed to prod",
                   session.events.find { |e| e.type == "tool/result" }.payload[:content]
      assert_equal :idle, agent.status
      sock.client_close
    end
  end

  def test_cancel_while_parked_denies_durably_and_cancels_the_turn
    Sync do |task|
      ctx = boot(script: [{ text: "Deploying.", tool_calls: [DEPLOY_CALL.call] }, { text: "Done." }],
                 extra_rows: [APPROVALS_ROW])
      register_deploy(ctx)
      agent, session = spawn_agent(ctx)
      sock, = connect(ctx, agent, task)

      sock.client_send({ type: "inject", text: "ship it", wake: true })
      await { agent.status == :waiting_approval }

      sock.client_send({ type: "cancel", reason: "changed my mind" })
      await { session.events.any? { |e| e.type == "turn/end" } }

      resolved = session.events.find { |e| e.type == "approval/resolved" }
      assert_equal "denied", resolved.payload[:verdict]
      turn_end = session.events.find { |e| e.type == "turn/end" }
      assert_equal "cancelled", turn_end.payload[:status]
      assert_equal "changed my mind", turn_end.payload[:reason]
      sock.client_close
    end
  end

  def test_a_verdict_for_an_idle_agent_with_an_open_turn_resumes_it
    Sync do |task|
      ctx = boot(script: [{ text: "Done." }], extra_rows: [APPROVALS_ROW])
      register_deploy(ctx)
      agent, session = stage_open_turn(ctx, requested: true)

      sock, = connect(ctx, agent, task)
      sock.client_send({ type: "approve", call_id: "tc7" })
      await { session.events.any? { |e| e.type == "turn/end" } }

      assert_equal "deployed to prod",
                   session.events.find { |e| e.type == "tool/result" }.payload[:content]
      assert_equal 1, session.events.count { |e| e.type == "turn/start" }
      sock.client_close
    end
  end

  def test_set_model_repoints_the_role_for_the_next_turn
    ctx = boot(script: [{ text: "from fake" }])
    ctx[:llm].register_adapter("alt", Terret::LLM::FakeAdapter.new([{ text: "from alt" }]))
    agent, = spawn_agent(ctx)

    Sync do |task|
      sock, = connect(ctx, agent, task)
      sock.client_send(type: "subscribe", from_seq: 0)
      sock.client_send(type: "set_model", role: "main", model: "alt/anything")
      sock.client_send(type: "inject", text: "hi", wake: true)
      await { sock.event_types.include?("turn/end") }

      chunks = sock.events.select { |f| f[:type] == "assistant/chunk" }.map { |f| f[:payload][:text] }.join
      assert_equal "from alt", chunks

      sock.client_send(type: "set_model", role: "main", model: "nonsense")
      await { sock.protocol_frames.any? { |f| f[:code] == "bad_frame" } }
      refute sock.closed?
      sock.client_close
    end
  end

  def test_set_policy_flips_permissions_mid_session
    Sync do |task|
      ping = Terret::LLM::ToolCall.new(id: "tp9", name: "ping", args: {})
      ctx = boot(script: [{ text: "Pinging.", tool_calls: [ping] }, { text: "done" }])
      ctx.with_owner("ping-plugin") do
        ctx[:tools].register(name: "ping", description: "Pong", params: {}) { "pong" }
      end
      agent, session = spawn_agent(ctx)
      Terret::Tools::AllowList.install(agent.ctx, ["nothing"])
      sock, = connect(ctx, agent, task)

      sock.client_send({ type: "set_policy", patterns: ["ping"] })
      await { session.events.any? { |e| e.type == "policy/updated" } }

      sock.client_send({ type: "inject", text: "go", wake: true })
      await { session.events.any? { |e| e.type == "turn/end" } }
      assert_equal "pong", session.events.find { |e| e.type == "tool/result" }.payload[:content]
      sock.client_close
    end
  end

  def test_set_policy_rejects_non_string_patterns
    Sync do |task|
      ctx = boot(script: [])
      agent, session = spawn_agent(ctx)
      sock, = connect(ctx, agent, task)
      sock.client_send({ type: "set_policy", patterns: [1, 2] })
      await { sock.protocol_frames.any? { |f| f[:code] == "bad_frame" } }
      refute session.events.map(&:type).include?("policy/updated")
      sock.client_close
    end
  end

  # Before the M6 boundary (Task 3), invalid UTF-8 appended durably and blew up
  # in the socket's JSON serializer, dropping the connection. Now the boundary
  # refuses it before any consumer can see it: the log stays untouched and the
  # connection never even notices.
  def test_a_poison_payload_is_refused_at_the_boundary_and_the_socket_survives
    ctx = boot(script: [])
    agent, session = spawn_agent(ctx)
    poison = "\xFF\xFE".dup.force_encoding(Encoding::UTF_8)

    Sync do |task|
      sock, = connect(ctx, agent, task)
      sock.client_send(type: "subscribe", from_seq: 0)
      await { sock.events.any? }

      before = session.events.length
      assert_raises(Terret::NonPrimitivePayload) do
        ctx[:sessions].append(session.id, "user/message", { text: poison })
      end
      assert_equal before, session.events.length, "a refused append must leave the log untouched"
      refute sock.closed?, "the poison never reached the wire; the connection lives"
      sock.client_close
    end
  end

  def test_a_client_drop_mid_turn_never_cancels_the_turn
    ctx = boot(script: two_step_script)
    gate = Async::Queue.new
    register_weather(ctx) { |city:| gate.dequeue; "22C in #{city}" }
    agent, session = spawn_agent(ctx)

    Sync do |task|
      sock, _conn, conn_task = connect(ctx, agent, task)
      sock.client_send(type: "subscribe", from_seq: 0)
      sock.client_send(type: "inject", text: "weather?", wake: true)
      await { sock.event_types(chunkless: false).include?("tool/call") }

      sock.client_close # the network blips; the turn task is rooted on the server
      conn_task.wait
      gate.enqueue(nil)
      await { session.events.any? { |e| e.type == "turn/end" } }

      assert_equal "completed", session.events.last.payload[:status]
    end
  end

  def test_reconnect_with_from_seq_sees_no_gap_and_no_duplicate
    ctx = boot(script: [{ text: "one" }, { text: "two" }])
    agent, session = spawn_agent(ctx)

    Sync do |task|
      sock1, _c1, task1 = connect(ctx, agent, task)
      sock1.client_send(type: "subscribe", from_seq: 0)
      sock1.client_send(type: "inject", text: "first", wake: true)
      await { sock1.event_types.include?("turn/end") }
      recorded = sock1.events.map { |f| f[:seq] }.max
      sock1.client_close
      task1.wait

      # a whole turn happens while nobody is connected
      ctx[:loop].run_turn(agent, "second")

      sock2, = connect(ctx, agent, task)
      sock2.client_send(type: "subscribe", from_seq: recorded + 1)
      await { sock2.event_types.include?("turn/end") }

      seqs = sock2.events.map { |f| f[:seq] }
      assert_equal ((recorded + 1)..seqs.max).to_a, seqs,
                   "the reconnecting client must see exactly the events it missed"
      total = session.events.map(&:seq)
      assert_equal total, (sock1.events.map { |f| f[:seq] } + seqs),
                   "old stream plus new stream must equal the whole log with no overlap"
      sock2.client_close
    end
  end

  class RosterClient
    Tool = Struct.new(:name, :description, :input_schema)
    Result = Struct.new(:structured_content, keyword_init: true) do
      def error? = false
      def structured? = !structured_content.nil?
      def content = []
    end

    def connect = true
    def disconnect = true
    def reconnect! = true
    def on(*) = nil
    def listen = nil
    def tools(*) = [Tool.new("lookup", "", {}), Tool.new("wipe", "", {})]
    def call_tool(name, **args) = Result.new(structured_content: { "did" => name, "args" => args })
  end

  def test_an_all_mcp_roster_works_under_policy_over_the_socket
    script = [
      { text: "Using tools.", tool_calls: [
        Terret::LLM::ToolCall.new(id: "t1", name: "mcp__nexus__lookup", args: { q: "x" }),
        Terret::LLM::ToolCall.new(id: "t2", name: "mcp__nexus__wipe", args: {})
      ] },
      { text: "Done." }
    ]
    ctx = boot(script: script, extra_rows: [
      { id: "mcp", plugin: Terret::MCP::Service,
        config: { servers: { "nexus" => { url: "https://x/mcp" } },
                  client_factory: ->(*) { RosterClient.new } } }
    ])
    ctx[:mcp].mount!
    agent, session = spawn_agent(ctx)
    Terret::Tools::AllowList.install(agent.ctx, ["mcp__nexus__lookup"])

    Sync do |task|
      sock, = connect(ctx, agent, task)
      sock.client_send(type: "subscribe", from_seq: 0)
      sock.client_send(type: "inject", text: "go", wake: true)
      await { sock.event_types.include?("turn/end") }

      results = session.events.select { |e| e.type == "tool/result" }
      lookup = results.find { |e| e.payload[:id] == "t1" }
      wipe   = results.find { |e| e.payload[:id] == "t2" }
      assert_equal({ did: "lookup", args: { q: "x" } }, lookup.payload[:content])
      assert_nil lookup.payload[:error]
      assert_equal "mcp__nexus__wipe is not on the allow list", wipe.payload[:error]
      assert_equal "completed", sock.events.last[:payload][:status]
      sock.client_close
    end
  end

  def test_bearer_tokens_hot_reload
    # The harness `boot` helper only returns ctx, and its ~20 call sites make
    # extending it non-mechanical to review under TDD; booted locally here
    # instead, mirroring the harness's own row list plus the ws row.
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
      { id: "ws",       plugin: Terret::WS::Service, config: { tokens: { "s1" => "old" } } }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new([]))

    assert ctx[:ws].authorized?("s1", "old")
    loader.reconfigure!("ws", { tokens: { "s1" => "new" } })
    refute ctx[:ws].authorized?("s1", "old"), "rotated-out token must stop authorizing"
    assert ctx[:ws].authorized?("s1", "new")
  end

  def test_an_unexpected_dispatch_error_surfaces_as_internal
    ctx = boot(script: [])
    agent, = spawn_agent(ctx)
    # Inject the failure at the dispatch path itself (Sessions#read), not via
    # a raising session/event listener: as of emit isolation (Task 2), a
    # listener bug no longer surfaces as a producer-side dispatch failure --
    # that's the whole point of the fix. subscribe -> handle_subscribe ->
    # sessions.read raises -> Connection#run's dispatch rescue ->
    # shutdown(code: "internal"). Deliberately not the approve/deny path: a
    # later task rewrites handle_resolution, and this keeps the test out of
    # its blast radius.
    ctx[:sessions].define_singleton_method(:read) { |*| raise "boom" }

    Sync do |task|
      sock, = connect(ctx, agent, task)
      sock.client_send(type: "subscribe", from_seq: 0)
      await { sock.closed? }

      assert_equal "internal", sock.written.last[:code]
    end
  end
end
