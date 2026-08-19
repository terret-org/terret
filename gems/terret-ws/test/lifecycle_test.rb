# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "timeout"

ASYNC_AVAILABLE = begin
  require "async"
  require "async/queue"
  true
rescue LoadError
  false
end unless defined?(ASYNC_AVAILABLE)

require_relative "../lib/terret/ws" if ASYNC_AVAILABLE

# The §12 M6 acceptance, hard half: a turn wedged mid-tool survives kill -9
# and completes after a wake in a fresh process.
class LifecycleTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/wedged_boot.rb", __dir__)

  def setup
    skip "async not installed" unless ASYNC_AVAILABLE
  end

  def test_a_wedged_deploy_resumes_after_a_real_process_death
    Dir.mktmpdir("terret-lifecycle") do |dir|
      sid = "s-deploy"

      # --- life before: wedge mid-tool, then die hard ---------------------
      # Same spawn shape as gems/terret-mcp/test/integration_test.rb: the
      # running interpreter by RbConfig.ruby, inheriting this process's env
      # (under `bundle exec` that is what puts async on the child's path).
      # err is merged into out so a fixture crash lands in the assertion.
      out = IO.popen([RbConfig.ruby, FIXTURE, dir, sid], err: [:child, :out])
      begin
        seen = []
        marker = scan_for(out, "WEDGED", seen)
        assert_equal "WEDGED", marker, "fixture never wedged; output: #{seen.join.inspect}"
      ensure
        kill_child(out)
      end

      # --- life after: fresh boot on the same directory -------------------
      Hames.reset_events!
      Terret.declare_events!
      loader = Hames::Loader.new
      loader.layer([
        { id: "session_store", plugin: Terret::Store::JSONL, config: { dir: dir } },
        { id: "sessions", plugin: Terret::Sessions },
        { id: "prompt",   plugin: Terret::Prompt },
        { id: "tools",    plugin: Terret::Tools::Registry },
        { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
        { id: "loop",     plugin: Terret::Loop }
      ])
      ctx = loader.boot!
      # the model still owes the post-tool step; the fresh process scripts it
      ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new([{ text: "Done." }]))
      ctx.with_owner("deploy-plugin") do
        ctx[:tools].register(name: "deploy", description: "Ship it",
                             params: { env: "string" }, mutating: true) { |env:| "deployed v2 to #{env}" }
      end

      session = ctx[:sessions].resume(sid)
      assert ctx[:loop].resumable?(sid), "the killed process must leave an open turn"
      before = ctx[:sessions].derive_messages(sid)

      agent = ctx[:loop].spawn_agent(session_id: sid)

      Sync do |task|
        sock = FakeIO.new
        conn = Terret::WS::Connection.new(
          ctx: ctx, agent: agent, io: sock,
          runner: ->(a, text) { task.async { ctx[:loop].run_turn(a, text) } },
          resumer: ->(a) { task.async { ctx[:loop].resume_turn(a) } }
        )
        task.async { conn.run }
        # the first stimulus after the deploy picks the turn back up
        sock.client_send({ type: "inject", text: "status?", wake: true })
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        until session.events.any? { |e| e.type == "turn/end" }
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            Async::Task.current.children&.each(&:stop)
            raise "turn never completed after the wake"
          end
          sleep 0.005
        end
        sock.client_close
      end

      result = session.events.find { |e| e.type == "tool/result" }
      assert_equal "deployed v2 to prod", result.payload[:content]
      assert_equal "completed", session.events.reverse_each
                                       .find { |e| e.type == "turn/end" }.payload[:status]
      assert_equal 1, session.events.count { |e| e.type == "turn/start" }
      assert_equal "status?",
                   session.events.find { |e| e.type == "context/injected" }&.payload&.[](:text),
                   "the wake text rode the resumed turn"

      # derived context before the wake is a strict prefix of after: the
      # resume extended history, never rewrote it
      after = ctx[:sessions].derive_messages(sid)
      assert_equal before, after.first(before.length)
    end
  end

  private

  # Read the child until `marker` shows up, keeping everything read in `seen`
  # for the failure message. Scanning rather than reading one line matters:
  # stderr is merged into stdout so a crash is diagnosable, and Ruby 4.0 warns
  # about IO::Buffer the first time the store writes under the scheduler, so
  # the marker is not reliably the first line. nil means the child died or
  # went quiet — `seen` says which.
  def scan_for(io, marker, seen)
    Timeout.timeout(30) do
      while (line = io.gets)
        seen << line
        return marker if line.strip == marker
      end
    end
    nil
  rescue Timeout::Error
    nil
  end

  # SIGKILL is the point of the lane, and it is also the cleanup path when an
  # assertion above fails: never leave a wedged fixture behind.
  def kill_child(io)
    Process.kill(:KILL, io.pid)
    Process.wait(io.pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil # already reaped
  ensure
    io.close unless io.closed?
  end

  # Minimal io for Connection. protocol_test's FakeSocket is the full harness
  # (it records frames for assertions); this lane asserts on the durable log
  # instead, so it only needs the read/write/close contract.
  class FakeIO
    def initialize
      @in = Async::Queue.new
      @closed = false
    end

    def client_send(hash) = @in.enqueue(JSON.generate(hash))
    def client_close = @in.enqueue(nil)
    def read = @closed ? nil : @in.dequeue
    def write(_text) = nil

    def close(*)
      return if @closed

      @closed = true
      @in.enqueue(nil)
    end
  end
end
