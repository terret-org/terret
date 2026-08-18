# frozen_string_literal: true

require "minitest/autorun"
require "json"

ASYNC_AVAILABLE = begin
  require "async"
  require "async/queue"
  true
rescue LoadError
  false
end

require_relative "../lib/terret/ws" if ASYNC_AVAILABLE

class ServiceTest < Minitest::Test
  def setup
    skip "async not installed" unless ASYNC_AVAILABLE
  end

  def boot(script:, tokens:)
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
      { id: "ws",       plugin: Terret::WS::Service, config: { tokens: tokens } }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))
    ctx
  end

  class FakeSocket
    attr_reader :written

    def initialize
      @in = Async::Queue.new
      @written = []
      @closed = false
    end

    def client_send(hash) = @in.enqueue(JSON.generate(hash))
    def client_close = @in.enqueue(nil)
    def read = @closed ? nil : @in.dequeue
    def write(text) = @written << JSON.parse(text, symbolize_names: true)

    def close(*)
      return if @closed

      @closed = true
      @in.enqueue(nil)
    end

    def closed? = @closed
  end

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

  def test_a_bad_token_is_refused_before_the_agent_exists
    ctx = boot(script: [], tokens: { "s1" => "right" })

    Sync do
      sock = FakeSocket.new
      ctx[:ws].attach(session_id: "s1", token: "wrong", io: sock)

      assert_equal [{ type: "error", code: "unauthorized" }], sock.written
      assert sock.closed?
      assert_empty ctx[:sessions].session_ids, "auth runs before the session is resolved"
      assert_nil ctx[:loop].agent("agent-s1")
    end
  end

  def test_connecting_resolves_or_creates_the_session_named_by_the_agent_id
    ctx = boot(script: [{ text: "hi" }], tokens: { "s1" => "secret" })

    Sync do |task|
      sock = FakeSocket.new
      attach_task = task.async { ctx[:ws].attach(session_id: "s1", token: "secret", io: sock) }
      await { sock.written.any? { |f| f[:type] == "hello" } }

      assert_includes ctx[:sessions].session_ids, "s1"
      sock.client_send(type: "subscribe", from_seq: 0)
      sock.client_send(type: "inject", text: "hello", wake: true)
      await { sock.written.any? { |f| f[:type] == "turn/end" } }
      sock.client_close
      attach_task.wait

      # a second attach resumes the same session rather than creating another
      sock2 = FakeSocket.new
      t2 = task.async { ctx[:ws].attach(session_id: "s1", token: "secret", io: sock2) }
      await { sock2.written.any? { |f| f[:type] == "hello" } }
      assert_operator sock2.written.first[:last_seq], :>, 0
      sock2.client_close
      t2.wait
    end
  end

  def test_a_second_connection_supersedes_the_first
    ctx = boot(script: [], tokens: { "s1" => "secret" })

    Sync do |task|
      sock1 = FakeSocket.new
      t1 = task.async { ctx[:ws].attach(session_id: "s1", token: "secret", io: sock1) }
      await { sock1.written.any? { |f| f[:type] == "hello" } }

      sock2 = FakeSocket.new
      t2 = task.async { ctx[:ws].attach(session_id: "s1", token: "secret", io: sock2) }
      await { sock2.written.any? { |f| f[:type] == "hello" } }

      await { sock1.closed? }
      assert_equal "superseded", sock1.written.last[:code]
      refute sock2.closed?
      sock2.client_close
      [t1, t2].each(&:wait)
    end
  end

  def test_tokens_do_not_cross_agents
    ctx = boot(script: [], tokens: { "s1" => "one", "s2" => "two" })

    Sync do
      sock = FakeSocket.new
      ctx[:ws].attach(session_id: "s2", token: "one", io: sock)
      assert_equal "unauthorized", sock.written.last[:code]
    end
  end
end
