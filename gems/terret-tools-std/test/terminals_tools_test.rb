# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/terret/tools_std"
require_relative "../../terret-exec/lib/terret/exec" # the seams these tools stand on

class TerminalToolsTest < Minitest::Test
  ROSTER = %w[terminal_open terminal_input terminal_read terminal_close].freeze

  def boot(config: {}, extra_rows: [])
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "sandbox", plugin: Terret::Exec::SandboxNone },
      { id: "subprocess", plugin: Terret::Exec::Subprocess },
      { id: "terminals", plugin: Terret::Exec::Terminals, config: config },
      { id: "tools", plugin: Terret::Tools::Registry },
      { id: "std_terminals", plugin: Terret::ToolsStd::Terminals },
      *extra_rows
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

  def call(ctx, name, session_id: "s1", **args)
    ctx[:tools].execute(
      Terret::Tools::Call.new(id: "c1", name: name, args: args, session_id: session_id), ctx: ctx
    )
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # Bounded, like the seam's own tests: a terminal that never says the
  # expected thing fails the assertion instead of hanging the suite.
  def read_until(ctx, name, marker, session_id: "s1", timeout: 5)
    deadline = now + timeout
    seen = +""
    while now < deadline
      chunk = call(ctx, "terminal_read", session_id: session_id, name: name).content.to_s
      seen << chunk unless chunk == "(nothing to read)"
      break if seen.include?(marker)
    end
    seen
  end

  # -- what the definitions claim --------------------------------------------

  def test_the_roster_is_the_four_terminal_tools
    ctx, = boot
    assert_equal ROSTER.sort, ctx[:tools].schemas.map { |s| s[:name] }.sort
  end

  def test_every_terminal_tool_is_mutating_and_governed_by_policy
    ctx, = boot
    ROSTER.each do |name|
      d = ctx[:tools].fetch(name)
      assert d.mutating, "#{name} mutating"
      assert_equal :policy, d.approval, "#{name} approval"
      assert_equal :serial, d.concurrency, "#{name} concurrency"
      refute_empty d.description, "#{name} description"
    end
  end

  def test_the_registrations_die_with_the_row_that_made_them
    ctx, loader = boot
    refute_empty ctx[:tools].schemas

    loader.unload!("std_terminals")
    assert_empty ctx[:tools].schemas, "a tool registered by a plugin row must not outlive the row"
  end

  # -- end to end ------------------------------------------------------------

  def test_open_write_read_close_drives_a_live_terminal
    ctx, = boot
    opened = call(ctx, "terminal_open", name: "echoer", argv: ["cat"])
    assert_nil opened.error
    assert_match(/echoer/, opened.content)

    assert_nil call(ctx, "terminal_input", name: "echoer", text: "hello\n").error
    assert_match(/hello/, read_until(ctx, "echoer", "hello"))

    closed = call(ctx, "terminal_close", name: "echoer")
    assert_nil closed.error
    assert_match(/echoer/, closed.content)

    gone = call(ctx, "terminal_read", name: "echoer")
    assert_nil gone.content
    assert_match(/no terminal named echoer is open/, gone.error)
  end

  def test_a_terminal_with_nothing_to_say_says_so
    ctx, = boot
    call(ctx, "terminal_open", name: "quiet", argv: ["cat"])
    assert_equal "(nothing to read)", call(ctx, "terminal_read", name: "quiet").content
  end

  def test_closing_a_name_that_is_not_open_is_not_an_error
    ctx, = boot
    result = call(ctx, "terminal_close", name: "never-opened")
    assert_nil result.error, "the seam makes this a no-op; the tool must not invent a failure"
    assert_match(/never-opened/, result.content)
  end

  # -- ownership -------------------------------------------------------------

  # Names are scoped per owner on the seam, and the owner is the call's
  # session. A tool that lost that would let one agent read — or close — a
  # live process belonging to another.
  def test_one_session_cannot_reach_anothers_terminal
    ctx, = boot
    call(ctx, "terminal_open", name: "repl", argv: ["cat"], session_id: "agent-a")

    stolen = call(ctx, "terminal_read", name: "repl", session_id: "agent-b")
    assert_match(/no terminal named repl is open/, stolen.error)

    mine = call(ctx, "terminal_open", name: "repl", argv: ["cat"], session_id: "agent-b")
    assert_nil mine.error, "the same name in another session is a different terminal"
  end

  def test_reopening_a_name_this_session_already_holds_is_refused
    ctx, = boot
    call(ctx, "terminal_open", name: "repl", argv: ["cat"])

    again = call(ctx, "terminal_open", name: "repl", argv: ["cat"])
    assert_nil again.content
    assert_equal "a terminal named repl is already open", again.error
    refute_match(/Terret|Failure/, again.error, "a Failure renders message-only")
  end

  def test_opening_past_the_cap_is_refused_with_the_limit_that_bit
    ctx, = boot(config: { max_terminals: 1 })
    call(ctx, "terminal_open", name: "one", argv: ["cat"])

    result = call(ctx, "terminal_open", name: "two", argv: ["cat"])
    assert_nil result.content
    assert_match(/max_terminals: 1/, result.error)
  end

  # -- refusals the spawn path raises ----------------------------------------

  # A missing binary raises Errno::ENOENT out of the spawn. Left alone it
  # would render with its class name attached, which tells a model about
  # Ruby's exception hierarchy instead of about its own mistake.
  def test_opening_a_binary_that_does_not_exist_is_a_refusal_not_a_crash
    ctx, = boot
    result = call(ctx, "terminal_open", name: "ghost", argv: ["terret-no-such-binary"])

    assert_nil result.content
    assert_match(/terret-no-such-binary/, result.error)
    refute_match(/Errno|ENOENT/, result.error, "the model gets a sentence, not an errno")
    assert_empty ctx[:terminals].close_all_for("s1"), "a spawn that failed must leave no row behind"
  end

  # A spawn can fail for reasons other than a missing binary, and every one of
  # them is the model's argv to fix. "Errno::EACCES: Permission denied - fork
  # failed" tells it the harness broke — the fork did not fail, the exec did —
  # so it retries instead of correcting itself.
  def test_opening_a_file_that_is_not_executable_is_a_refusal
    ctx, = boot
    Dir.mktmpdir do |dir|
      path = File.join(dir, "script.sh")
      File.write(path, "#!/bin/sh\necho hi\n")
      File.chmod(0o644, path)

      result = call(ctx, "terminal_open", name: "ghost", argv: [path])
      assert_nil result.content
      assert_match(/not executable/, result.error)
      refute_match(/Errno|fork failed/, result.error, "the fork did not fail; the exec did")
    end
  end

  def test_opening_a_directory_is_a_refusal
    ctx, = boot
    Dir.mktmpdir do |dir|
      result = call(ctx, "terminal_open", name: "ghost", argv: [dir])
      assert_nil result.content
      assert_match(/#{Regexp.escape(dir)}/, result.error)
      refute_match(/Errno|fork failed/, result.error)
    end
  end

  def test_an_empty_argv_is_refused_before_anything_is_spawned
    ctx, = boot
    result = call(ctx, "terminal_open", name: "ghost", argv: [])

    assert_nil result.content
    assert_match(/argv/, result.error)
    refute_match(/TypeError/, result.error)
  end

  # Stringifying would turn a nil the model did not mean into an empty
  # argument the kernel accepts, and the terminal would open around a command
  # nobody wrote.
  def test_an_argv_element_that_is_not_a_string_is_refused_rather_than_stringified
    ctx, = boot
    result = call(ctx, "terminal_open", name: "ghost", argv: ["echo", nil])

    assert_nil result.content
    refute_match(/TypeError/, result.error)
    assert_empty ctx[:terminals].close_all_for("s1"), "a malformed argv opens nothing"
  end

  # -- a terminal whose process is gone --------------------------------------

  def test_reading_a_terminal_whose_process_has_ended_says_so_and_keeps_the_name
    ctx, = boot
    call(ctx, "terminal_open", name: "brief", argv: ["bash", "-c", "exit 0"])

    deadline = now + 5
    content = ""
    content = call(ctx, "terminal_read", name: "brief").content.to_s while now < deadline &&
                                                                          !content.include?("ended")

    assert_match(/ended/, content, "a dead child is not the same answer as a quiet one")
    assert_match(/Closed terminal brief/, call(ctx, "terminal_close", name: "brief").content,
                 "reading is not disposal: the name is still the owner's to close")
  end

  # -- the two tools that can destroy another agent's process ----------------

  def test_one_session_cannot_type_into_anothers_terminal
    ctx, = boot
    call(ctx, "terminal_open", name: "repl", argv: ["cat"], session_id: "agent-a")

    result = call(ctx, "terminal_input", name: "repl", text: "rm -rf /\n", session_id: "agent-b")
    assert_nil result.content
    assert_match(/no terminal named repl is open/, result.error)
  end

  def test_one_session_cannot_close_anothers_terminal
    ctx, = boot
    opened = call(ctx, "terminal_open", name: "repl", argv: ["cat"], session_id: "agent-a")
    pid = Integer(opened.content[/pid (\d+)/, 1])

    result = call(ctx, "terminal_close", name: "repl", session_id: "agent-b")
    assert_nil result.error, "closing a name you do not hold is the seam's no-op"
    assert_match(/No terminal named repl was open/, result.content)
    assert alive?(pid), "another session's process must still be running"

    assert_match(/Closed terminal repl/,
                 call(ctx, "terminal_close", name: "repl", session_id: "agent-a").content,
                 "and its owner can still close it")
  end

  # -- bytes a child wrote that are not text ---------------------------------

  # The session log refuses invalid UTF-8 at the durable append boundary, and
  # the seam deliberately preserves whatever the child wrote. Scrubbing is
  # this layer's job, and the proof is the append itself.
  def test_reading_invalid_utf8_still_produces_a_storable_result
    rows = [{ id: "session_store", plugin: Terret::Store::Memory },
            { id: "sessions", plugin: Terret::Sessions }]
    ctx, = boot(extra_rows: rows)
    call(ctx, "terminal_open", name: "binary", argv: ["bash", "-c", "printf '\\xff\\xfe'; sleep 30"])

    deadline = now + 5
    content = ""
    while now < deadline
      content = call(ctx, "terminal_read", name: "binary").content.to_s
      break unless content == "(nothing to read)"
    end

    assert content.valid_encoding?, "the tool's result must be storable text"
    session = ctx[:sessions].create
    ctx[:sessions].append(session.id, "tool/result", { id: "c1", content: content, error: nil })
    assert_equal content, ctx[:sessions].fetch(session.id).events.last.payload[:content]
  end
end
