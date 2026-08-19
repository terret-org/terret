# frozen_string_literal: true

require "minitest/autorun"
require "rbconfig"
require "tmpdir"
require_relative "../lib/terret/exec"

# A job is the one thing on this seam that keeps running while nobody is
# looking at it, so the drain has to happen on the reactor rather than at the
# caller's convenience. Where the host has async, that path is exercised too.
ASYNC_AVAILABLE = begin
  require "async"
  true
rescue LoadError
  false
end unless defined?(ASYNC_AVAILABLE)

class JobsTest < Minitest::Test
  RUBY = RbConfig.ruby

  # Records every wrap and returns an observably different argv, so a test can
  # tell "the sandbox was consulted" from "the wrapped argv is what actually
  # became a process" (the same probe subprocess_test and terminals_test use).
  class ProbeSandbox < Terret::Exec::SandboxNone
    def calls = @calls ||= []

    def wrap(argv, cwd:, tty: false)
      calls << { argv: argv, cwd: cwd, tty: tty }
      ["env", "TERRET_WRAPPED=1", *argv]
    end
  end

  def boot(config: {}, sandbox: Terret::Exec::SandboxNone, subprocess_config: {})
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "sandbox", plugin: sandbox, config: {} },
      { id: "subprocess", plugin: Terret::Exec::Subprocess, config: subprocess_config },
      { id: "jobs", plugin: Terret::Exec::Jobs, config: config }
    ])
    ctx = loader.boot!
    @booted << ctx
    [ctx, loader]
  end

  def setup = @booted = []

  # A job is a live process the harness owns, so a test that fails part-way
  # through must still not leak one into the rest of the suite.
  def teardown
    @booted.each { |ctx| ctx[:jobs].stop_all if ctx.service?(:jobs) }
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # Bounded so a child that never dies fails the assertion instead of hanging
  # the suite; signal delivery and reaping are asynchronous, so a bare check
  # right after the call under test would be a race.
  def refute_alive(pid, timeout: 5)
    deadline = now + timeout
    sleep 0.02 while alive?(pid) && now < deadline
    refute alive?(pid), "pid #{pid} is still alive"
  end

  # A handshake rather than a fixed sleep: the job writes the file as its last
  # act, so waiting for it is waiting for everything before it to have
  # happened — including the writes whose bytes this test is about to collect.
  def await_file(path, timeout: 5)
    deadline = now + timeout
    sleep 0.02 while !File.exist?(path) && now < deadline
    assert File.exist?(path), "the job never reached #{path}"
  end

  # A job the harness spawned and never waited on becomes an unreaped zombie
  # the moment it exits, and stays one until something collects it. `ps` is the
  # only portable way to see that state: a zombie still answers `kill(0)`, so
  # #alive? cannot tell one from a running process.
  def zombie?(pid) = `ps -o stat= -p #{pid} 2>/dev/null`.strip.start_with?("Z")

  def await_zombie(pid, timeout: 5)
    deadline = now + timeout
    sleep 0.02 while !zombie?(pid) && now < deadline
    assert zombie?(pid), "pid #{pid} never became an unreaped zombie"
  end

  # The pid without a collect. #collect probes the handle, and probing it reaps
  # a process that has already exited — which is the very state these tests are
  # about, so they cannot ask the seam for the pid the way start_with_pid does.
  def start_announcing_pid(ctx, command, dir, name: "pid", session: "s1")
    path = File.join(dir, name)
    id = ctx[:jobs].start("echo $$ > #{path}; #{command}", session: session)
    await_file(path)
    [id, Integer(File.read(path))]
  end

  # A job that announces its own pid, so a test can watch the process itself
  # rather than take the seam's word for it.
  def start_with_pid(ctx, tail, session: "s1")
    id = ctx[:jobs].start("echo $$; #{tail}", session: session)
    deadline = now + 5
    out = +""
    while !out.include?("\n") && now < deadline
      out << ctx[:jobs].collect(id, session: session)[:output]
      sleep 0.02
    end
    assert_includes out, "\n", "the job never announced its pid"
    [id, Integer(out[/(\d+)/, 1])]
  end

  # -- starting ---------------------------------------------------------------

  def test_start_hands_back_an_opaque_id_and_the_output_arrives_under_it
    ctx, = boot
    id = ctx[:jobs].start("printf hello", session: "s1")

    assert_kind_of String, id
    refute_empty id
    assert_equal "hello", drain_to_exit(ctx, id).first
  end

  def test_a_jobs_command_becomes_a_bash_argv_through_the_sandbox_wrap
    ctx, = boot(sandbox: ProbeSandbox)
    id = ctx[:jobs].start("printf W$TERRET_WRAPPED", session: "s1")

    assert_equal "W1", drain_to_exit(ctx, id).first,
                 "a job must reach a process through subprocess, never around it"
    assert_equal [["bash", "-lc", "printf W$TERRET_WRAPPED"]], ctx[:sandbox].calls.map { |c| c[:argv] }
    refute ctx[:sandbox].calls.first[:tty], "a job is not a terminal; it asks for no tty"
  end

  def test_a_job_runs_in_the_given_cwd
    Dir.mktmpdir do |dir|
      ctx, = boot
      id = ctx[:jobs].start("pwd", session: "s1", cwd: dir)
      assert_includes drain_to_exit(ctx, id).first, File.realpath(dir)
    end
  end

  # -- collecting -------------------------------------------------------------

  def test_a_job_that_is_still_running_says_so_and_has_no_exit_status
    ctx, = boot
    id = ctx[:jobs].start("sleep 30", session: "s1")

    r = ctx[:jobs].collect(id, session: "s1")
    assert_equal :running, r[:status]
    assert_nil r[:exit_status]
    assert_equal "", r[:output]
    refute r[:truncated]
  end

  # The whole point of a job: its output is readable while it is still
  # working, not only once it is done.
  def test_collect_returns_output_while_the_job_is_still_running
    Dir.mktmpdir do |dir|
      ctx, = boot
      first = File.join(dir, "first")
      id = ctx[:jobs].start("printf one; touch #{first}; sleep 30", session: "s1")
      await_file(first)

      r = ctx[:jobs].collect(id, session: "s1")
      assert_equal "one", r[:output]
      assert_equal :running, r[:status]
    end
  end

  def test_a_second_collect_returns_only_what_arrived_since_the_first
    Dir.mktmpdir do |dir|
      ctx, = boot
      one = File.join(dir, "one")
      two = File.join(dir, "two")
      id = ctx[:jobs].start("printf one; touch #{one}; sleep 0.2; printf two; touch #{two}",
                            session: "s1")

      await_file(one)
      assert_equal "one", ctx[:jobs].collect(id, session: "s1")[:output]
      await_file(two)
      assert_equal "two", ctx[:jobs].collect(id, session: "s1")[:output],
                   "a collect drains the buffer; the next one owes only what arrived after it"
    end
  end

  def test_a_finished_job_reports_its_exit_status
    ctx, = boot
    id = ctx[:jobs].start("printf done; exit 3", session: "s1")

    output, result = drain_to_exit(ctx, id)
    assert_equal "done", output
    assert_equal :exited, result[:status]
    assert_equal 3, result[:exit_status]
  end

  # One stream, like a terminal's: a job's diagnostics are part of what it
  # said, and a caller reading only stdout would lose the half that explains
  # why the other half stopped.
  def test_a_jobs_stderr_is_collected_alongside_its_stdout
    ctx, = boot
    id = ctx[:jobs].start("printf out; printf err >&2", session: "s1")

    output = drain_to_exit(ctx, id).first
    assert_includes output, "out"
    assert_includes output, "err"
  end

  # -- the byte cap -----------------------------------------------------------

  def test_output_past_the_cap_is_dropped_and_the_truncation_is_reported
    Dir.mktmpdir do |dir|
      ctx, = boot(config: { max_output: 64 })
      flag = File.join(dir, "written")
      id = ctx[:jobs].start("#{RUBY} -e 'print \"x\" * 200'; touch #{flag}; sleep 30",
                            session: "s1")
      await_file(flag)

      r = ctx[:jobs].collect(id, session: "s1")
      assert_equal 64, r[:output].bytesize, "the cap is a memory bound, kept exactly"
      assert r[:truncated], "dropping bytes is reported rather than quietly done"
    end
  end

  def test_a_job_inside_the_cap_is_not_reported_as_truncated
    ctx, = boot(config: { max_output: 64 })
    id = ctx[:jobs].start("printf small", session: "s1")

    output, result = drain_to_exit(ctx, id)
    assert_equal "small", output
    refute result[:truncated]
  end

  # -- stopping ---------------------------------------------------------------

  def test_stop_ends_the_process_and_the_next_collect_says_it_exited
    ctx, = boot
    id, pid = start_with_pid(ctx, "sleep 30")

    ctx[:jobs].stop(id, session: "s1")
    refute_alive pid

    r = ctx[:jobs].collect(id, session: "s1")
    assert_equal :exited, r[:status]
    assert_nil r[:exit_status], "a signalled job has no exit status to report"
  end

  # The escalation is subprocess's own: TERM, then KILL after the grace. A job
  # that ignores the polite request is still ended.
  def test_a_job_that_ignores_sigterm_is_killed
    ctx, = boot(subprocess_config: { term_grace: 0.2 })
    id, pid = start_with_pid(ctx, "trap '' TERM; sleep 30")

    ctx[:jobs].stop(id, session: "s1")
    refute_alive pid
  end

  # Stopping the same job twice with the row still there is one job being
  # stopped, not two: the handle is idempotent, so the second call is a no-op
  # that still names the job it was asked about.
  def test_stopping_a_job_twice_is_idempotent_while_its_row_is_still_there
    ctx, = boot
    id, pid = start_with_pid(ctx, "sleep 30")

    assert_equal id, ctx[:jobs].stop(id, session: "s1")
    assert_equal id, ctx[:jobs].stop(id, session: "s1")
    refute_alive pid
  end

  def test_stopping_a_job_after_it_is_collected_out_is_refused_rather_than_signalling_a_stranger
    ctx, = boot
    id, = start_with_pid(ctx, "sleep 30")

    ctx[:jobs].stop(id, session: "s1")
    ctx[:jobs].collect(id, session: "s1") # the collect that closes it out
    assert_raises(Terret::Exec::NoSuchJob) { ctx[:jobs].stop(id, session: "s1") }
  end

  # A job that finished on its own and was never collected is an unreaped
  # zombie in a process group whose only member is itself. Darwin answers EPERM
  # rather than ESRCH to a signal aimed at that group, and an errno raised out
  # of #stop is a job left half-closed: the fd still open, the child still in
  # the process table, and a raw errno on its way to the model.
  def test_stopping_a_job_that_finished_on_its_own_and_was_never_collected_still_ends_it
    Dir.mktmpdir do |dir|
      ctx, = boot
      id, pid = start_announcing_pid(ctx, "printf hi", dir)
      await_zombie(pid)

      assert_equal id, ctx[:jobs].stop(id, session: "s1")
      refute zombie?(pid), "the stop must collect the child it ended"
      # and the handle is fully closed: the stream has ended, so the collect
      # that hands over its last words is also the one that closes the row out
      assert_equal :exited, ctx[:jobs].collect(id, session: "s1")[:status]
      assert_raises(Terret::Exec::NoSuchJob) { ctx[:jobs].collect(id, session: "s1") }
    end
  end

  # The same corpse, met by disposal instead of by a stop. One job that cannot
  # be signalled must not strand the ledger behind it — emit isolates the
  # raise, so the agent is disposed and its live jobs keep running with nothing
  # left in the harness able to name them.
  def test_a_finished_job_first_in_the_ledger_does_not_strand_the_jobs_behind_it
    Dir.mktmpdir do |dir|
      ctx, = boot
      _dead, dead_pid = start_announcing_pid(ctx, "printf bye", dir, name: "dead", session: "a")
      await_zombie(dead_pid)
      _live, live_pid = start_announcing_pid(ctx, "sleep 60", dir, name: "live", session: "a")

      ctx.emit("agent/disposed", "a")

      refute_alive live_pid
      refute zombie?(dead_pid), "the finished job's child must be reaped, not left in the table"
    end
  end

  # The sweep is what reaches a job's own children, and it has to land while
  # the pid is provably ours — before anything reaps the leader, exactly as
  # Shell#discard sweeps before it closes.
  def test_stopping_a_job_ends_the_children_it_left_behind
    Dir.mktmpdir do |dir|
      ctx, = boot
      path = File.join(dir, "child")
      id = ctx[:jobs].start("sleep 60 & echo $! > #{path}; sleep 60", session: "s1")
      await_file(path)
      child = Integer(File.read(path))

      assert alive?(child)
      ctx[:jobs].stop(id, session: "s1")
      refute_alive child
    end
  end

  # The other branch: an earlier collect already reaped the leader while a
  # child of its own kept the pipe open. Nothing may be signalled there — the
  # pgid stopped being provably ours the moment the leader was reaped — and the
  # close must still be a clean one that ends the stream.
  def test_stopping_a_job_whose_leader_was_already_reaped_closes_cleanly
    child = nil
    Dir.mktmpdir do |dir|
      ctx, = boot
      path = File.join(dir, "child")
      id = ctx[:jobs].start("sleep 60 & echo $! > #{path}; exit 0", session: "s1")
      await_file(path)
      child = Integer(File.read(path))

      deadline = now + 5
      sleep 0.02 while ctx[:jobs].collect(id, session: "s1")[:status] != :exited && now < deadline
      assert_equal :exited, ctx[:jobs].collect(id, session: "s1")[:status],
                   "the leader never exited, so this is not the branch under test"

      assert_equal id, ctx[:jobs].stop(id, session: "s1")
      assert_equal :exited, ctx[:jobs].collect(id, session: "s1")[:status]
      assert_raises(Terret::Exec::NoSuchJob) { ctx[:jobs].collect(id, session: "s1") }
    end
  ensure
    begin
      Process.kill("KILL", child) if child
    rescue Errno::ESRCH
      nil
    end
  end

  # -- the cap ----------------------------------------------------------------

  def test_starting_past_the_cap_is_refused_with_the_limit_that_bit
    ctx, = boot(config: { max_jobs: 2 })
    2.times { ctx[:jobs].start("sleep 30", session: "s1") }

    err = assert_raises(Terret::Exec::JobLimit) { ctx[:jobs].start("sleep 30", session: "s1") }
    assert_match(/max_jobs: 2/, err.message)
    assert_kind_of Terret::Tools::Failure, err
  end

  def test_the_cap_defaults_to_eight
    ctx, = boot
    8.times { ctx[:jobs].start("sleep 30", session: "s1") }
    assert_raises(Terret::Exec::JobLimit) { ctx[:jobs].start("sleep 30", session: "s1") }
  end

  def test_the_cap_counts_one_sessions_jobs_only
    ctx, = boot(config: { max_jobs: 1 })
    ctx[:jobs].start("sleep 30", session: "agent-a")
    ctx[:jobs].start("sleep 30", session: "agent-b") # must not raise
    assert_raises(Terret::Exec::JobLimit) { ctx[:jobs].start("sleep 30", session: "agent-a") }
  end

  # A buffer nobody collects is the failure mode the cap exists to make
  # visible, so a job is only forgotten once its last output has been handed
  # over — and that is what frees its slot.
  def test_collecting_a_finished_job_frees_its_slot
    ctx, = boot(config: { max_jobs: 1 })
    id = ctx[:jobs].start("printf done", session: "s1")
    drain_to_exit(ctx, id)

    ctx[:jobs].start("sleep 30", session: "s1") # must not raise
  end

  def test_stopping_a_job_does_not_free_its_slot_until_its_output_is_collected
    ctx, = boot(config: { max_jobs: 1 })
    id = ctx[:jobs].start("sleep 30", session: "s1")
    ctx[:jobs].stop(id, session: "s1")

    assert_raises(Terret::Exec::JobLimit) { ctx[:jobs].start("sleep 30", session: "s1") }
    ctx[:jobs].collect(id, session: "s1")
    ctx[:jobs].start("sleep 30", session: "s1") # must not raise
  end

  # -- failing closed ---------------------------------------------------------

  def test_an_unknown_id_fails_closed
    ctx, = boot
    err = assert_raises(Terret::Exec::NoSuchJob) { ctx[:jobs].collect("job-nope", session: "s1") }
    assert_kind_of Terret::Tools::Failure, err
    assert_match(/job-nope/, err.message)
  end

  # Which of "never existed", "already closed out" and "belongs to somebody
  # else" is true is not information one session should be able to learn about
  # another's jobs.
  def test_another_sessions_job_id_fails_closed_and_leaves_that_job_alone
    ctx, = boot
    id, pid = start_with_pid(ctx, "sleep 30", session: "agent-a")

    assert_raises(Terret::Exec::NoSuchJob) { ctx[:jobs].collect(id, session: "agent-b") }
    assert_raises(Terret::Exec::NoSuchJob) { ctx[:jobs].stop(id, session: "agent-b") }
    assert alive?(pid), "another session's process must still be running"
    assert_equal :running, ctx[:jobs].collect(id, session: "agent-a")[:status]
  end

  def test_an_owner_key_is_the_same_owner_whether_given_as_a_symbol_or_a_string
    ctx, = boot
    id = ctx[:jobs].start("sleep 30", session: :agent)
    assert_equal :running, ctx[:jobs].collect(id, session: "agent")[:status]
  end

  # -- disposal ---------------------------------------------------------------

  # Per-agent runtime that no registration owns: fork disposal never reaches
  # this root-mounted state, so without the listener every disposed agent
  # leaks its jobs.
  def test_jobs_are_reaped_when_their_agent_is_disposed
    ctx, = boot
    id, pid = start_with_pid(ctx, "sleep 30", session: "agent-a")
    _other, other_pid = start_with_pid(ctx, "sleep 30", session: "agent-b")

    ctx.emit("agent/disposed", "agent-a")

    refute_alive pid
    assert alive?(other_pid), "another agent's job must survive"
    assert_raises(Terret::Exec::NoSuchJob) { ctx[:jobs].collect(id, session: "agent-a") }
  end

  def test_unloading_the_row_reaps_every_job
    ctx, loader = boot
    _a, pid_a = start_with_pid(ctx, "sleep 30", session: "agent-a")
    _b, pid_b = start_with_pid(ctx, "sleep 30", session: "agent-b")

    loader.unload!("jobs")

    refute_alive pid_a
    refute_alive pid_b
  end

  # -- the reactor ------------------------------------------------------------

  # The headline promise, and the one the drain fiber could quietly break: a
  # transient task on the root does not hold the reactor open, so the turn
  # that started the job ends while the job carries on — and the job is still
  # collectible once the reactor that spawned it has gone quiet.
  def test_a_job_outlives_the_turn_that_started_it
    skip "async is not installed on this host" unless ASYNC_AVAILABLE

    ctx, = boot
    id = nil
    started = now
    Async { id = ctx[:jobs].start("printf started; sleep 0.3; printf finished", session: "s1") }.wait

    assert_operator now - started, :<, 0.3, "the reactor waited for the job instead of leaving it running"
    output, result = drain_to_exit(ctx, id)
    assert_equal "startedfinished", output
    assert_equal 0, result[:exit_status]
  end

  # A pipe holds about 64KB before a writer blocks on it. Nothing collects
  # this job until it is over, so the only thing that can keep it moving is a
  # fiber draining it as it fills — and that fiber must not hold the reactor
  # while it does, which is what the sibling's ticks are here to prove.
  def test_a_job_writing_more_than_a_pipe_buffer_is_drained_while_it_runs
    skip "async is not installed on this host" unless ASYNC_AVAILABLE

    Dir.mktmpdir do |dir|
      ctx, = boot
      flag = File.join(dir, "written")
      ticks = 0
      output = nil

      Async do |task|
        id = ctx[:jobs].start("#{RUBY} -e 'print \"y\" * 400_000'; touch #{flag}", session: "s1")
        ticker = task.async do
          loop do
            ticks += 1
            sleep 0.02
          end
        end
        sleep 0.02 while !File.exist?(flag) && ticks < 250
        ticker.stop
        output = ctx[:jobs].collect(id, session: "s1")[:output]
      end

      assert File.exist?(flag), "the job never finished writing; nothing was draining its pipe"
      assert_equal 400_000, output.bytesize
      assert ticks > 2, "the drain must park the fiber, not hold the reactor"
    end
  end

  private

  # Collects until the job reports that it has exited, accumulating what each
  # window handed over. Bounded, so a job that never ends fails the assertion
  # instead of hanging the suite.
  def drain_to_exit(ctx, id, session: "s1", timeout: 5)
    deadline = now + timeout
    output = +""
    loop do
      r = ctx[:jobs].collect(id, session: session)
      output << r[:output]
      return [output, r] if r[:status] == :exited

      flunk "the job never exited" if now > deadline
      sleep 0.02
    end
  end
end
