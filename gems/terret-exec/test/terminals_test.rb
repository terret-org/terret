# frozen_string_literal: true

require "minitest/autorun"
require "rbconfig"
require "tmpdir"
require_relative "../lib/terret/exec"

class TerminalsTest < Minitest::Test
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

  def boot(config: {}, sandbox: Terret::Exec::SandboxNone, subprocess_config: {})
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "sandbox", plugin: sandbox, config: {} },
      { id: "subprocess", plugin: Terret::Exec::Subprocess, config: subprocess_config },
      { id: "terminals", plugin: Terret::Exec::Terminals, config: config }
    ])
    ctx = loader.boot!
    @booted << ctx
    [ctx, loader]
  end

  def setup = @booted = []

  # A terminal is a live process held across turns, so a test that fails
  # part-way through must still not leak one into the rest of the suite.
  def teardown
    @booted.each { |ctx| ctx[:terminals].close_all if ctx.service?(:terminals) }
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def refute_alive(pid, timeout: 5)
    deadline = now + timeout
    sleep 0.02 while alive?(pid) && now < deadline
    refute alive?(pid), "pid #{pid} is still alive"
  end

  # Bounded, like subprocess_test's: a terminal that never says the expected
  # thing fails the assertion instead of hanging the suite.
  def read_until(ctx, name, marker, session: nil, timeout: 5)
    deadline = now + timeout
    seen = +""
    until seen.include?(marker) || now > deadline
      chunk = session.nil? ? ctx[:terminals].read(name) : ctx[:terminals].read(name, session: session)
      break if chunk.nil?

      seen << chunk
    end
    seen
  end

  # -- open, input, read, close ---------------------------------------------

  def test_open_registers_a_named_terminal_and_reports_its_pid
    ctx, = boot
    t = ctx[:terminals].open("repl", ["cat"])
    assert_equal "repl", t.name
    assert_kind_of Integer, t.pid
    assert alive?(t.pid)
  end

  def test_input_and_read_round_trip_against_the_named_terminal
    ctx, = boot
    ctx[:terminals].open("repl", ["cat"])
    ctx[:terminals].input("repl", "hello\n")
    assert_includes read_until(ctx, "repl", "hello"), "hello"
  end

  def test_reading_an_idle_terminal_returns_empty_rather_than_blocking
    ctx, = boot
    ctx[:terminals].open("repl", ["cat"])
    assert_equal "", ctx[:terminals].read("repl")
  end

  def test_reading_reports_eof_once_the_child_is_gone
    ctx, = boot
    ctx[:terminals].open("brief", [RUBY, "-e", "exit 0"])
    deadline = now + 5
    chunk = +""
    chunk = ctx[:terminals].read("brief") while chunk && now < deadline
    assert_nil chunk, "a terminal whose child has exited must read as EOF, not stall"
  end

  def test_a_terminal_opens_in_the_given_cwd
    Dir.mktmpdir do |dir|
      ctx, = boot
      ctx[:terminals].open("here", [RUBY, "-e", "STDOUT.sync = true; print Dir.pwd"], cwd: dir)
      assert_includes read_until(ctx, "here", File.realpath(dir)), File.realpath(dir)
    end
  end

  def test_close_reaps_the_child
    ctx, = boot
    t = ctx[:terminals].open("repl", ["cat"])
    ctx[:terminals].close("repl")
    refute_alive t.pid
  end

  # A shell killed while its terminal still holds bytes nobody read gets stuck
  # in exit, and the handle's reaper then waits on a child that never
  # finishes. If this regresses it shows up as a hung close rather than a
  # failed assertion, which is precisely why it is worth pinning.
  def test_closing_a_terminal_holding_output_nobody_read_does_not_wedge
    ctx, = boot(subprocess_config: { term_grace: 0.2 })
    t = ctx[:terminals].open("noisy", ["bash", "--norc", "--noprofile", "--noediting", "-s"])
    ctx[:terminals].input("noisy", "echo unread\n")
    sleep 0.3

    ctx[:terminals].close("noisy")
    refute_alive t.pid
  end

  def test_close_is_idempotent
    ctx, = boot
    ctx[:terminals].open("repl", ["cat"])
    ctx[:terminals].close("repl")
    ctx[:terminals].close("repl") # must not raise
  end

  def test_closing_a_name_that_was_never_opened_is_harmless
    ctx, = boot
    assert_nil ctx[:terminals].close("never-opened")
  end

  # -- refusals -------------------------------------------------------------

  def test_input_to_an_unknown_terminal_is_refused
    ctx, = boot
    err = assert_raises(Terret::Exec::NoSuchTerminal) { ctx[:terminals].input("ghost", "hi\n") }
    assert_match(/ghost/, err.message)
    assert_kind_of Terret::Tools::Failure, err
  end

  def test_input_to_a_terminal_whose_child_is_gone_is_refused
    ctx, = boot
    ctx[:terminals].open("brief", [RUBY, "-e", "exit 0"])
    deadline = now + 5
    chunk = +""
    chunk = ctx[:terminals].read("brief") while chunk && now < deadline
    assert_nil chunk, "the child has to be gone before this proves anything"

    err = assert_raises(Terret::Exec::TerminalGone) { ctx[:terminals].input("brief", "hi\n") }
    assert_kind_of Terret::Tools::Failure, err
    assert_match(/brief/, err.message)
  end

  def test_close_all_twice_is_harmless
    ctx, = boot
    ctx[:terminals].open("repl", ["cat"])
    ctx[:terminals].close_all
    ctx[:terminals].close_all # must not raise
  end

  def test_reading_an_unknown_terminal_is_refused
    ctx, = boot
    assert_raises(Terret::Exec::NoSuchTerminal) { ctx[:terminals].read("ghost") }
  end

  def test_reopening_a_live_name_is_refused_rather_than_clobbering_the_process
    ctx, = boot
    t = ctx[:terminals].open("repl", ["cat"])
    assert_raises(Terret::Exec::TerminalExists) { ctx[:terminals].open("repl", ["cat"]) }
    assert alive?(t.pid), "the terminal already open under that name must be untouched"
  end

  # -- the cap --------------------------------------------------------------

  def test_opening_past_the_cap_is_refused
    ctx, = boot(config: { max_terminals: 2 })
    ctx[:terminals].open("one", ["cat"])
    ctx[:terminals].open("two", ["cat"])
    err = assert_raises(Terret::Exec::TerminalLimit) { ctx[:terminals].open("three", ["cat"]) }
    assert_match(/2/, err.message)
    assert_kind_of Terret::Tools::Failure, err
  end

  def test_the_cap_defaults_to_eight
    ctx, = boot
    8.times { |i| ctx[:terminals].open("t#{i}", ["cat"]) }
    assert_raises(Terret::Exec::TerminalLimit) { ctx[:terminals].open("t8", ["cat"]) }
  end

  def test_closing_frees_a_slot_against_the_cap
    ctx, = boot(config: { max_terminals: 1 })
    ctx[:terminals].open("one", ["cat"])
    ctx[:terminals].close("one")
    ctx[:terminals].open("two", ["cat"]) # must not raise
  end

  def test_the_cap_counts_one_owners_terminals_only
    ctx, = boot(config: { max_terminals: 1 })
    ctx[:terminals].open("repl", ["cat"], session: "agent-a")
    ctx[:terminals].open("repl", ["cat"], session: "agent-b") # must not raise
    assert_raises(Terret::Exec::TerminalLimit) { ctx[:terminals].open("other", ["cat"], session: "agent-a") }
  end

  # -- ownership ------------------------------------------------------------

  def test_the_same_name_under_two_owners_is_two_terminals
    ctx, = boot
    a = ctx[:terminals].open("repl", ["cat"], session: "agent-a")
    b = ctx[:terminals].open("repl", ["cat"], session: "agent-b")
    refute_equal a.pid, b.pid

    ctx[:terminals].input("repl", "for-a\n", session: "agent-a")
    assert_includes read_until(ctx, "repl", "for-a", session: "agent-a"), "for-a"
    assert_equal "", ctx[:terminals].read("repl", session: "agent-b"),
                 "one owner's input must never reach another owner's terminal of the same name"
  end

  def test_an_owner_cannot_reach_another_owners_terminal_by_name
    ctx, = boot
    ctx[:terminals].open("repl", ["cat"], session: "agent-a")
    assert_raises(Terret::Exec::NoSuchTerminal) { ctx[:terminals].input("repl", "hi\n", session: "agent-b") }
  end

  def test_an_owner_key_is_the_same_owner_whether_given_as_a_symbol_or_a_string
    ctx, = boot
    ctx[:terminals].open("repl", ["cat"], session: :agent)
    assert_raises(Terret::Exec::TerminalExists) { ctx[:terminals].open("repl", ["cat"], session: "agent") }
  end

  # -- disposal -------------------------------------------------------------

  def test_close_all_for_reaps_every_terminal_that_key_owns_and_no_others
    ctx, = boot
    a1 = ctx[:terminals].open("one", ["cat"], session: "agent-a")
    a2 = ctx[:terminals].open("two", ["cat"], session: "agent-a")
    b1 = ctx[:terminals].open("one", ["cat"], session: "agent-b")

    closed = ctx[:terminals].close_all_for("agent-a")
    assert_equal %w[one two], closed.sort
    refute_alive a1.pid
    refute_alive a2.pid
    assert alive?(b1.pid), "another owner's terminal must survive an agent's disposal"
  end

  def test_close_all_for_an_owner_with_nothing_open_is_harmless
    ctx, = boot
    assert_equal [], ctx[:terminals].close_all_for("agent-with-none")
  end

  def test_close_all_for_frees_the_owners_slots
    ctx, = boot(config: { max_terminals: 1 })
    ctx[:terminals].open("one", ["cat"], session: "agent-a")
    ctx[:terminals].close_all_for("agent-a")
    ctx[:terminals].open("two", ["cat"], session: "agent-a") # must not raise
  end

  def test_unloading_the_row_reaps_every_open_terminal
    ctx, loader = boot
    pids = [ctx[:terminals].open("one", ["cat"], session: "agent-a").pid,
            ctx[:terminals].open("two", ["cat"], session: "agent-b").pid]

    loader.unload!("terminals")
    pids.each { |pid| refute_alive pid }
  end

  # -- the sandbox seam -----------------------------------------------------

  def test_a_terminals_argv_becomes_a_process_only_through_the_sandbox_wrap
    ctx, = boot(sandbox: ProbeSandbox)
    argv = [RUBY, "-e", "STDOUT.sync = true; print 'W', ENV['TERRET_WRAPPED'].to_s"]
    ctx[:terminals].open("probe", argv)

    assert_includes read_until(ctx, "probe", "W1"), "W1",
                    "a terminal must reach a process through subprocess, never around it"
    assert_equal [argv], ctx[:sandbox].calls.map { |c| c[:argv] }
  end
end
