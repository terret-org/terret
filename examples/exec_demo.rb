# frozen_string_literal: true
# The M7 execution world, narrated end to end and offline-safe. One tmp
# workspace, one boot of the local world (fs + sandbox-none + subprocess +
# shell + terminals + the std tool roster + the loop + a redactor), then:
#
#   act 1  the world boots; the agent loop drives one tool call, exactly as a
#          model would — so the seams below are the same ones a real turn uses
#   act 2  the file tools (Read/Write/Edit/Glob/Grep) through the pipeline,
#          under a hot allow-list flip: all five run, a policy denies Write,
#          the flip allows it again — the M6 hot-policy story on real tools
#   act 3  Bash: uname, and a cwd + export that persist across two calls (one
#          long-lived shell per session)
#   act 4  a terminal (a PTY) round-trip: open cat, type a line, read the echo
#   act 5  the redactor scrubbing an (obviously fake) credential from a result
#   act 6  IF docker is present and the image is local: the §7 patch-row swap —
#          one appended sandbox row moves EXECUTION into a container with zero
#          tool changes. uname flips to Linux, /.dockerenv reads IN-CONTAINER,
#          and `--network none` is proven by a lookup that fails. Without
#          docker the act is skipped and the demo still exits 0.
#
# Honesty: ctx[:fs] always runs host-side over the bind mount — under docker it
# is the same bytes at the same paths (one world), NOT the filesystem moving
# into the container. What moves in act 6 is process execution (Bash and the
# PTY); the uname/dockerenv flip is the proof of exactly that and nothing more.
#
#   ruby examples/exec_demo.rb   # offline path; also runs act 6 when docker
#                                # and the ruby:slim image are already present

require "tmpdir"
require "fileutils"
require "securerandom"
require_relative "../gems/terret-exec/lib/terret/exec"            # fs, sandbox-none, subprocess, shell, terminals (+ terret-core)
require_relative "../gems/terret-tools-std/lib/terret/tools_std"  # Read/Write/Edit/Glob/Grep, Bash, terminal_*
require_relative "../gems/terret-sandbox-docker/lib/terret/sandbox/docker" # ctx[:sandbox] — the container provider

IMAGE = ENV.fetch("TERRET_DOCKER_TEST_IMAGE", "ruby:slim")
LABEL = "terret-sandbox" # the label the docker provider stamps; the sweep matches it
# Obviously not a real key — the whole point is that the redactor scrubs it
# before the model ever sees it, so a live secret would defeat the demonstration.
FAKE_SECRET = "sk-FAKENOTAREALKEY000000000000"

Terret.declare_events! # once; both worlds share the global declarations

# -- narration ---------------------------------------------------------------

def section(title) = puts "\n== #{title}"
def note(msg)       = puts "   #{msg}"
def mono            = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def trim(str, limit = 200)
  s = str.to_s
  s.length > limit ? "#{s[0, limit]}…(+#{s.length - limit} more)" : s
end

# One tool through the real pipeline (pre_execute policy → execute → the
# redactor's post_execute), the same path the loop drives. Returns the Result.
def pipe(ctx, session_id, name, **args)
  ctx[:tools].execute(
    Terret::Tools::Call.new(id: "c-#{SecureRandom.hex(3)}", name: name, args: args, session_id: session_id),
    ctx: ctx
  )
end

# Drives one tool AND narrates it: the call line, then its output or its
# refusal, exactly as they came back from the pipeline.
def show(ctx, session_id, name, **args)
  result = pipe(ctx, session_id, name, **args)
  argstr = args.map { |k, v| "#{k}: #{trim(v.inspect, 48)}" }.join(", ")
  puts "   tool> #{name}(#{argstr})"
  if result.error
    puts "     !!  #{result.error}"
  else
    trim(result.content).to_s.each_line { |line| puts "     |  #{line.chomp}" }
  end
  result
end

# Reads a terminal until the marker echoes back or the deadline passes. A
# terminal with nothing to say answers "(...)", which is not output.
def read_until(ctx, session_id, name, marker, timeout: 10)
  deadline = mono + timeout
  seen = +""
  while mono < deadline
    chunk = pipe(ctx, session_id, "terminal_read", name: name, timeout: 500).content.to_s
    seen << chunk unless chunk.start_with?("(")
    break if seen.include?(marker)
  end
  seen
end

# open cat, type a line, read the echo, close. The same four PTY tools in both
# worlds — that the round-trip closes is the proof the terminal tools survived.
def terminal_roundtrip(ctx, session_id, world)
  marker = "TERMPROBE-#{SecureRandom.hex(4)}"
  puts "   tool> terminal_open(name: \"repl\", argv: [\"cat\"])"
  puts "     |  #{pipe(ctx, session_id, 'terminal_open', name: 'repl', argv: ['cat']).content}"
  pipe(ctx, session_id, "terminal_input", name: "repl", text: "#{marker}\n")
  puts "   tool> terminal_input(name: \"repl\", text: #{marker.inspect}+\"\\n\")"
  echoed = read_until(ctx, session_id, "repl", marker)
  puts "   tool> terminal_read(name: \"repl\")"
  puts "     |  #{echoed.chomp}"
  note(echoed.include?(marker) ? "the cat PTY echoed the line back — the terminal tools live in the #{world} world" \
                               : "WARNING: the #{world} terminal never echoed the marker")
  pipe(ctx, session_id, "terminal_close", name: "repl")
end

# -- docker probes -----------------------------------------------------------

def docker_available? = system("docker", "info", out: File::NULL, err: File::NULL)
def image_present?(image) = system("docker", "image", "inspect", image, out: File::NULL, err: File::NULL)

# `docker ps -a` by label, so a stopped-but-present container still counts —
# the same probe the acceptance suite sweeps with.
def containers_labelled(label)
  out = IO.popen(["docker", "ps", "-aq", "--no-trunc", "--filter", "label=#{label}"], err: %i[child out], &:read)
  out.to_s.lines.map(&:strip).reject(&:empty?)
end

# -- the world ---------------------------------------------------------------

# Every row a real profile mounts for the execution world except the sandbox
# verdict itself: the seams, the whole std tool roster, the loop that drives
# them through a FakeAdapter, and the redactor at the append/post_execute
# boundary. shell and terminals are pointed at the workspace on purpose — their
# default cwd is the host repo, and under docker an unmounted cwd is Denied.
def build_rows(raw_ws, secret_pattern)
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
    { id: "redactor",   plugin: Terret::Redactor,        config: { patterns: [secret_pattern] } },
    { id: "llm",  plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
    { id: "loop", plugin: Terret::Loop }
  ]
end

# Both worlds boot the SAME base rows; the docker world layers one more row on
# top — the §7 mechanism the whole milestone turns on. A later layer's row with
# an existing id ("sandbox") swaps that row's plugin and config wholesale.
def boot_world(base_rows, patch_rows = [])
  loader = Hames::Loader.new
  loader.layer(base_rows)
  loader.layer(patch_rows) unless patch_rows.empty?
  loader.boot!
end

booted = []
workspace = Dir.mktmpdir("terret-exec-demo")
raw_ws = workspace           # pre-realpath, handed verbatim to fs and the sandbox
secret_pattern = "sk-[A-Za-z0-9-]+"

begin
  base_rows = build_rows(raw_ws, secret_pattern)

  # == act 1: the world boots, and the loop drives it ========================
  ctx = boot_world(base_rows)
  booted << ctx
  section "act 1: the local execution world boots"
  note "workspace: #{raw_ws}"
  note "seams:  ctx[:fs] (workspace-contained files) · ctx[:sandbox] = SandboxNone (no isolation)"
  note "        ctx[:subprocess] · ctx[:shell] (persistent bash) · ctx[:terminals] (named PTYs)"
  note "tools:  #{ctx[:tools].schemas.map { |s| s[:name] }.sort.join(', ')}"
  note "loop + FakeAdapter mounted; the redactor guards every tool result"

  # One genuine turn so the loop is not just mounted furniture: the model script
  # asks for a shell command, the loop runs it through the very pipeline the
  # rest of this walk-through drives by hand. Rendered from the session stream.
  ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(
    [
      { text: "Running a shell command.",
        tool_calls: [Terret::LLM::ToolCall.new(id: "t1", name: "Bash",
                                               args: { command: "echo hello from inside the loop" })] },
      { text: "Done." }
    ]
  ))
  transcript = ctx.on("session/event") do |ev|
    case ev.type
    when "assistant/message" then puts "   bot>  #{ev.payload[:text]}" unless ev.payload[:text].to_s.empty?
    when "tool/call"         then puts "   tool> #{ev.payload[:name]}(#{ev.payload[:args]})"
    when "tool/result"       then puts(ev.payload[:error] ? "     !!  #{ev.payload[:error]}" : "     |  #{trim(ev.payload[:content]).chomp}")
    when "turn/end"          then puts "   [turn #{ev.payload[:status]}]"
    end
  end
  loop_session = ctx[:sessions].create(id: "loop")
  agent = ctx[:loop].spawn_agent(session_id: loop_session.id)
  puts "   you>  run a shell command"
  ctx[:loop].run_turn(agent, "run a shell command")
  transcript.call # the rest of the demo drives the same pipeline directly, so each step is visible

  # == act 2: file tools through the pipeline, under a hot policy flip ========
  section "act 2: the file tools, under a deny-then-allow policy flip"
  files = ctx[:sessions].create(id: "files")
  notes_path = File.join(raw_ws, "notes.txt")
  gate = Terret::Tools::AllowList.install(ctx, ["*"]) # floor: everything allowed until a session says otherwise

  puts "\n   -- all five file tools run through the pipeline (policy: allow *)"
  show(ctx, files.id, "Write", file_path: notes_path, content: "the quick brown fox\nover the lazy dog\n")
  show(ctx, files.id, "Read",  file_path: notes_path)
  show(ctx, files.id, "Edit",  file_path: notes_path, old_string: "brown", new_string: "red")
  show(ctx, files.id, "Glob",  pattern: "**/*.txt")
  show(ctx, files.id, "Grep",  pattern: "fox")

  puts "\n   -- a hot policy update drops Write from the allow list"
  Terret::Tools::AllowList.update(ctx, files.id, %w[Read Glob Grep Edit])
  show(ctx, files.id, "Write", file_path: File.join(raw_ws, "blocked.txt"), content: "should not land")
  note "blocked.txt on disk? #{File.exist?(File.join(raw_ws, 'blocked.txt'))} — the veto never reached the seam"

  puts "\n   -- flip the policy back, and the very next call succeeds"
  Terret::Tools::AllowList.update(ctx, files.id, %w[Read Glob Grep Edit Write])
  show(ctx, files.id, "Write", file_path: File.join(raw_ws, "allowed.txt"), content: "this one lands\n")
  gate.call # tear the allow list down; the remaining acts run ungated

  # == act 3: Bash, and a shell that keeps its state ==========================
  section "act 3: Bash over one long-lived shell per session"
  bash = "bash-session"
  show(ctx, bash, "Bash", command: "uname")
  puts "\n   -- a cd and an export in one call…"
  show(ctx, bash, "Bash", command: "cd /tmp && export GREETING=hola")
  puts "   -- …are still in effect in the next call (same persistent bash)"
  show(ctx, bash, "Bash", command: 'echo "$GREETING from $(pwd)"')

  # == act 4: a terminal (a PTY) round-trip ===================================
  section "act 4: a terminal round-trip (a long-lived PTY)"
  terminal_roundtrip(ctx, "term-session", "local")

  # == act 5: the redactor scrubs a credential ================================
  section "act 5: the redactor scrubs a fake credential from a tool result"
  note "the command echoes an obviously fake token: #{FAKE_SECRET}"
  redacted = show(ctx, bash, "Bash", command: "echo token=#{FAKE_SECRET}")
  note redacted.content.to_s.include?("[REDACTED]") ? "the credential never reached the session — scrubbed at post_execute" \
                                                    : "WARNING: the credential was not redacted"

  # == act 6: the patch-row swap moves execution into a container =============
  section "act 6: one appended row moves execution into a container"
  if docker_available? && image_present?(IMAGE)
    preexisting = containers_labelled(LABEL)
    patch = [{ id: "sandbox", plugin: Terret::Sandbox::Docker,
               config: { image: IMAGE, network: "none", workspace: [raw_ws] } }]
    ctx_docker = boot_world(base_rows, patch)
    booted << ctx_docker
    note "layered one row: ctx[:sandbox] = Terret::Sandbox::Docker (#{IMAGE}, --network none)"
    note "zero tool changes — the same Bash and PTY handlers, now wrapped as `docker exec`;"
    note "the file tools stay host-side over the bind mount (one world, same bytes, same paths)"
    dsession = "docker-session"

    puts "\n   -- the same Bash tool, now running inside the container"
    show(ctx_docker, dsession, "Bash", command: "uname")
    show(ctx_docker, dsession, "Bash", command: "test -f /.dockerenv && echo IN-CONTAINER || echo ON-HOST")
    show(ctx_docker, dsession, "Bash", command: "grep -m1 PRETTY_NAME /etc/os-release")
    puts "\n   -- one world: the file act 2 wrote host-side, read from inside the container"
    show(ctx_docker, dsession, "Bash", command: "cat notes.txt")
    puts "\n   -- --network none, demonstrated rather than asserted"
    show(ctx_docker, dsession, "Bash",
         command: "getent hosts example.com >/dev/null 2>&1 && echo REACHABLE || echo NO-NETWORK")
    puts "\n   -- and the PTY tools survived the move into the container"
    terminal_roundtrip(ctx_docker, dsession, "container")

    note "the local world ran ON-HOST; this world ran IN-CONTAINER — execution moved, one row did it"
    note "ctx[:fs] stayed host-side over the bind mount the whole time; the FILES never moved, only execution"

    leaked = containers_labelled(LABEL) - preexisting
    ctx_docker[:shell].close_all
    ctx_docker[:terminals].close_all
    ctx_docker[:sandbox].stop
    booted.delete(ctx_docker)
    still = containers_labelled(LABEL) - preexisting
    note "container swept by label; #{still.empty? ? 'none left behind' : "LEAKED: #{still.inspect}"} (this run started #{leaked.length})"
  elsif docker_available?
    note "docker is present but #{IMAGE} is not local — skipping the container act to stay offline"
    note "(`docker pull #{IMAGE}`, or run the terret-sandbox-docker acceptance suite once, to enable it)"
  else
    note "docker not available — skipping the container act"
  end

  section "done: the whole execution world, one boot, offline"
ensure
  booted.each do |c|
    c[:shell].close_all     if c.service?(:shell)
    c[:terminals].close_all if c.service?(:terminals)
    c[:sandbox].stop        if c.service?(:sandbox) && c[:sandbox].isolated?
  rescue StandardError
    nil
  end
  FileUtils.remove_entry(workspace) if File.directory?(workspace)
end
