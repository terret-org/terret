# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/terret/tools_std"
require_relative "../../terret-exec/lib/terret/exec" # the seams these tools stand on

class BashToolTest < Minitest::Test
  # Stands in for the docker provider (plan §12): a sandbox whose verdict is
  # a config knob, so a row swap can flip `isolated?` hot without a second
  # plugin class. `reconfigure` is defined because the verdict is read live —
  # there is nothing captured to re-derive, and the base class would otherwise
  # warn that this row needs a remount.
  class ConfiguredSandbox < Terret::Exec::SandboxNone
    def isolated? = config.fetch(:isolated, false)
    def reconfigure(_config); end
  end

  # A shell that only ever refuses, so the seam's typed failures can be seen
  # arriving at the pipeline. It is the real ShellBusy — a stub must not be
  # allowed to invent a friendlier contract than the seam's.
  class BusyShell < Hames::Service
    service_key :shell

    def start(_ctx); end
    def close_all; end

    def run(_cmd, session: nil, timeout: nil)
      raise Terret::Exec::ShellBusy, "the #{session} shell session is already running a command"
    end
  end

  def boot(sandbox: Terret::Exec::SandboxNone, sandbox_config: {}, config: {},
           shell: Terret::Exec::Shell, shell_config: {}, extra_rows: [])
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "sandbox", plugin: sandbox, config: sandbox_config },
      { id: "subprocess", plugin: Terret::Exec::Subprocess },
      { id: "shell", plugin: shell, config: shell_config },
      { id: "tools", plugin: Terret::Tools::Registry },
      { id: "std_bash", plugin: Terret::ToolsStd::Bash, config: config },
      *extra_rows
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

  # Every call goes through the pipeline, never straight at a handler: policy
  # listens on tools/pre_execute, so a tool proven only by calling its block
  # is a tool proven outside the thing that governs it. The session on the
  # Call is the one the handler has to end up running under.
  def call(ctx, name, session_id: "s1", **args)
    ctx[:tools].execute(
      Terret::Tools::Call.new(id: "c1", name: name, args: args, session_id: session_id), ctx: ctx
    )
  end

  # -- running ---------------------------------------------------------------

  def test_bash_runs_a_command_through_the_shell_seam
    ctx, = boot
    result = call(ctx, "Bash", command: "echo hi")
    assert_nil result.error
    assert_equal "hi\n", result.content, "a clean run renders the command's bytes and nothing else"
  end

  def test_the_shell_keeps_its_state_between_two_calls_in_one_session
    ctx, = boot
    call(ctx, "Bash", command: "cd /tmp && export FOO=bar")

    result = call(ctx, "Bash", command: "echo \"$FOO $(pwd)\"")
    assert_nil result.error
    assert_match(/bar/, result.content, "an export from the previous call is still in effect")
    assert_match(%r{/tmp}, result.content, "a cd from the previous call is still in effect")
  end

  # The session key is the whole reason the handler needs the call's session:
  # one agent's cwd must not be another's.
  def test_two_sessions_do_not_share_a_shell
    ctx, = boot
    call(ctx, "Bash", command: "cd /tmp", session_id: "agent-a")

    result = call(ctx, "Bash", command: "pwd", session_id: "agent-b")
    refute_match(%r{^/tmp$}, result.content.strip,
                 "a second session must get its own shell, not the first one's cwd")
  end

  def test_a_non_zero_status_is_reported_rather_than_passed_off_as_success
    ctx, = boot
    result = call(ctx, "Bash", command: "(exit 3)")
    assert_nil result.error, "a command that failed still ran; that is a result, not a tool error"
    assert_match(/exit status 3/, result.content)
  end

  def test_no_output_says_so_rather_than_rendering_nothing
    ctx, = boot
    assert_equal "(no output)", call(ctx, "Bash", command: "true").content
  end

  # -- the notice ------------------------------------------------------------

  # The seam carries restart and truncation facts in a field of their own so
  # that stdout stays exactly what the terminal carried. A tool that rendered
  # only stdout would swallow both.
  def test_a_timed_out_run_shows_the_restart_notice_after_the_output_it_got
    ctx, = boot
    result = call(ctx, "Bash", command: "echo before; sleep 30", timeout: 500)

    assert_nil result.error
    assert result.content.start_with?("before\n"),
           "the command's own bytes come first, untouched: #{result.content.inspect}"
    assert_match(/timed out after 0.5s/, result.content)
    assert_match(/fresh session/, result.content, "the model has to learn the cwd is gone")
    assert_match(/^--- terret ---$/, result.content, "the notice is separated from the output")
  end

  def test_the_session_really_did_restart_after_a_timeout
    ctx, = boot
    call(ctx, "Bash", command: "cd /tmp")
    call(ctx, "Bash", command: "sleep 30", timeout: 500)

    result = call(ctx, "Bash", command: "pwd")
    refute_match(%r{^/tmp$}, result.content.strip, "the notice said the cwd was gone; it must be gone")
  end

  # -- the tool's own cap ----------------------------------------------------

  def test_output_past_max_output_is_truncated_with_a_marker_line
    ctx, = boot(config: { max_output: 200 })
    result = call(ctx, "Bash", command: "printf 'a%.0s' $(seq 1 1000)")

    assert_nil result.error
    assert_equal "a" * 200, result.content.lines.first.chomp[0, 200]
    assert_match(/kept the first 200 bytes of rendered output and dropped 800 more/, result.content)
    assert_match(/^--- terret ---$/, result.content)
  end

  def test_the_cap_defaults_to_30_000_bytes
    ctx, = boot
    result = call(ctx, "Bash", command: "printf 'a%.0s' $(seq 1 40000)")
    assert_match(/kept the first 30000 bytes of rendered output and dropped 10000 more/, result.content)
  end

  def test_a_swapped_row_governs_the_very_next_call
    ctx, loader = boot(config: { max_output: 200 })
    loader.reconfigure!("std_bash", { max_output: 50 })

    result = call(ctx, "Bash", command: "printf 'a%.0s' $(seq 1 1000)")
    assert_match(/kept the first 50 bytes of rendered output and dropped 950 more/, result.content)
  end

  # -- the model's own arguments ---------------------------------------------

  # Everything a model writes arrives as JSON it typed, so these are ordinary
  # inputs rather than exotic ones: the tool has to answer them, not crash on
  # them and leave the turn to guess what happened.
  def test_a_timeout_written_as_a_string_is_coerced_rather_than_crashing
    ctx, = boot
    result = call(ctx, "Bash", command: "echo before; sleep 30", timeout: "500")

    assert_nil result.error
    assert_match(/timed out after 0.5s/, result.content)
  end

  def test_a_timeout_that_is_not_a_number_is_refused
    ctx, = boot
    result = call(ctx, "Bash", command: "echo hi", timeout: "abc")

    assert_nil result.content
    assert_equal "timeout must be a whole number of milliseconds", result.error
    refute_match(/NoMethodError|ArgumentError/, result.error, "a Failure renders message-only")
  end

  # A zero or negative timeout used to fire instantly, which killed the shell
  # the model was working in and reported "timed out after 0.0s" — the worst
  # possible answer, since the damage was to the caller's own session state.
  def test_a_non_positive_timeout_falls_back_to_the_default_instead_of_killing_the_session
    ctx, = boot
    call(ctx, "Bash", command: "cd /tmp")

    [0, -5].each do |ms|
      result = call(ctx, "Bash", command: "echo hi", timeout: ms)
      assert_nil result.error, "timeout: #{ms}"
      assert_equal "hi\n", result.content, "timeout: #{ms} must not fire immediately"
    end

    assert_match(%r{/tmp}, call(ctx, "Bash", command: "pwd").content,
                 "a bad argument must not cost the model the session it was working in")
  end

  def test_a_non_positive_max_output_cannot_crash_every_call
    ctx, = boot(config: { max_output: -1 })
    result = call(ctx, "Bash", command: "echo hi")

    assert_nil result.error, "a nonsense cap degrades to showing nothing; it does not crash"
    assert_match(/kept the first 0 bytes/, result.content)
  end

  # -- bytes a child wrote that are not text ---------------------------------

  # The session log refuses invalid UTF-8 at the durable append boundary, and
  # the seam deliberately preserves whatever the child wrote. Scrubbing is
  # this layer's job, and the proof is the append itself, not an assertion
  # about encodings.
  def test_a_child_emitting_invalid_utf8_still_produces_a_storable_result
    rows = [{ id: "session_store", plugin: Terret::Store::Memory },
            { id: "sessions", plugin: Terret::Sessions }]
    ctx, = boot(extra_rows: rows)
    result = call(ctx, "Bash", command: "printf '\\xff\\xfe'")

    assert_nil result.error
    assert result.content.valid_encoding?, "the tool's result must be storable text"

    session = ctx[:sessions].create
    ctx[:sessions].append(session.id, "tool/result",
                          { id: result.id, content: result.content, error: result.error })
    assert_equal result.content, ctx[:sessions].fetch(session.id).events.last.payload[:content]
  end

  # -- what the definition claims --------------------------------------------

  def test_bash_needs_a_human_every_time_outside_a_sandbox
    ctx, = boot
    d = ctx[:tools].fetch("Bash")
    assert_equal :always, d.approval, "unsandboxed, arbitrary shell needs a human"
    assert d.mutating
    assert_equal :serial, d.concurrency
    assert_match(/persist/i, d.description, "the model has to know the shell keeps its state")
  end

  def test_bash_is_governed_like_any_other_mutating_tool_inside_a_sandbox
    ctx, = boot(sandbox: ConfiguredSandbox, sandbox_config: { isolated: true })
    assert_equal :policy, ctx[:tools].fetch("Bash").approval
  end

  def test_a_hot_sandbox_swap_re_registers_bash_with_the_freshly_derived_approval
    ctx, loader = boot(sandbox: ConfiguredSandbox, sandbox_config: { isolated: false })
    assert_equal :always, ctx[:tools].fetch("Bash").approval

    loader.reconfigure!("sandbox", { isolated: true })
    assert_equal :policy, ctx[:tools].fetch("Bash").approval,
                 "an approval captured at registration must not outlive the sandbox it was derived from"

    loader.reconfigure!("sandbox", { isolated: false })
    assert_equal :always, ctx[:tools].fetch("Bash").approval, "and back, when the sandbox goes away"
  end

  def test_the_re_registered_bash_still_runs
    ctx, loader = boot(sandbox: ConfiguredSandbox, sandbox_config: { isolated: false })
    loader.reconfigure!("sandbox", { isolated: true })

    assert_equal "hi\n", call(ctx, "Bash", command: "echo hi").content
    assert_equal 1, ctx[:tools].schemas.count { |s| s[:name] == "Bash" },
                 "re-registration replaces the definition rather than doubling it"
  end

  def test_the_registration_dies_with_the_row_that_made_it
    ctx, loader = boot
    refute_empty ctx[:tools].schemas

    loader.unload!("std_bash")
    assert_empty ctx[:tools].schemas, "a tool registered by a plugin row must not outlive the row"
  end

  # The trap in re-registering from an event listener: the loader's
  # config/updated emit runs outside `with_owner`, so a registration made
  # there is ownerless unless the row keeps hold of it — and an ownerless
  # Bash would outlive the row that mounted it, holding shell authority
  # nothing in the harness could still reach.
  def test_the_registration_still_dies_with_the_row_after_a_hot_swap
    ctx, loader = boot(sandbox: ConfiguredSandbox, sandbox_config: { isolated: false })
    loader.reconfigure!("sandbox", { isolated: true })

    loader.unload!("std_bash")
    assert_empty ctx[:tools].schemas, "a re-registered tool must still belong to its row"
  end

  # -- refusals --------------------------------------------------------------

  def test_a_seam_failure_renders_as_a_refusal_rather_than_a_crash
    ctx, = boot(shell: BusyShell)
    result = call(ctx, "Bash", command: "echo hi")

    assert_nil result.content
    assert_equal "the s1 shell session is already running a command", result.error
    refute_match(/Terret|Failure|ShellBusy/, result.error, "a Failure renders message-only")
  end
end
