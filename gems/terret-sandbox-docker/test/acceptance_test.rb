# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "securerandom"
require_relative "../lib/terret/sandbox/docker"                # ctx[:sandbox] — the container provider
require_relative "../../terret-exec/lib/terret/exec"           # fs, sandbox-none, subprocess, shell, terminals (+ terret-core)
require_relative "../../terret-tools-std/lib/terret/tools_std" # Read/Write/Bash/terminal_* on those seams

ASYNC_AVAILABLE = begin
  require "async"
  true
rescue LoadError
  false
end unless defined?(ASYNC_AVAILABLE)

# THE ACCEPTANCE (plan §12): "one patch row moves Bash, Read, Write, and PTY
# into a container with ZERO tool changes." This is that criterion, made
# literal. Two boots of the SAME execution world — one array of rows, built
# once and handed to both loaders — differ by exactly one thing: the docker
# boot appends a single sandbox patch row (§7 layering, a second `loader.layer`
# call whose `id: "sandbox"` swaps SandboxNone for the docker provider). Then it
# proves the tools behave identically except that their processes now run inside
# the container.
#
# ZERO TOOL CHANGES is not asserted by inspection, it is enforced: both boots
# mount the identical Terret::ToolsStd::Files / Bash / Terminals service classes
# imported above — there is no second roster and no per-world tool code — and
# the roster diff below proves every Definition is field-for-field identical
# across the two boots save the ONE value the sandbox is allowed to move: Bash's
# §13 approval (`:always` unsandboxed, `:policy` sandboxed). Every handler even
# came from the same source_location, so the same block ran in both worlds.
#
# The discriminator is container membership, which is OS-independent: a Bash
# probe of /.dockerenv — a file the docker runtime creates inside every
# container and that exists on no host — reads ON-HOST locally and IN-CONTAINER
# under docker, and that inequality is the whole proof the world moved. It holds
# whatever the host OS is: on a Linux runner (the live CI lane) both kernels
# report "Linux", so a `uname` comparison could not tell the worlds apart, but
# ON-HOST still differs from IN-CONTAINER. `uname` is kept as corroborating
# evidence, exact rather than substring — the local world genuinely sees the
# host kernel, the docker world genuinely sees the container's "Linux".
# The shell sentinel must appear in NEITHER (the tty-wrapped-pty regression the
# Task 12 work fixed); the Write/Read round-trip must hold in BOTH worlds on the
# same workspace file (ctx[:fs] writes through the bind mount, so one world);
# and a cat PTY must echo in both, proving the terminal tools survived the move.
#
# If the tools do NOT behave identically — if anything other than Bash's
# approval differs, or the container path breaks a tool — the assertion is the
# finding. It must not be weakened to make the headline "pass"; a false
# acceptance is the worst outcome this file can produce.
#
# Docker-gated, like the rest of the gem: a machine without the daemon skips
# clean rather than failing, and every container this drives is swept by label
# on teardown so none survives even a mid-run failure.
class SandboxAcceptanceTest < Minitest::Test
  # Overridable so a machine that would rather not pull ruby:slim can point the
  # suite at any Debian-ish image carrying bash and uname.
  IMAGE = ENV.fetch("TERRET_DOCKER_TEST_IMAGE", "ruby:slim")

  # Asked once per process: `docker info` is a daemon round-trip and the answer
  # cannot change mid-suite.
  DOCKER = system("docker", "info", out: File::NULL, err: File::NULL)

  LABEL = "terret-sandbox"

  def setup
    @booted = []
    @workspace = nil
    # What was already on this machine. Everything the sweep is allowed to
    # remove is measured against this, so a developer running the suite beside a
    # real terret container keeps it.
    @preexisting = DOCKER ? containers_labelled : []
    return unless DOCKER

    # The first wrap of a cold machine pays a `ruby:slim` pull — minutes, during
    # which nothing else runs. Doing it here rather than lazily inside the first
    # Bash call keeps the pull cost out of the boot timing (a no-op when the
    # image is already local, which is the ordinary case).
    unless system("docker", "image", "inspect", IMAGE, out: File::NULL, err: File::NULL)
      system("docker", "pull", IMAGE, out: File::NULL, err: File::NULL)
    end
  end

  # Cleanup on every path, including a failed or raising test. The provider's
  # own #stop is what should have removed each container; the label sweep is the
  # net that catches one it lost track of, and asserting the net came up empty
  # is what proves #stop did its job. The workspace is removed only after the
  # containers that bind-mounted it are gone.
  def teardown
    @booted.each do |ctx|
      ctx[:shell].close_all     if ctx.service?(:shell)
      ctx[:terminals].close_all if ctx.service?(:terminals)
      ctx[:sandbox].stop(nil)   if ctx.service?(:sandbox)
    rescue StandardError
      nil
    end

    leaked = []
    if DOCKER
      leaked = containers_labelled - @preexisting
      leaked.each { |id| system("docker", "rm", "-f", id, out: File::NULL, err: File::NULL) }
    end
    FileUtils.remove_entry(@workspace) if @workspace && File.directory?(@workspace)
    assert_empty leaked, "the docker sandbox left a container behind after its own stop" if DOCKER
  end

  # -- the acceptance ---------------------------------------------------------

  def test_one_appended_row_moves_the_whole_execution_world_into_a_container
    skip "docker unavailable" unless DOCKER

    # The pre-realpath workspace string, handed verbatim to BOTH the fs row and
    # the sandbox row so they resolve it the same way (on macOS /var is a
    # symlink to /private/var, and a disagreement there would make every
    # fs-produced path one the container does not have).
    @workspace = Dir.mktmpdir("terret-accept")
    raw_ws = @workspace
    ws_real = File.realpath(raw_ws)

    # Built ONCE. This same array object is what each boot layers, so the only
    # thing that can differ between the two worlds is the patch row appended
    # below — the criterion made structural.
    base_rows = build_base_rows(raw_ws)

    # -- boot 1: the local world (the identity sandbox) --
    ctx_local = boot_world(base_rows, [])
    local = exercise(ctx_local, "local", ws_real)
    refute ctx_local[:sandbox].isolated?, "SandboxNone must report itself unisolated"

    # -- boot 2: the same world + one appended sandbox patch row (§7 layering) --
    patch = [{ id: "sandbox", plugin: Terret::Sandbox::Docker,
               config: { image: IMAGE, network: "none", workspace: [raw_ws] } }]
    ctx_docker = boot_world(base_rows, patch)
    docker = exercise(ctx_docker, "docker", ws_real)
    assert ctx_docker[:sandbox].isolated?, "the docker provider must report itself isolated"
    refute_nil ctx_docker[:sandbox].container, "the docker world must have started a real container"

    # -- the discriminator: which side of the container boundary each world ran on --
    #
    # OS-independent on purpose. On this mac the kernels alone would give it away
    # (Darwin vs Linux), but the live CI lane is a Linux runner where BOTH worlds
    # report "Linux" — so kernel-name inequality would falsely read as "nothing
    # moved". /.dockerenv exists only inside a container the docker runtime
    # started and on no host, so ON-HOST vs IN-CONTAINER is the inequality that
    # holds whatever the host OS is: host uname Linux, container uname Linux, yet
    # ON-HOST still ≠ IN-CONTAINER.
    assert_equal "ON-HOST\n", local[:membership],
                 "the local world must run on the host, outside any container"
    assert_equal "IN-CONTAINER\n", docker[:membership],
                 "the docker world must run inside the container"
    refute_equal local[:membership], docker[:membership],
                 "both worlds ran on the same side of the container boundary; nothing moved"

    # `uname` corroborates, exact rather than substring: the local world
    # genuinely sees the host kernel, the docker world genuinely sees the
    # container's. These also differ on a non-Linux host and AGREE on a Linux
    # one, which is exactly why the discriminator above is membership, not this.
    host_uname = "#{`uname`.chomp}\n"
    assert_equal host_uname, local[:bash],
                 "local Bash `uname` must equal the host's own uname, exactly"
    assert_equal "Linux\n", docker[:bash],
                 "docker Bash `uname` must be Linux, exactly — not merely containing it"
    # The sentinel guard on every Bash output: the tty-wrapped pty must keep
    # stdout exact in both worlds. The pre-fix leak ALSO contained the kernel
    # name, so exactness above plus this are what make the check a real net.
    [local[:bash], docker[:bash], local[:membership], docker[:membership]].each do |out|
      refute_match(/TERRET\h{32}/, out, "the shell sentinel leaked into a Bash output: #{out.inspect}")
    end

    # -- Write/Read round-trip: identical in both worlds, same workspace file --
    assert_equal local[:written], local[:read],
                 "local Write/Read round-trip did not return what it wrote"
    assert_equal docker[:written], docker[:read],
                 "docker Write/Read round-trip did not return what it wrote"

    # -- the roster and every Definition, identical save Bash's approval --
    local_defs  = definitions(ctx_local)
    docker_defs = definitions(ctx_docker)

    assert_equal local_defs.keys.sort, docker_defs.keys.sort,
                 "the tool roster must be identical between the two boots"

    # Diff every Definition field but the handler (a Proc, whose object identity
    # is meaningless across boots; source_location below is the real check).
    diffs = local_defs.filter_map do |name, ld|
      lh = fields(ld)
      dh = fields(docker_defs.fetch(name))
      [name, { local: lh, docker: dh }] unless lh == dh
    end.to_h
    assert_equal ["Bash"], diffs.keys,
                 "only Bash may differ between the worlds; also differed: #{diffs.keys.inspect}"

    # And on Bash, the ONE field that moved is the sandbox-derived approval —
    # §13 made visible, and nothing else.
    moved = fields(local_defs.fetch("Bash")).keys.select do |k|
      fields(local_defs.fetch("Bash"))[k] != fields(docker_defs.fetch("Bash"))[k]
    end
    assert_equal [:approval], moved, "on Bash, only :approval may move; also moved: #{moved.inspect}"
    assert_equal :always, local_defs.fetch("Bash").approval,
                 "unsandboxed, arbitrary shell needs a human every time (§13)"
    assert_equal :policy, docker_defs.fetch("Bash").approval,
                 "inside the container Bash is governed like any other mutating tool (§13)"

    # Zero tool code was touched: every handler in the docker world was defined
    # at the identical file:line as its local twin, so it is literally the same
    # block — the only delta between the worlds is the appended row.
    local_defs.each do |name, ld|
      assert_equal ld.handler.source_location, docker_defs.fetch(name).handler.source_location,
                   "#{name}'s handler was defined at a different place across the boots"
    end
  end

  private

  # The execution world, minus the sandbox verdict: seams, the tool roster, and
  # the full loop driving them through a FakeAdapter. Everything a real profile
  # would mount except the one row the acceptance swaps. ctx[:shell] and
  # ctx[:terminals] are given the workspace as their cwd on purpose: their
  # default is Dir.pwd (the unmounted host repo), and under docker an unmounted
  # cwd raises Sandbox::Denied — so the same pre-realpath string that fs and the
  # sandbox get goes here too.
  def build_base_rows(raw_ws)
    [
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions",   plugin: Terret::Sessions },
      { id: "prompt",     plugin: Terret::Prompt },
      { id: "tools",      plugin: Terret::Tools::Registry },
      { id: "sandbox",    plugin: Terret::Exec::SandboxNone },
      { id: "subprocess", plugin: Terret::Exec::Subprocess },
      { id: "fs",         plugin: Terret::Exec::FS,        config: { workspace: [raw_ws] } },
      { id: "shell",      plugin: Terret::Exec::Shell,     config: { cwd: raw_ws } },
      { id: "terminals",  plugin: Terret::Exec::Terminals, config: { cwd: raw_ws } },
      { id: "std_files",     plugin: Terret::ToolsStd::Files },
      { id: "std_bash",      plugin: Terret::ToolsStd::Bash },
      { id: "std_terminals", plugin: Terret::ToolsStd::Terminals },
      { id: "llm",  plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop", plugin: Terret::Loop }
    ]
  end

  # Both worlds boot the SAME base rows; the docker world layers one more row on
  # top, which is the §7 mechanism the whole test turns on: a later layer's row
  # with an existing id ("sandbox") swaps that row's plugin and config wholesale.
  def boot_world(base_rows, patch_rows)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer(base_rows)
    loader.layer(patch_rows) unless patch_rows.empty?
    ctx = loader.boot!
    @booted << ctx
    ctx
  end

  # Drives Bash("uname"), Write and Read through a full scripted turn (the loop,
  # the pipeline, the seams, the sandbox — the whole harness moves, not just a
  # tool block), then a cat PTY round-trip through the same tool pipeline.
  # Returns the bytes each tool actually produced.
  def exercise(ctx, world, ws_real)
    probe = File.join(ws_real, "roundtrip.txt")
    written = "roundtrip written in the #{world} world\n"

    # `test -f /.dockerenv` is the OS-independent discriminator; `uname` is the
    # corroborating kernel evidence. Both go through the same persistent bash, so
    # both also exercise the tty-wrapped pty and the sentinel protocol.
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(
      [
        { text: "Running uname.",       tool_calls: [tc("u", "Bash", command: "uname")] },
        { text: "Checking membership.", tool_calls: [tc("m", "Bash",
                                                        command: "test -f /.dockerenv && echo IN-CONTAINER || echo ON-HOST")] },
        { text: "Writing.",             tool_calls: [tc("w", "Write", file_path: probe, content: written)] },
        { text: "Reading back.",        tool_calls: [tc("r", "Read",  file_path: probe)] },
        { text: "Done." }
      ]
    ))

    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    assert_equal :completed, ctx[:loop].run_turn(agent, "exercise the tools"),
                 "#{world}: the scripted turn must complete"

    results = session.events.select { |e| e.type == "tool/result" }
                     .to_h { |e| [e.payload[:id], e.payload] }
    results.each_value { |r| assert_nil r[:error], "#{world}: a tool erred: #{r[:error]}" }

    # The PTY, driven through the four terminal tools on the same pipeline. cat
    # echoes a fresh marker back; that the round-trip closes in both worlds is
    # the proof the terminal tools survived the move into the container.
    marker = "TERMPROBE#{SecureRandom.hex(8)}"
    assert_nil call(ctx, session.id, "terminal_open",  name: "echoer", argv: ["cat"]).error,
               "#{world}: terminal_open failed"
    assert_nil call(ctx, session.id, "terminal_input", name: "echoer", text: "#{marker}\n").error,
               "#{world}: terminal_input failed"
    seen = read_until(ctx, session.id, "echoer", marker)
    assert_includes seen, marker, "#{world}: the cat PTY never echoed the marker back"
    call(ctx, session.id, "terminal_close", name: "echoer")

    { bash: results.fetch("u")[:content], membership: results.fetch("m")[:content],
      written:, read: results.fetch("r")[:content], terminal: seen }
  end

  def tc(id, name, **args) = Terret::LLM::ToolCall.new(id: id, name: name, args: args)

  # One tool through the real pipeline (pre_execute policy included), the way
  # the loop reaches it. session_id scopes the per-owner terminal namespace.
  def call(ctx, session_id, name, **args)
    ctx[:tools].execute(
      Terret::Tools::Call.new(id: "c-#{name}", name: name, args: args, session_id: session_id), ctx: ctx
    )
  end

  # Polls terminal_read until the marker arrives or the deadline passes; a
  # terminal with nothing to say answers "(...)", which is not output.
  def read_until(ctx, session_id, name, marker, timeout: 10)
    deadline = now + timeout
    seen = +""
    while now < deadline
      chunk = call(ctx, session_id, "terminal_read", name: name).content.to_s
      seen << chunk unless chunk.start_with?("(")
      break if seen.include?(marker)
    end
    seen
  end

  # name => Definition, for every tool the roster carries.
  def definitions(ctx)
    ctx[:tools].schemas.map { |s| s[:name] }.to_h { |n| [n, ctx[:tools].fetch(n)] }
  end

  # A Definition's comparable fields — everything but the handler Proc.
  def fields(definition) = definition.to_h.reject { |k, _| k == :handler }

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # `docker ps -a` by label, so a stopped-but-present container still counts as
  # surviving — the same probe docker_test sweeps with.
  def containers_labelled
    out = IO.popen(["docker", "ps", "-aq", "--no-trunc", "--filter", "label=#{LABEL}"],
                   err: [:child, :out], &:read)
    out.to_s.lines.map(&:strip).reject(&:empty?)
  end
end
