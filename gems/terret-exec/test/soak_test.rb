# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/terret/exec"                              # the execution seams
require_relative "../../terret-tools-std/lib/terret/tools_std"     # Read/Write/Bash on those seams
require_relative "../../terret-store-sqlite/lib/terret/store/sqlite" # the durable file store

ASYNC_AVAILABLE = begin
  require "async"
  true
rescue LoadError
  false
end unless defined?(ASYNC_AVAILABLE)

# §14's owed debt (owed since M2): prove the one-reactor design survives real
# concurrent load. Terret runs one reactor and many agents with no user-facing
# threads (plan §8), so a call that parked the THREAD instead of the FIBER — or
# a store that let two appends to one session claim the same seq — would take
# every other agent in the process down with it. This drives the WHOLE stack
# under fire: N agents each running a multi-step tool turn (Bash + Write + Read)
# against a shared durable store, while 2 long-lived PTYs stream throughout, and
# a second fiber hammers each agent's own session with projection-invisible
# appends so the M6 per-session append lock is contended for real rather than
# only in theory.
#
# Slow and gated: `TERRET_SOAK=1` opts in, so the default lanes stay fast. The
# heavy body also needs the reactor, so it skips without async too.
#
# If this file goes red, the assertion is the point — do not weaken it to green.
# A seq gap, a duplicate seq, an agent's log carrying another agent's bytes, or
# a wall-clock blowout is a real reactor stall or a store race, which is the
# most valuable thing this test can find.
class SoakTest < Minitest::Test
  N_AGENTS = 8
  N_PTYS = 2
  CYCLES = 3 # Bash+Write+Read repeated per turn, so a turn is many steps, not one
  KEEPER = "pty-keeper" # the session that owns the two long-lived terminals

  # A healthy run finishes in well under a second on developer hardware
  # (measured ~0.1s): 8 shells each paying one bash+stty handshake, 72 tool
  # calls of file I/O, and several hundred store appends, nearly all of it
  # interleaved on one reactor. The ceiling sits far above that so even a
  # heavily loaded CI box never flakes, yet a genuine reactor stall — one
  # agent's blocking call parking all the others behind it — blows past 30s or
  # hangs outright. The PTY round-trip floor below is the finer stall detector;
  # this is the coarse near-hang backstop.
  WALL_CEILING = 30.0

  T = Terret::LLM

  # Deterministic, and deliberately STATELESS: every answer is derived from the
  # request alone, so the 8 fibers that share one instance cannot corrupt each
  # other — there is nothing mutable to race on. The turn's first user message
  # carries the agent index and its workspace dir ("AGENT:<i>:<dir>"); the step
  # is simply how many tool results the derived history already holds. Each
  # cycle echoes through the shell, writes a file, then reads it back; after
  # CYCLES of that a final tool-free message closes the turn.
  class ScriptedByRequest
    def stream(request)
      user = request.messages.find { |m| m.role == :user }.text
      _, idx, workdir = user.split(":", 3)
      step = request.messages.count { |m| m.role == :tool }

      text, calls =
        if step >= 3 * CYCLES
          ["Done for agent #{idx}.", []]
        else
          cycle = step / 3
          out = File.join(workdir, "out-#{cycle}.txt")
          id = "tc-#{idx}-#{step}" # unique within the session's turn
          case step % 3
          when 0 then ["Running echo #{cycle}.",
                       [T::ToolCall.new(id:, name: "Bash",
                                        args: { command: "echo hi-#{idx}-#{cycle}" })]]
          when 1 then ["Writing file #{cycle}.",
                       [T::ToolCall.new(id:, name: "Write",
                                        args: { file_path: out, content: "written-by-#{idx}-#{cycle}" })]]
          else ["Reading file #{cycle} back.",
                [T::ToolCall.new(id:, name: "Read", args: { file_path: out })]]
          end
        end

      parts = []
      text.chars.each_slice(8) { |c| yield T::TextDelta.new(text: c.join) }
      parts << T::Text.new(text: text)
      calls.each do |tc|
        yield T::ToolCallEnd.new(tool_call: tc)
        parts << tc
      end
      yield T::MessageStop.new(stop_reason: calls.empty? ? :end_turn : :tool_use)
      T::Message.new(role: :assistant, parts: parts)
    end
  end

  def boot(store_row, workspace)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      store_row,
      { id: "sessions",   plugin: Terret::Sessions },
      { id: "prompt",     plugin: Terret::Prompt },
      { id: "tools",      plugin: Terret::Tools::Registry },
      { id: "sandbox",    plugin: Terret::Exec::SandboxNone },
      { id: "subprocess", plugin: Terret::Exec::Subprocess },
      { id: "fs",         plugin: Terret::Exec::FS, config: { workspace: workspace } },
      { id: "shell",      plugin: Terret::Exec::Shell },
      { id: "terminals",  plugin: Terret::Exec::Terminals },
      { id: "std_bash",      plugin: Terret::ToolsStd::Bash },
      { id: "std_files",     plugin: Terret::ToolsStd::Files },
      { id: "std_terminals", plugin: Terret::ToolsStd::Terminals },
      { id: "llm",  plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop", plugin: Terret::Loop }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", ScriptedByRequest.new)
    ctx
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # -- the tests -------------------------------------------------------------

  def test_soak_against_the_sqlite_file_store
    skip "set TERRET_SOAK=1 to run the soak" unless ENV["TERRET_SOAK"]
    skip "async not installed" unless ASYNC_AVAILABLE

    Dir.mktmpdir("terret-soak-sqlite") do |root|
      path = File.join(root, "store", "soak.sqlite3")
      run_soak(root, "sqlite") do
        { id: "session_store", plugin: Terret::Store::SQLite, config: { path: path } }
      end
      fresh = Terret::Store::SQLite.new(path: path)
      fresh.start(nil)
      verify_durable_log(fresh)
      fresh.stop(nil)
    end
  end

  def test_soak_against_the_jsonl_store
    skip "set TERRET_SOAK=1 to run the soak" unless ENV["TERRET_SOAK"]
    skip "async not installed" unless ASYNC_AVAILABLE

    Dir.mktmpdir("terret-soak-jsonl") do |root|
      dir = File.join(root, "store-jsonl")
      run_soak(root, "jsonl") do
        { id: "session_store", plugin: Terret::Store::JSONL, config: { dir: dir } }
      end
      fresh = Terret::Store::JSONL.new(dir: dir)
      fresh.start(nil)
      verify_durable_log(fresh)
    end
  end

  private

  # Boots the harness, opens the two streaming PTYs, fires the N agents, and
  # leaves the process tree reaped. `verify_durable_log` runs afterward against
  # a FRESH store instance on the same file/dir, so what it checks is the
  # durable bytes rather than the in-memory working set.
  def run_soak(root, label)
    @session_ids = (0...N_AGENTS).map { |i| "soak-#{i}" }
    workdirs = @session_ids.map { |sid| File.join(root, "ws-#{sid}") }
    workdirs.each { |d| FileUtils.mkdir_p(d) }

    ctx = boot(yield, workdirs)
    pty_round_trips = Array.new(N_PTYS, 0)
    terminal_pids = []
    shell_pids = []
    statuses = Array.new(N_AGENTS)

    started = now
    begin
      Sync do |task|
        # Two long-lived terminals opened BEFORE the load, each driven by a
        # fiber that write/reads a unique marker round-trip in a loop. Those
        # fibers are the reactor's pulse: if a blocking call ever stalled the
        # reactor, their round-trip count would stop climbing.
        N_PTYS.times do |i|
          term = ctx[:terminals].open("keep-#{i}", ["cat"], session: KEEPER)
          terminal_pids << term.pid
        end

        pty_stop = false
        pty_fibers = (0...N_PTYS).map do |i|
          task.async do
            n = 0
            until pty_stop
              marker = "rt-#{i}-#{n}-x"
              ctx[:terminals].input("keep-#{i}", "#{marker}\n", session: KEEPER)
              seen = +""
              deadline = now + 3
              until seen.include?(marker) || now > deadline
                chunk = ctx[:terminals].read("keep-#{i}", session: KEEPER, timeout: 0.05)
                seen << chunk if chunk && !chunk.empty?
              end
              raise "terminal keep-#{i} went unresponsive at round-trip #{n}" unless seen.include?(marker)

              n += 1
              pty_round_trips[i] = n
              sleep 0.001 # a guaranteed yield even if an echo ever arrives without one
            end
          end
        end

        # N agents, each its own session, each running the full multi-cycle
        # turn. A second fiber per agent pounds the SAME session with projection-
        # invisible session/titled appends throughout the turn, so the loop's
        # own appends and these race on one session's events.length — exactly
        # what the M6 per-session lock exists to serialize. If the lock failed,
        # SQLite's PRIMARY KEY(session_id, seq) rejects the colliding INSERT and
        # JSONL's contiguity check below catches the duplicate.
        agent_fibers = (0...N_AGENTS).map do |i|
          task.async do
            sid = @session_ids[i]
            ctx[:sessions].create(id: sid)
            agent = ctx[:loop].spawn_agent(session_id: sid)

            meta_stop = false
            meta = task.async do
              k = 0
              until meta_stop
                ctx[:sessions].append(sid, "session/titled", { title: "meta-#{i}-#{k}" })
                k += 1
                sleep 0.002
              end
            end

            begin
              statuses[i] = ctx[:loop].run_turn(agent, "AGENT:#{i}:#{workdirs[i]}")
            ensure
              meta_stop = true
              meta.wait
            end
          end
        end
        agent_fibers.each(&:wait)

        # The shells were spawned lazily by the first Bash call; capture their
        # pids while the sessions are still live, to prove them reaped later.
        shell_pids = @session_ids.map { |sid| ctx[:shell].pid(session: sid) }

        # Stop the pulse and prove each terminal answers one more round-trip
        # AFTER the load — responsive the whole way through, not merely alive.
        pty_stop = true
        pty_fibers.each(&:wait)
        N_PTYS.times do |i|
          marker = "final-#{i}-z"
          ctx[:terminals].input("keep-#{i}", "#{marker}\n", session: KEEPER)
          seen = +""
          deadline = now + 5
          until seen.include?(marker) || now > deadline
            chunk = ctx[:terminals].read("keep-#{i}", session: KEEPER, timeout: 0.05)
            seen << chunk if chunk && !chunk.empty?
          end
          assert_includes seen, marker, "terminal keep-#{i} did not answer a final round-trip"
        end
      end
      @elapsed = now - started

      # Every turn ran to completion — no agent was stranded by the concurrency.
      assert_equal Array.new(N_AGENTS, :completed), statuses,
                   "every agent's turn must complete under load"

      # The PTYs streamed throughout: a stalled reactor would have frozen these
      # fibers at 0 or 1 while the agents ran. Each round-trip costs about one
      # of PTYHandle#read's poll intervals, so the healthy count tracks the load
      # duration (~a dozen on this hardware); the floor sits well clear of a
      # stall yet low enough that a fast box cannot dip under it. The final
      # round-trip below is the definitive after-the-load responsiveness check.
      pty_round_trips.each_with_index do |count, i|
        assert_operator count, :>, 3, "terminal keep-#{i} only completed #{count} round-trips"
      end

      # Every process the run spawned is reaped: no leak into the rest of CI.
      ctx[:shell].close_all
      ctx[:terminals].close_all
      (shell_pids + terminal_pids).compact.each do |pid|
        refute alive?(pid), "pid #{pid} survived teardown"
      end

      # Flush and close the writer connection so the fresh reader in the caller
      # sees a settled store rather than racing a WAL checkpoint.
      ctx[:session_store].stop(nil) if ctx.service?(:session_store)

      puts "\n[soak/#{label}] #{N_AGENTS} agents, #{N_PTYS} PTYs, " \
           "#{format('%.2f', @elapsed)}s wall (ceiling #{WALL_CEILING}s), " \
           "pty round-trips #{pty_round_trips.inspect}"
      assert_operator @elapsed, :<, WALL_CEILING,
                      "wall clock #{@elapsed}s exceeded the ceiling; suspect a reactor stall"
    ensure
      # Idempotent safety net for the failure path — close_all discards by key
      # and stop nils the db, so a second call is a no-op.
      ctx[:shell].close_all if ctx.service?(:shell)
      ctx[:terminals].close_all if ctx.service?(:terminals)
      ctx[:session_store].stop(nil) if ctx.service?(:session_store)
    end
  end

  # Re-reads the durable log through a FRESH store instance and proves, per
  # session: seqs are 0..n-1 (contiguous, unique — the append lock held), every
  # row belongs to the session it was read under, the turn completed, and the
  # tool results carry THIS agent's bytes and no other agent's (no cross-session
  # interleaving wrote one agent's event into another's log).
  def verify_durable_log(store)
    assert_equal @session_ids.sort, store.session_ids.sort,
                 "the store must hold exactly the sessions the soak drove"

    @session_ids.each_with_index do |sid, i|
      events = store.read(sid)
      refute_empty events, "#{sid} has no durable events"

      seqs = events.map(&:seq)
      assert_equal (0...events.length).to_a, seqs,
                   "#{sid}: seqs must be contiguous 0..n-1 with no gap or duplicate"
      assert(events.all? { |e| e.session_id == sid },
             "#{sid}: every stored row must belong to this session")

      ends = events.select { |e| e.type == "turn/end" }
      assert_equal 1, events.count { |e| e.type == "turn/start" }, "#{sid}: one turn opened"
      assert_equal 1, ends.length, "#{sid}: one turn closed"
      assert_equal "completed", ends.first.payload[:status], "#{sid}: the turn completed"

      results = events.select { |e| e.type == "tool/result" }.map { |e| e.payload[:content] }
      assert_equal 3 * CYCLES, results.length,
                   "#{sid}: #{CYCLES} cycles of three tool results (Bash, Write, Read)"
      (0...CYCLES).each do |c|
        assert(results.any? { |r| r.to_s.include?("hi-#{i}-#{c}") },
               "#{sid}: its own echo output for cycle #{c}")
        assert_includes results, "written-by-#{i}-#{c}",
                        "#{sid}: its own file contents read back for cycle #{c}"
      end

      @session_ids.each_index do |j|
        next if j == i

        refute(results.any? { |r| r.to_s.include?("written-by-#{j}-") },
               "#{sid} must not carry agent #{j}'s bytes — that is cross-session corruption")
      end
    end
  end
end
