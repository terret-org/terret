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

class SubprocessTest < Minitest::Test
  RUBY = RbConfig.ruby

  # Records every wrap, and returns an argv that is observably different from
  # the one handed in: `env TERRET_WRAPPED=1 ...` still runs the original
  # command, so a child printing `ENV["TERRET_WRAPPED"]` proves the wrapped
  # argv is what actually became a process — not merely that #wrap was called.
  class ProbeSandbox < Terret::Exec::SandboxNone
    def calls = @calls ||= []

    def wrap(argv, cwd:)
      calls << { argv: argv, cwd: cwd }
      ["env", "TERRET_WRAPPED=1", *argv]
    end
  end

  def boot(sandbox: Terret::Exec::SandboxNone, config: {})
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "sandbox", plugin: sandbox, config: {} },
      { id: "subprocess", plugin: Terret::Exec::Subprocess, config: config }
    ])
    [loader.boot!, loader]
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # A pid we reaped is gone outright, so signal 0 finds nothing to signal.
  def refute_alive(pid)
    alive = begin
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end
    refute alive, "pid #{pid} is still alive"
  end

  # Bounded so a handle that never yields the expected bytes fails the
  # assertion instead of hanging the suite.
  def read_until(handle, marker, timeout: 5)
    deadline = now + timeout
    seen = +""
    until seen.include?(marker) || now > deadline
      chunk = handle.read(256, timeout: 0.05)
      break if chunk.nil?

      seen << chunk
    end
    seen
  end

  # -- capture --------------------------------------------------------------

  def test_spawn_captures_stdout_and_a_zero_status
    ctx, = boot
    r = ctx[:subprocess].spawn([RUBY, "-e", "print 'hi'"])
    assert_equal 0, r.status
    assert_equal "hi", r.stdout
    assert_equal "", r.stderr
  end

  def test_spawn_captures_stderr_separately_from_stdout
    ctx, = boot
    r = ctx[:subprocess].spawn([RUBY, "-e", "STDOUT.print 'out'; STDERR.print 'err'"])
    assert_equal "out", r.stdout
    assert_equal "err", r.stderr
  end

  def test_a_non_zero_exit_is_captured_not_raised
    ctx, = boot
    r = ctx[:subprocess].spawn([RUBY, "-e", "STDERR.print 'boom'; exit 3"])
    assert_equal 3, r.status
    assert_equal "boom", r.stderr
  end

  def test_output_larger_than_a_pipe_buffer_is_captured_whole
    ctx, = boot
    r = ctx[:subprocess].spawn([RUBY, "-e", "print 'x' * 500_000; STDERR.print 'y' * 500_000"])
    assert_equal 500_000, r.stdout.bytesize
    assert_equal 500_000, r.stderr.bytesize
  end

  def test_captured_output_is_readable_utf8
    ctx, = boot
    r = ctx[:subprocess].spawn([RUBY, "-e", "print 'héllo ✓'"])
    assert_equal "héllo ✓", r.stdout
    assert_equal Encoding::UTF_8, r.stdout.encoding
  end

  # -- cwd, env, stdin ------------------------------------------------------

  def test_spawn_runs_in_the_given_cwd
    Dir.mktmpdir do |dir|
      ctx, = boot
      r = ctx[:subprocess].spawn([RUBY, "-e", "print Dir.pwd"], cwd: dir)
      assert_equal File.realpath(dir), File.realpath(r.stdout)
    end
  end

  def test_the_given_env_merges_into_the_inherited_one
    ctx, = boot
    r = ctx[:subprocess].spawn([RUBY, "-e", "print ENV['TERRET_T'], '|', ENV['PATH'].to_s.empty?"],
                               env: { "TERRET_T" => "set" })
    assert_equal "set|false", r.stdout
  end

  def test_stdin_is_fed_to_the_child
    ctx, = boot
    r = ctx[:subprocess].spawn([RUBY, "-e", "print STDIN.read.upcase"], stdin: "hi")
    assert_equal "HI", r.stdout
  end

  def test_stdin_defaults_to_an_immediate_eof
    ctx, = boot
    r = ctx[:subprocess].spawn([RUBY, "-e", "print STDIN.read.bytesize"])
    assert_equal "0", r.stdout
  end

  def test_a_stdin_payload_larger_than_a_pipe_buffer_does_not_deadlock
    ctx, = boot
    r = ctx[:subprocess].spawn([RUBY, "-e", "print STDIN.read.bytesize"], stdin: "z" * 300_000)
    assert_equal "300000", r.stdout
  end

  # -- timeout and signal escalation ----------------------------------------

  def test_a_timeout_terminates_the_child_and_says_so
    Dir.mktmpdir do |dir|
      pidfile = File.join(dir, "pid")
      ctx, = boot
      r = ctx[:subprocess].spawn([RUBY, "-e", "File.write(ARGV[0], Process.pid); sleep 30", pidfile],
                                 timeout: 0.4)
      assert_nil r.status
      assert_match(/timed out/, r.stderr)
      assert_match(/SIGTERM/, r.stderr)

      refute_alive Integer(File.read(pidfile))
    end
  end

  def test_a_child_that_ignores_term_is_killed_after_the_grace
    Dir.mktmpdir do |dir|
      pidfile = File.join(dir, "pid")
      ctx, = boot(config: { term_grace: 0.1 })
      script = "Signal.trap('TERM') {}; File.write(ARGV[0], Process.pid); sleep 30"
      r = ctx[:subprocess].spawn([RUBY, "-e", script, pidfile], timeout: 0.4)
      assert_nil r.status
      assert_match(/timed out/, r.stderr)
      assert_match(/SIGKILL/, r.stderr)

      refute_alive Integer(File.read(pidfile))
    end
  end

  def test_a_timed_out_child_still_reports_the_output_it_produced
    ctx, = boot
    r = ctx[:subprocess].spawn([RUBY, "-e", "STDOUT.sync = true; print 'partial'; sleep 30"], timeout: 0.4)
    assert_equal "partial", r.stdout
    assert_match(/timed out/, r.stderr)
  end

  def test_a_child_that_finishes_inside_the_timeout_is_untouched
    ctx, = boot
    r = ctx[:subprocess].spawn([RUBY, "-e", "print 'quick'"], timeout: 5)
    assert_equal 0, r.status
    assert_equal "quick", r.stdout
    assert_equal "", r.stderr
  end

  # -- the sandbox seam -----------------------------------------------------

  def test_every_spawned_argv_passes_through_the_sandbox_wrap
    Dir.mktmpdir do |dir|
      ctx, = boot(sandbox: ProbeSandbox)
      argv = [RUBY, "-e", "print ENV['TERRET_WRAPPED'].to_s"]
      r = ctx[:subprocess].spawn(argv, cwd: dir)

      assert_equal "1", r.stdout, "the wrapped argv, not the original, must become the process"
      assert_equal [{ argv: argv, cwd: dir }], ctx[:sandbox].calls
    end
  end

  def test_every_pty_argv_passes_through_the_sandbox_wrap
    Dir.mktmpdir do |dir|
      ctx, = boot(sandbox: ProbeSandbox)
      argv = [RUBY, "-e", "STDOUT.sync = true; print 'W', ENV['TERRET_WRAPPED'].to_s"]
      handle = ctx[:subprocess].pty_spawn(argv, cwd: dir)
      begin
        assert_includes read_until(handle, "W1"), "W1",
                        "the wrapped argv, not the original, must become the pty process"
        assert_equal [{ argv: argv, cwd: dir }], ctx[:sandbox].calls
      ensure
        handle.close
      end
    end
  end

  # -- pty ------------------------------------------------------------------

  def test_pty_spawn_round_trips_a_line
    ctx, = boot
    handle = ctx[:subprocess].pty_spawn(["cat"])
    begin
      handle.write("hello\n")
      assert_includes read_until(handle, "hello"), "hello"
    ensure
      handle.close
    end
  end

  def test_a_pty_handle_exposes_its_pid_and_close_reaps_the_child
    ctx, = boot
    handle = ctx[:subprocess].pty_spawn(["cat"])
    pid = handle.pid
    assert_kind_of Integer, pid
    assert_equal 1, Process.kill(0, pid), "the child should be alive before close"

    handle.close
    refute_alive pid
  end

  def test_closing_a_pty_handle_twice_is_harmless
    ctx, = boot
    handle = ctx[:subprocess].pty_spawn(["cat"])
    handle.close
    handle.close
    refute_alive handle.pid
  end

  def test_a_bounded_pty_read_returns_empty_rather_than_blocking_forever
    ctx, = boot
    handle = ctx[:subprocess].pty_spawn(["cat"])
    begin
      assert_equal "", handle.read(64, timeout: 0.1)
    ensure
      handle.close
    end
  end

  def test_a_pty_read_reports_eof_once_the_child_is_gone
    ctx, = boot
    handle = ctx[:subprocess].pty_spawn([RUBY, "-e", "exit 0"])
    begin
      deadline = now + 5
      chunk = +""
      chunk = handle.read(256, timeout: 0.05) while chunk && now < deadline
      assert_nil chunk, "a pty whose child has exited must read as EOF, not stall"
    ensure
      handle.close
    end
  end

  # -- fiber cooperation ----------------------------------------------------
  #
  # One reactor, no user-facing threads (plan §8): a call here that parked the
  # THREAD rather than the fiber would stall every other agent in the process
  # on the first slow child. The ticker is the probe. These two use the
  # unbounded read/wait paths deliberately — a poll loop with its own sleep
  # would park the fiber whether or not the underlying call cooperates, and
  # would prove nothing.

  def test_a_slow_child_does_not_stall_another_fiber
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
      result = ctx[:subprocess].spawn([RUBY, "-e", "sleep 0.4; print 'done'"])
      ticker.stop
    end

    assert_equal "done", result.stdout
    assert_operator ticks, :>, 5, "the ticker fiber stopped while the child ran"
  end

  def test_a_slow_pty_read_does_not_stall_another_fiber
    skip "async not installed" unless ASYNC_AVAILABLE

    ctx, = boot
    ticks = 0
    seen = +""
    Sync do |task|
      ticker = task.async do
        loop do
          ticks += 1
          sleep 0.01
        end
      end
      handle = ctx[:subprocess].pty_spawn([RUBY, "-e", "STDOUT.sync = true; sleep 0.4; print 'late'"])
      begin
        # with_timeout turns a fiber that never wakes into a failed assertion
        # rather than a hung suite; it can only fire if the read parked.
        task.with_timeout(10) do
          until seen.include?("late")
            chunk = handle.read(256)
            break if chunk.nil?

            seen << chunk
          end
        end
      ensure
        handle.close
        ticker.stop
      end
    end

    assert_includes seen, "late"
    assert_operator ticks, :>, 5, "the ticker fiber stopped while the pty read blocked"
  end
end
