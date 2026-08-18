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

  def connect(ctx, agent, root, queue_limit: 256)
    sock = FakeSocket.new
    conn = Terret::WS::Connection.new(ctx: ctx, agent: agent, io: sock,
                                      runner: runner(ctx, root), queue_limit: queue_limit)
    conn_task = root.async { conn.run }
    [sock, conn, conn_task]
  end

  # Bounded wait: scheduling order is the async gem's business, not the
  # test's. Poll the observable outcome instead of assuming interleavings.
  def await(timeout = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "await timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

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
end
