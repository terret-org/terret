# frozen_string_literal: true

require "minitest/autorun"
require "rbconfig"
require "tmpdir"
require_relative "../lib/terret/exec"

ASYNC_AVAILABLE = begin
  require "async"
  true
rescue LoadError
  false
end unless defined?(ASYNC_AVAILABLE)

class ShellTest < Minitest::Test
  RUBY = RbConfig.ruby

  # Records every wrap and returns an observably different argv, so a test can
  # tell "the sandbox was consulted" from "the wrapped argv is what actually
  # became a process" (the same probe subprocess_test uses).
  class ProbeSandbox < Terret::Exec::SandboxNone
    def calls = @calls ||= []

    def wrap(argv, cwd:)
      calls << { argv: argv, cwd: cwd }
      ["env", "TERRET_WRAPPED=1", *argv]
    end
  end

  def boot(config: {}, sandbox: Terret::Exec::SandboxNone)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "sandbox", plugin: sandbox, config: {} },
      { id: "subprocess", plugin: Terret::Exec::Subprocess, config: {} },
      { id: "shell", plugin: Terret::Exec::Shell, config: config }
    ])
    ctx = loader.boot!
    @booted << ctx
    [ctx, loader]
  end

  def setup = @booted = []

  # Every test leaves its bash processes reaped even when an assertion fails
  # part-way through: a leaked persistent shell would outlive the whole suite.
  def teardown
    @booted.each { |ctx| ctx[:shell].close_all if ctx.service?(:shell) }
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

  # -- one command ----------------------------------------------------------

  def test_run_returns_the_commands_exact_output_and_a_zero_status
    ctx, = boot
    r = ctx[:shell].run("echo hi")
    assert_equal 0, r.status
    assert_equal "hi\n", r.stdout, "stdout must be the command's bytes, with no echo, prompt, or CR"
    assert_nil r.notice
  end

  def test_output_without_a_trailing_newline_is_not_padded
    ctx, = boot
    assert_equal "no-newline", ctx[:shell].run("printf no-newline").stdout
  end

  def test_a_command_producing_no_output_returns_an_empty_string
    ctx, = boot
    r = ctx[:shell].run("true")
    assert_equal "", r.stdout
    assert_equal 0, r.status
  end

  def test_a_failing_commands_status_is_captured_rather_than_raised
    ctx, = boot
    # a subshell, so the failing status does not end the session itself
    r = ctx[:shell].run("(exit 3)")
    assert_equal 3, r.status
    assert_equal "", r.stdout
  end

  def test_stderr_arrives_on_the_same_stream_as_stdout
    ctx, = boot
    # a terminal has one stream; this is documented, not accidental
    assert_equal "oops\n", ctx[:shell].run("echo oops >&2").stdout
  end

  def test_a_multi_line_command_runs_as_one_unit
    ctx, = boot
    assert_equal "a\nb\n", ctx[:shell].run("echo a\necho b").stdout
  end

  def test_a_loop_producing_several_lines_is_captured_whole
    ctx, = boot
    assert_equal "1\n2\n3\n", ctx[:shell].run("for i in 1 2 3; do echo $i; done").stdout
  end

  def test_output_larger_than_a_terminal_buffer_is_captured_whole
    ctx, = boot
    r = ctx[:shell].run("#{RUBY} -e 'print \"x\" * 200_000'")
    assert_equal 0, r.status
    assert_equal 200_000, r.stdout.bytesize
  end

  def test_a_command_line_longer_than_the_terminals_line_buffer_survives
    ctx, = boot
    # a canonical-mode terminal caps a line at MAX_CANON (1024 on macOS)
    r = ctx[:shell].run("echo #{'a' * 4000}")
    assert_equal 0, r.status
    assert_equal "#{'a' * 4000}\n", r.stdout
  end

  # -- persistence ----------------------------------------------------------

  def test_cwd_and_exported_variables_persist_across_runs
    Dir.mktmpdir do |dir|
      ctx, = boot
      ctx[:shell].run("cd #{dir} && export FOO=bar")
      # pwd -P, and a realpath comparison: on macOS /tmp and /var are symlinks
      r = ctx[:shell].run("echo $FOO $(pwd -P)")
      assert_equal "bar #{File.realpath(dir)}\n", r.stdout
    end
  end

  def test_a_shell_variable_set_without_export_also_persists
    ctx, = boot
    ctx[:shell].run("COUNT=1")
    assert_equal "1\n", ctx[:shell].run("echo $COUNT").stdout
  end

  def test_sessions_keyed_differently_hold_independent_state
    ctx, = boot
    ctx[:shell].run("export WHO=one", session: "agent-a")
    ctx[:shell].run("export WHO=two", session: "agent-b")
    assert_equal "one\n", ctx[:shell].run("echo $WHO", session: "agent-a").stdout
    assert_equal "two\n", ctx[:shell].run("echo $WHO", session: "agent-b").stdout
  end

  def test_a_session_key_is_the_same_session_whether_given_as_a_symbol_or_a_string
    ctx, = boot
    ctx[:shell].run("export WHO=sym", session: :agent)
    assert_equal "sym\n", ctx[:shell].run("echo $WHO", session: "agent").stdout
  end

  def test_the_session_starts_in_the_configured_cwd
    Dir.mktmpdir do |dir|
      ctx, = boot(config: { cwd: dir })
      assert_equal "#{File.realpath(dir)}\n", ctx[:shell].run("pwd -P").stdout
    end
  end

  def test_the_configured_env_reaches_the_session
    ctx, = boot(config: { env: { "TERRET_SHELL_T" => "set" } })
    assert_equal "set\n", ctx[:shell].run("echo $TERRET_SHELL_T").stdout
  end

  # -- timeout --------------------------------------------------------------

  def test_a_timeout_reports_no_status_and_says_the_session_was_killed
    ctx, = boot
    r = ctx[:shell].run("sleep 30", timeout: 0.5)
    assert_nil r.status, "an exit code we do not have must not be reported as one"
    assert_match(/timed out/, r.notice)
    assert_match(/fresh/, r.notice)
  end

  def test_a_timeout_kills_the_command_the_shell_was_running
    Dir.mktmpdir do |dir|
      pidfile = File.join(dir, "pid")
      ctx, = boot
      script = "File.write(ARGV[0], Process.pid); sleep 30"
      r = ctx[:shell].run(%(#{RUBY} -e "#{script}" #{pidfile}), timeout: 1.5)

      assert_nil r.status, "the run has to have actually timed out for this to prove anything"
      refute_alive Integer(File.read(pidfile))
    end
  end

  def test_the_session_survives_a_timeout_by_restarting_fresh
    ctx, = boot
    ctx[:shell].run("export KEPT=yes")
    ctx[:shell].run("sleep 30", timeout: 0.5)

    r = ctx[:shell].run("echo [$KEPT]")
    assert_equal 0, r.status, "the next run must get a working shell"
    assert_equal "[]\n", r.stdout, "the restarted shell must not carry the dead one's state"
  end

  def test_a_timed_out_run_reports_the_output_the_command_managed_to_produce
    ctx, = boot
    r = ctx[:shell].run("echo partial; sleep 30", timeout: 1.0)
    assert_equal "partial\n", r.stdout
    assert_nil r.status
  end

  # -- a session that ends on its own ---------------------------------------

  def test_a_command_that_ends_the_shell_reports_no_status_and_says_so
    ctx, = boot
    r = ctx[:shell].run("exit")
    assert_nil r.status
    assert_match(/ended/, r.notice)
  end

  def test_a_shell_that_exited_between_runs_respawns_and_says_so
    ctx, = boot
    ctx[:shell].run("export KEPT=yes")
    pid = ctx[:shell].pid
    Process.kill("KILL", pid)
    Process.wait(pid) # reap it here, so nothing races the service's own reaper

    r = ctx[:shell].run("echo [$KEPT]")
    assert_equal 0, r.status
    assert_equal "[]\n", r.stdout
    assert_match(/exited/, r.notice)
  end

  def test_output_a_background_job_wrote_between_runs_is_not_charged_to_the_next_command
    ctx, = boot
    # the outer subshell is not interactive, so backgrounding inside it prints
    # no job-control notice; the stray line lands on the terminal well after
    # this run's own sentinel has been read
    ctx[:shell].run("( (sleep 0.3; echo stray) & )")
    sleep 0.6
    assert_equal "clean\n", ctx[:shell].run("echo clean").stdout
  end

  # -- disposal -------------------------------------------------------------

  def test_close_reaps_one_session_and_leaves_the_others_alone
    ctx, = boot
    ctx[:shell].run("true", session: "a")
    ctx[:shell].run("true", session: "b")
    pid_a = ctx[:shell].pid(session: "a")
    pid_b = ctx[:shell].pid(session: "b")

    ctx[:shell].close(session: "a")
    refute_alive pid_a
    assert alive?(pid_b), "closing one session must not touch another"
  end

  def test_closing_an_unknown_session_is_harmless
    ctx, = boot
    assert_nil ctx[:shell].close(session: "never-opened")
  end

  def test_pid_is_nil_until_a_session_has_run_something
    ctx, = boot
    assert_nil ctx[:shell].pid(session: "cold")
    ctx[:shell].run("true", session: "cold")
    assert_kind_of Integer, ctx[:shell].pid(session: "cold")
  end

  def test_unloading_the_row_reaps_every_live_session
    ctx, loader = boot
    ctx[:shell].run("true", session: "a")
    ctx[:shell].run("true", session: "b")
    pids = [ctx[:shell].pid(session: "a"), ctx[:shell].pid(session: "b")]

    loader.unload!("shell")
    pids.each { |pid| refute_alive pid }
  end

  # -- the sandbox seam -----------------------------------------------------

  def test_the_bash_argv_becomes_a_process_only_through_the_sandbox_wrap
    ctx, = boot(sandbox: ProbeSandbox)
    r = ctx[:shell].run("echo $TERRET_WRAPPED")

    assert_equal "1\n", r.stdout, "the shell must reach bash through subprocess, never around it"
    assert_equal 1, ctx[:sandbox].calls.length, "one session, one wrapped spawn"
  end

  # -- fiber cooperation ----------------------------------------------------
  #
  # One reactor, no user-facing threads (plan §8): a shell run that parked the
  # THREAD would stall every other agent on the first slow command.

  def test_a_slow_run_does_not_stall_another_fiber
    skip "async not installed" unless ASYNC_AVAILABLE

    ctx, = boot
    ticks = 0
    result = nil
    Sync do |task|
      ticker = task.async do
        loop do
          ticks += 1
          sleep 0.01
        end
      end
      result = ctx[:shell].run("sleep 0.4; echo late")
      ticker.stop
    end

    assert_equal "late\n", result.stdout
    assert_operator ticks, :>, 5, "the ticker fiber stopped while the shell ran"
  end
end
