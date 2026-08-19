# frozen_string_literal: true

require "minitest/autorun"
require "json"
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

  # Whatever the shell asks to spawn, it gets a process that exits at once —
  # the shape of a bash that is not installed, or a container that refuses.
  class DeadShellSandbox < Terret::Exec::SandboxNone
    def wrap(_argv, cwd:) = [RbConfig.ruby, "-e", "exit 0"]
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

  # A handshake rather than a fixed sleep: the child writes its pid as its
  # first act, so waiting for the file is waiting for the child to exist.
  def await_pidfile(path, timeout: 5)
    deadline = now + timeout
    sleep 0.02 while (!File.exist?(path) || File.read(path).empty?) && now < deadline
    Integer(File.read(path))
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

  # -- the output cap -------------------------------------------------------

  def test_output_past_the_cap_is_truncated_and_the_run_still_completes
    ctx, = boot(config: { max_output: 4096 })
    r = ctx[:shell].run(%(#{RUBY} -e "print 'x' * 200_000"))

    assert_equal 0, r.status, "the run must still reach its marker and report the real status"
    assert_equal 4096, r.stdout.bytesize
    assert_match(/truncated/, r.notice)
    assert_match(/4096/, r.notice, "the notice must say how much was kept")
    assert_match(/195904/, r.notice, "the notice must say how much was dropped, exactly")
  end

  def test_a_run_inside_the_cap_carries_no_truncation_notice
    ctx, = boot(config: { max_output: 4096 })
    assert_nil ctx[:shell].run("echo small").notice
  end

  def test_the_session_is_still_usable_after_a_truncated_run
    ctx, = boot(config: { max_output: 4096 })
    ctx[:shell].run(%(#{RUBY} -e "print 'x' * 200_000"))

    assert_equal "after\n", ctx[:shell].run("echo after").stdout
  end

  def test_a_cap_smaller_than_the_marker_window_still_finds_the_marker
    ctx, = boot(config: { max_output: 8 })
    r = ctx[:shell].run(%(#{RUBY} -e "print 'x' * 50_000"))

    assert_equal 0, r.status
    assert_equal 8, r.stdout.bytesize
  end

  # The cap is a byte offset and characters are not bytes. Bytes the CHILD
  # emitted that were never valid UTF-8 still round-trip untouched; what must
  # never happen is this seam manufacturing invalid bytes by cutting a valid
  # character in half — a durable append JSON-encodes the payload, and a
  # half-character raises there rather than at the seam that made it.
  def test_a_multibyte_flood_is_never_cut_into_invalid_utf8
    ctx, = boot(config: { max_output: 1000 })
    r = ctx[:shell].run(%(#{RUBY} -e "print '日' * 400")) # 1200 bytes, cut lands mid-character

    assert_equal 0, r.status
    assert r.stdout.valid_encoding?, "the cap must not manufacture invalid UTF-8"
    JSON.generate({ stdout: r.stdout }) # what the append boundary does; raises on a broken string
    assert_equal 999, r.stdout.bytesize, "the cut backs off to the last whole character"
    assert_equal 333, r.stdout.length
    assert_match(/201/, r.notice, "the backed-off bytes count as dropped, exactly")
  end

  # When a command's output ends inside a marker's length of the cap, the
  # marker BEGINS inside the kept region. Reporting the kept region verbatim
  # would hand the model the session's sentinel — the one value the protocol's
  # forgery resistance rests on — and leave the dropped count negative.
  def test_output_ending_just_short_of_the_cap_never_leaks_the_sentinel
    [20, 30, 39].each do |slack|
      ctx, = boot(config: { max_output: 100 })
      size = 100 - slack
      r = ctx[:shell].run(%(#{RUBY} -e "print 'x' * #{size}"))

      assert_equal 0, r.status, "slack #{slack}"
      refute_includes r.stdout, "TERRET", "protocol bytes reported as output (slack #{slack})"
      assert_equal size, r.stdout.bytesize, "slack #{slack}"
      assert_nil r.notice, "nothing was dropped at #{size} bytes of output"
    end
  end

  def test_output_exactly_filling_the_cap_with_its_marker_stays_clean
    ctx, = boot(config: { max_output: 100 })
    r = ctx[:shell].run(%(#{RUBY} -e "print 'x' * 60")) # 60 + a 40-byte marker == the cap

    assert_equal 0, r.status
    assert_equal "x" * 60, r.stdout
    assert_nil r.notice
  end

  # Both adjustments in one run: the cap cut lands inside the marker while the
  # marker itself begins inside the kept region. The reported output has to end
  # on a character boundary AND carry none of the protocol.
  def test_a_multibyte_run_whose_marker_straddles_the_cap_stays_clean
    ctx, = boot(config: { max_output: 100 })
    r = ctx[:shell].run(%(#{RUBY} -e "print '日' * 30")) # 90 bytes, marker begins at 90

    assert_equal 0, r.status
    assert r.stdout.valid_encoding?
    refute_includes r.stdout, "TERRET"
    assert_equal 90, r.stdout.bytesize
    assert_equal "日" * 30, r.stdout
    assert_nil r.notice
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

  # -- background jobs ------------------------------------------------------
  #
  # A `&` job outlives the command that started it by definition, so nothing
  # about the run's own end reaps it. It must not outlive the SESSION: it holds
  # the agent's authority and, once the shell is gone, nothing in the harness
  # is left holding a reference to it.

  def test_a_backgrounded_child_dies_with_the_session
    Dir.mktmpdir do |dir|
      pidfile = File.join(dir, "pid")
      ctx, = boot
      ctx[:shell].run(%(#{RUBY} -e "File.write(ARGV[0], Process.pid); sleep 45" #{pidfile} &))
      pid = await_pidfile(pidfile)
      assert alive?(pid), "the background child should be running before disposal"

      ctx[:shell].close_all
      refute_alive pid
    end
  end

  def test_a_backgrounded_child_dies_when_a_timeout_restarts_the_session
    Dir.mktmpdir do |dir|
      pidfile = File.join(dir, "pid")
      ctx, = boot
      ctx[:shell].run(%(#{RUBY} -e "File.write(ARGV[0], Process.pid); sleep 45" #{pidfile} &))
      pid = await_pidfile(pidfile)

      ctx[:shell].run("sleep 30", timeout: 0.5) # kills the session and respawns
      refute_alive pid
    end
  end

  # Turning job control off does NOT silence the job-start notice: bash still
  # announces a background job, and the line is written to the terminal by the
  # shell itself, indistinguishable from what the command wrote. It is reported
  # as output rather than filtered, so this pins what a caller actually sees.
  def test_backgrounding_a_job_reports_bashs_own_job_notice_as_output
    ctx, = boot
    r = ctx[:shell].run("sleep 5 &")

    assert_equal 0, r.status
    assert_match(/\A\[1\] \d+\n\z/, r.stdout)
  end

  def test_a_backgrounded_child_dies_when_its_session_alone_is_closed
    Dir.mktmpdir do |dir|
      pidfile = File.join(dir, "pid")
      ctx, = boot
      ctx[:shell].run(%(#{RUBY} -e "File.write(ARGV[0], Process.pid); sleep 45" #{pidfile} &),
                      session: "agent-a")
      pid = await_pidfile(pidfile)
      ctx[:shell].run("true", session: "agent-b")
      pid_b = ctx[:shell].pid(session: "agent-b")

      ctx[:shell].close(session: "agent-a")
      refute_alive pid
      assert alive?(pid_b), "another session's shell must survive"
    end
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

  def test_close_all_twice_is_harmless
    ctx, = boot
    ctx[:shell].run("true", session: "a")
    ctx[:shell].close_all
    ctx[:shell].close_all # must not raise

    assert_nil ctx[:shell].pid(session: "a")
  end

  def test_a_shell_that_never_answers_its_handshake_is_a_typed_failure
    ctx, = boot(sandbox: DeadShellSandbox)
    err = assert_raises(Terret::Exec::ShellUnavailable) { ctx[:shell].run("echo hi") }

    assert_kind_of Terret::Tools::Failure, err
    assert_nil ctx[:shell].pid, "a session that never became usable must not be held"
    # the in-flight guard has to be released on the raising path too, or the
    # next attempt would report the wrong thing entirely
    assert_raises(Terret::Exec::ShellUnavailable) { ctx[:shell].run("echo hi") }
  end

  def test_unloading_the_row_reaps_every_live_session
    ctx, loader = boot
    ctx[:shell].run("true", session: "a")
    ctx[:shell].run("true", session: "b")
    pids = [ctx[:shell].pid(session: "a"), ctx[:shell].pid(session: "b")]

    loader.unload!("shell")
    pids.each { |pid| refute_alive pid }
  end

  # -- one command at a time ------------------------------------------------
  #
  # One bash per key means two commands cannot be in flight on it at once, and
  # the seam's guarantee is that the result handed back is the caller's own
  # command's result. Nothing in today's sequential loop dispatch can reach
  # this, but ctx[:shell] is a public seam and `concurrency:` is declared
  # metadata the tool barrier does not enforce yet, so the guarantee has to
  # live here rather than in a caller's habits.

  def test_a_second_run_on_a_session_already_running_a_command_is_refused
    skip "async not installed" unless ASYNC_AVAILABLE

    ctx, = boot
    ctx[:shell].run("true") # warm it, so the refusal is about the run and not the spawn
    err = nil
    slow = nil
    Sync do |task|
      running = task.async { ctx[:shell].run("sleep 0.5; echo slow") }
      sleep 0.1 # let the first run park inside its read, so it is genuinely in flight
      err = assert_raises(Terret::Exec::ShellBusy) { ctx[:shell].run("echo second") }
      slow = running.wait
    end

    assert_kind_of Terret::Tools::Failure, err
    assert_match(/default/, err.message, "the refusal must name the session it is about")
    assert_equal "slow\n", slow.stdout, "the in-flight run must be unaffected by the refusal"
  end

  def test_a_session_takes_runs_again_once_the_in_flight_one_has_finished
    skip "async not installed" unless ASYNC_AVAILABLE

    ctx, = boot
    Sync do |task|
      running = task.async { ctx[:shell].run("sleep 0.3; echo slow") }
      sleep 0.1
      assert_raises(Terret::Exec::ShellBusy) { ctx[:shell].run("echo second") }
      running.wait
    end

    assert_equal "after\n", ctx[:shell].run("echo after").stdout
  end

  def test_another_session_key_runs_while_one_key_is_busy
    skip "async not installed" unless ASYNC_AVAILABLE

    ctx, = boot
    Sync do |task|
      running = task.async { ctx[:shell].run("sleep 0.5; echo slow", session: "a") }
      sleep 0.1
      assert_equal "b\n", ctx[:shell].run("echo b", session: "b").stdout
      assert_equal "slow\n", running.wait.stdout
    end
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
