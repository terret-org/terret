# frozen_string_literal: true
# The M8 composition layer, narrated end to end and offline-safe. One tmp
# TERRET_HOME, one profile stacking terret-base, and then:
#
#   act 1  the layers: terret-base's rows, the profile's patch, and one
#          --patch overlay, folded into an ordered tree with provenance
#   act 2  `trt dump-config` on that profile — the real command, real output.
#          OPENROUTER_API_KEY is set to an (obviously fake) value first, and
#          the point of the act is that it does NOT appear
#   act 3  Terret.boot: rows become constants, the loader mounts them in
#          dependency order, and a whole harness comes up from YAML
#   act 4  one scripted turn through the booted world — the model asks for a
#          tool, the tool writes a file inside the granted workspace
#   act 5  the allow-list floor: a tool terret-base never mounted is denied
#   act 6  the failure modes, on purpose: an unknown bundle, an unanchored
#          insertion, and a !ruby scalar without consent
#
# Everything here runs with no network, no docker daemon, and no API key.
#
#   ruby examples/boot_demo.rb

require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../gems/terret/lib/terret/boot"

FAKE_KEY = "sk-FAKENOTAREALKEY000000000000"

def section(title) = puts "\n== #{title}"
def note(msg)      = puts "   #{msg}"
def write(path, body)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, body)
  path
end

home      = Dir.mktmpdir("terret-demo-home")
workspace = Dir.mktmpdir("terret-demo-workspace")
ENV["TERRET_HOME"] = home
ENV["OPENROUTER_API_KEY"] = FAKE_KEY
ctx = nil

begin
  # -- the profile, three files -----------------------------------------------

  # Layer 1 is terret-base, which this profile stacks by naming the gem that
  # ships it. settings: exists only to be the target of !setting references,
  # so a value used by three rows is written once.
  write(File.join(home, "profiles", "demo", "profile.yml"), <<~YAML)
    bundles: [terret]
    settings:
      workspace:
        - #{workspace}
      store:   { path: #{File.join(home, 'sessions.db')} }
      model:   { main: fake/scripted }
      sandbox: { image: ruby:slim }
  YAML

  # Layer 2: what THIS composition decided. One row swaps the execution world
  # off docker — the same mechanism docs/exec.md §4 leans on, in reverse.
  write(File.join(home, "profiles", "demo", "patch.yml"), <<~YAML)
    rows:
      - id: sandbox
        plugin: Terret::Exec::SandboxNone
        config: {}
  YAML

  # Layer 4: what THIS INVOCATION decided. Keeping the demo offline means no
  # SQLite file and no HTTP adapter, which is two rows.
  overlay = write(File.join(home, "offline.yml"), <<~YAML)
    rows:
      - id: session_store
        plugin: Terret::Store::Memory
        config: {}
      - id: openrouter
        disabled: true
  YAML

  # == act 1: the layers fold into an ordered tree ============================
  section "act 1: three layers fold into one ordered list of rows"
  resolved = Terret::Composition.resolve(profile: "demo", patches: [overlay])
  note "TERRET_HOME=#{home}"
  note "#{resolved.rows.length} rows, in mount-independent order (the loader sorts by inject)"
  puts
  # A --patch overlay is labelled by the path as given, which here is a tmpdir.
  short = ->(layer) { layer.to_s.sub("#{home}/", "$TERRET_HOME/") }
  %w[session_store llm openrouter sandbox fs allow_list approvals].each do |id|
    row = resolved.row(id)
    puts format("   %-14s %-30s row: %-14s config: %s",
                row.id, row.plugin, row.row_layer, short.(row.config_layer))
  end
  note ""
  note "provenance is per ROW, not per key — a patch replaces a config wholesale,"
  note "so exactly one layer answers for what each service receives"

  # == act 2: dump-config, and what it refuses to print =======================
  section "act 2: `trt dump-config --profile demo`, with a key in the environment"
  note "OPENROUTER_API_KEY is set to #{FAKE_KEY} for this act"
  puts
  out = StringIO.new
  Terret::CLI.start(%w[dump-config --profile demo --patch] + [overlay], out: out, err: $stderr)
  # Four rows of the twenty-four, so the act stays readable; the command
  # itself prints the whole tree.
  shown = %w[session_store llm openrouter fs]
  out.string.split(/^(?=  - id: )/).each do |block|
    next unless shown.any? { |id| block.start_with?("  - id: #{id} ", "  - id: #{id}\n") }

    puts block.lines.map { |l| "   #{short.(l.chomp)}" }
  end
  puts
  note out.string.include?(FAKE_KEY) ? "WARNING: the key was printed" \
                                     : "the key never appears — the tag prints as written, unresolved"

  # == act 3: boot ============================================================
  section "act 3: Terret.boot turns that tree into a running harness"
  ctx = Terret.boot(profile: "demo", patches: [overlay])
  mounted = %i[session_store sessions prompt tools llm sandbox subprocess fs shell
               terminals jobs subagents loop redactor allow_list].select { |k| ctx.service?(k) }
  note "services: #{mounted.join(', ')}"
  note "tools:    #{ctx[:tools].schemas.map { |s| s[:name] }.sort.join(', ')}"
  note "approvals: #{ctx.service?(:approvals) ? 'mounted' : 'not mounted (the row ships disabled)'}"
  note "workspace: #{workspace}"

  # == act 4: one turn ========================================================
  section "act 4: one scripted turn through the world that YAML just built"
  ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(
                                       [{ text: "Writing a file into the workspace.",
                                          tool_calls: [Terret::LLM::ToolCall.new(
                                            id: "t1", name: "Write",
                                            args: { file_path: File.join(workspace, "hello.txt"),
                                                    content: "composed from YAML\n" }
                                          )] },
                                        { text: "Done." }]
                                     ))
  ctx.on("session/event") do |ev|
    case ev.type
    when "assistant/message"
      # The payload is encoded parts, not a string: a message is text and tool
      # calls interleaved, and the log keeps the structure.
      text = ev.payload[:parts].filter_map { |p| p[:text] if p[:type] == "text" }.join
      puts "   bot>  #{text}" unless text.empty?
    when "tool/call"         then puts "   tool> #{ev.payload[:name]}(#{ev.payload[:args]})"
    when "tool/result"       then puts(ev.payload[:error] ? "     !!  #{ev.payload[:error]}" : "     |  #{ev.payload[:content]}")
    when "turn/end"          then puts "   [turn #{ev.payload[:status]}]"
    end
  end
  session = ctx[:sessions].create(id: "demo")
  puts "   you>  write hello.txt"
  ctx[:loop].run_turn(ctx[:loop].spawn_agent(session_id: session.id), "write hello.txt")
  note "on disk: #{File.read(File.join(workspace, 'hello.txt')).inspect}"

  # == act 5: the floor =======================================================
  section "act 5: the allow-list floor denies a tool the bundle never mounted"
  ctx[:tools].register(name: "Nuke", description: "would be bad",
                       params: { type: "object", properties: {} },
                       mutating: true, approval: :never, concurrency: :exclusive, ctx: ctx) { "boom" }
  denied = ctx[:tools].execute(
    Terret::Tools::Call.new(id: "c1", name: "Nuke", args: {}, session_id: session.id), ctx: ctx
  )
  note "Nuke is registered on ctx[:tools] and still refused: #{denied.error}"
  note "the floor names the roster terret-base mounted; anything else is denied until a profile says otherwise"

  # == act 6: the failures, on purpose ========================================
  section "act 6: three ways a composition fails closed"
  write(File.join(home, "profiles", "bad-bundle", "profile.yml"), "bundles: [terret, terret-nope]\n")
  write(File.join(home, "profiles", "bad-anchor", "profile.yml"), "bundles: [terret]\n")
  write(File.join(home, "profiles", "bad-anchor", "patch.yml"),
        "rows:\n  - id: audit\n    plugin: Acme::Audit\n")
  write(File.join(home, "profiles", "bad-ruby", "profile.yml"), <<~YAML)
    bundles: [terret]
    settings:
      workspace: []
      store:   { path: x }
      model:   { main: !ruby "'fake/' + 'scripted'" }
      sandbox: { image: x }
  YAML

  [["an unknown bundle", -> { Terret::Composition.resolve(profile: "bad-bundle") }],
   ["an insertion with no anchor", -> { Terret::Composition.resolve(profile: "bad-anchor") }],
   ["!ruby without consent", -> { Terret::Composition.resolve(profile: "bad-ruby").materialize }]].each do |label, attempt|
    attempt.call
    note "#{label}: WARNING — no error raised"
  rescue Terret::Composition::Error => e
    note "#{label}:"
    puts "     !!  #{e.message}"
  end
  note ""
  note "and with consent, the same profile resolves: " \
       "#{Terret::Composition.resolve(profile: 'bad-ruby').materialize(allow_config_ruby: true)
                             .find { |r| r[:id] == 'llm' }[:config][:roles][:main].inspect}"

  section "done: a harness composed, booted, driven and torn down, from YAML"
ensure
  Terret::Boot.shutdown(ctx) if ctx
  [home, workspace].each { |d| FileUtils.remove_entry(d) if d && File.directory?(d) }
end
