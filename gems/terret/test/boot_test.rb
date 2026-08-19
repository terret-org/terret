# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/terret/boot"

# A row whose teardown fails. Named at the top level because a plugin: is a
# constant name resolved out of YAML, same as any other row's.
class BootTestWedgedSeam < Hames::Service
  service_key :wedged
  class << self; attr_accessor :stopped; end

  def stop(_ctx)
    self.class.stopped = true
    raise "wedged: this seam will not close"
  end
end

# Two seams that record the order they were torn down in. A depends on B, so
# the loader mounts B first whatever order the rows are declared in — which is
# what makes reverse-mount and reverse-declaration order tell apart.
module BootTestOrder
  class << self; attr_accessor :stops; end
  self.stops = []

  class B < Hames::Service
    service_key :order_b
    def stop(_ctx) = BootTestOrder.stops << :order_b
  end

  class A < Hames::Service
    service_key :order_a
    inject :order_b
    def stop(_ctx) = BootTestOrder.stops << :order_a
  end
end

# Terret.boot is the whole embedding surface (docs/composition.md §7): resolve
# the layers, hand the row list to the Hames loader, return the booted context.
# A Rails app calls this in an initializer and holds the ctx; `trt` is one
# caller of it rather than the way Terret is used.
class BootTest < Minitest::Test
  def setup
    @home_dir = Dir.mktmpdir("terret-home")
    @workspace = Dir.mktmpdir("terret-workspace")
    @prev_home = ENV["TERRET_HOME"]
    ENV["TERRET_HOME"] = @home_dir
    @booted = []
  end

  def teardown
    @booted.each { |ctx| Terret::Boot.shutdown(ctx) }
    ENV["TERRET_HOME"] = @prev_home
    [@home_dir, @workspace].each { |d| FileUtils.remove_entry(d) if File.directory?(d) }
  end

  def write(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  def profile(name, body) = write(File.join(@home_dir, "profiles", name, "profile.yml"), body)
  def profile_patch(name, body) = write(File.join(@home_dir, "profiles", name, "patch.yml"), body)

  # terret-base, with the three rows that reach the network or the disk swapped
  # for their offline equivalents. This is exactly the shape a CI profile takes,
  # and it is one patch file.
  OFFLINE_PATCH = <<~YAML
    rows:
      - id: session_store
        plugin: Terret::Store::Memory
        config: {}
      - id: openrouter
        disabled: true
      - id: llm
        config:
          roles:
            main: fake/scripted
      - id: sandbox
        plugin: Terret::Exec::SandboxNone
        config: {}
  YAML

  def offline_profile(name = "test")
    profile(name, <<~YAML)
      bundles: [terret]
      settings:
        workspace:
          - #{@workspace}
        store: { path: unused }
        model: { main: fake/scripted }
        sandbox: { image: unused }
    YAML
    profile_patch(name, OFFLINE_PATCH)
    name
  end

  def boot(name = offline_profile, **kw)
    ctx = Terret.boot(profile: name, **kw)
    @booted << ctx
    ctx
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # Bounded so a child that never dies fails the assertion instead of hanging;
  # signal delivery and reaping are asynchronous, so a bare check would race.
  def refute_alive(pid, message = nil, timeout: 5)
    deadline = now + timeout
    sleep 0.02 while alive?(pid) && now < deadline
    refute alive?(pid), message || "pid #{pid} is still alive"
  end

  # -- the whole point -------------------------------------------------------

  def test_a_patched_profile_boots_offline_and_drives_a_turn_end_to_end
    ctx = boot
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(
                                         [{ text: "Writing the file.",
                                            tool_calls: [Terret::LLM::ToolCall.new(
                                              id: "t1", name: "Write",
                                              args: { file_path: File.join(@workspace, "hello.txt"),
                                                      content: "from a booted profile\n" }
                                            )] },
                                          { text: "Done." }]
                                       ))

    session = ctx[:sessions].create(id: "boot-test")
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    ctx[:loop].run_turn(agent, "write hello.txt")

    assert_equal "from a booted profile\n", File.read(File.join(@workspace, "hello.txt"))

    types = ctx[:sessions].fetch(session.id).events.map(&:type)
    assert_includes types, "tool/call"
    assert_includes types, "turn/end"
  end

  def test_the_whole_terret_base_roster_is_mounted_and_addressable
    ctx = boot
    %i[session_store sessions prompt tools llm sandbox subprocess fs shell
       terminals jobs subagents loop redactor allow_list].each do |key|
      assert ctx.service?(key), "ctx[:#{key}] should be mounted by terret-base"
    end
    assert_equal %w[Bash Edit Glob Grep Read Task TodoWrite WebFetch Write
                    job_collect job_start job_stop terminal_close terminal_input
                    terminal_open terminal_read].sort,
                 ctx[:tools].schemas.map { |s| s[:name] }.sort
  end

  def test_a_disabled_row_stays_in_the_tree_and_out_of_the_context
    resolved = Terret::Composition.resolve(profile: offline_profile)
    assert resolved.row("approvals").disabled
    refute boot.service?(:approvals), "an approvals row shipped disabled must not mount"
  end

  def test_the_allow_list_floor_denies_a_tool_the_bundle_never_mounted
    ctx = boot
    ctx[:tools].register(name: "Nuke", description: "d", params: { type: "object", properties: {} },
                         mutating: true, approval: :never, concurrency: :exclusive, ctx: ctx) { "boom" }
    session = ctx[:sessions].create(id: "floor")
    result = ctx[:tools].execute(
      Terret::Tools::Call.new(id: "c1", name: "Nuke", args: {}, session_id: session.id), ctx: ctx
    )
    assert_match(/not on the allow list/, result.error.to_s)
  end

  # -- failure modes ---------------------------------------------------------

  def test_a_plugin_constant_that_does_not_resolve_names_the_row_and_the_constant
    name = offline_profile
    profile_patch(name, "#{OFFLINE_PATCH}\n  - id: sessions\n    plugin: Nope::NotAThing\n")
    err = assert_raises(Terret::Boot::Error) { boot(name) }
    assert_includes err.message, "sessions"
    assert_includes err.message, "Nope::NotAThing"
  end

  def test_a_plugin_that_is_not_a_plugin_is_refused_before_the_loader_sees_it
    name = offline_profile
    profile_patch(name, "#{OFFLINE_PATCH}\n  - id: sessions\n    plugin: String\n")
    err = assert_raises(Terret::Boot::Error) { boot(name) }
    assert_includes err.message, "String"
  end

  def test_a_bundle_require_that_cannot_be_loaded_says_which_file
    write(File.join(@home_dir, "b", "config", "bundle.yml"), <<~YAML)
      name: broken
      requires: [terret/no_such_file]
      rows:
        - id: sessions
          plugin: Terret::Sessions
    YAML
    profile("broken", "bundles: [broken]\n")
    catalog = { "broken" => Terret::Composition.load_bundle(
      File.join(@home_dir, "b", "config", "bundle.yml"), gem_name: "broken"
    ) }
    resolved = Terret::Composition.resolve(profile: "broken", bundles: catalog)
    err = assert_raises(Terret::Boot::Error) { Terret::Boot.new(resolved).boot! }
    assert_includes err.message, "terret/no_such_file"
  end

  # -- home ------------------------------------------------------------------

  def test_the_home_keyword_wins_over_terret_home
    elsewhere = Dir.mktmpdir("terret-elsewhere")
    write(File.join(elsewhere, "profiles", "test", "profile.yml"), <<~YAML)
      bundles: [terret]
      settings:
        workspace: []
        store: { path: unused }
        model: { main: fake/scripted }
        sandbox: { image: unused }
    YAML
    write(File.join(elsewhere, "profiles", "test", "patch.yml"), OFFLINE_PATCH)
    offline_profile("test") # a decoy of the same name in TERRET_HOME
    assert boot("test", home: elsewhere).service?(:sessions)
  ensure
    FileUtils.remove_entry(elsewhere) if elsewhere && File.directory?(elsewhere)
  end

  # -- shutdown --------------------------------------------------------------

  # A row's stop hook is where a service closes what it opened. Tearing a
  # composition down by hand-listing four seams runs none of them.
  def test_shutdown_runs_every_rows_stop_hook_not_a_hand_written_list
    name = offline_profile
    db_path = File.join(@workspace, "sessions.db")
    profile_patch(name, <<~YAML)
      rows:
        - id: session_store
          plugin: Terret::Store::SQLite
          config: { path: #{db_path} }
        - id: openrouter
          disabled: true
        - id: llm
          config: { roles: { main: fake/scripted } }
        - id: sandbox
          plugin: Terret::Exec::SandboxNone
          config: {}
    YAML
    ctx = Terret.boot(profile: name)
    handle = ctx[:session_store].instance_variable_get(:@db)
    refute_predicate handle, :closed?

    Terret::Boot.shutdown(ctx)
    assert_predicate handle, :closed?, "Store::SQLite#stop must have run and closed the database"
  end

  # The console (examples/web_chat.rb) routes its Ctrl-C teardown through
  # Boot.shutdown for exactly this: the two things a hand-picked list of seams
  # used to miss are a running job and the loop's own agents. Shutdown unloads
  # the loop row (whose stop disposes its agents) and the jobs row (whose stop
  # ends every subprocess), so neither survives.
  def test_shutdown_ends_running_jobs_and_disposes_the_loops_agents
    pid = nil
    ctx = boot
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new([]))
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    job_id = ctx[:jobs].start("sleep 60", session: session.id)
    pid = ctx[:jobs].instance_variable_get(:@jobs)[job_id].handle.pid
    assert alive?(pid), "the job did not start"

    Terret::Boot.shutdown(ctx)
    @booted.delete(ctx)

    assert_equal :done, agent.status, "the loop's agents must be disposed on shutdown"
    refute_alive pid, "a running job must not survive shutdown"
  ensure
    begin
      Process.kill("KILL", pid) if pid
    rescue Errno::ESRCH
      nil
    end
  end

  def test_one_wedged_seam_does_not_abort_the_rest_of_the_shutdown
    name = offline_profile
    profile_patch(name, "#{OFFLINE_PATCH}\n  - id: wedged\n    plugin: BootTestWedgedSeam\n    after: sessions\n")
    ctx = boot(name)
    BootTestWedgedSeam.stopped = false

    _out, errs = capture_io { Terret::Boot.shutdown(ctx) }
    @booted.delete(ctx)

    assert BootTestWedgedSeam.stopped, "the wedged seam's stop was attempted"
    assert_includes errs, "wedged"
    refute ctx.service?(:sessions), "every other row still came down"
  end

  # Declaration order is A then B; dependency order mounts B then A. Reverse
  # mount order is therefore A then B, and reverse declaration order is B then
  # A — only one of them tears a consumer down before the thing it consumes.
  def test_teardown_follows_reverse_mount_order_not_reverse_declaration_order
    name = offline_profile
    profile_patch(name, "#{OFFLINE_PATCH}\n" \
                        "  - id: order_a\n    plugin: BootTestOrder::A\n    after: sessions\n" \
                        "  - id: order_b\n    plugin: BootTestOrder::B\n    after: order_a\n")
    BootTestOrder.stops = []
    Terret::Boot.shutdown(Terret.boot(profile: name))

    assert_equal %i[order_a order_b], BootTestOrder.stops,
                 "a consumer must come down before the service it injects"
  end

  def test_shutting_down_a_context_that_was_not_booted_here_says_so
    loader = Hames::Loader.new.layer([{ id: "b", plugin: BootTestOrder::B }])
    ctx = loader.boot!
    BootTestOrder.stops = []

    _out, errs = capture_io { Terret::Boot.shutdown(ctx) }
    assert_includes errs, "loader", "a silent no-op would break the every-stop-hook-runs promise"
    assert_empty BootTestOrder.stops
  end

  def test_a_hand_built_world_can_hand_shutdown_its_own_loader
    loader = Hames::Loader.new.layer([{ id: "b", plugin: BootTestOrder::B }])
    loader.boot!
    BootTestOrder.stops = []

    _out, errs = capture_io { Terret::Boot.shutdown(loader.ctx, loader: loader) }
    assert_empty errs
    assert_equal %i[order_b], BootTestOrder.stops
  end

  def test_the_loader_stays_reachable_from_the_context_it_booted
    ctx = boot
    assert_kind_of Hames::Loader, ctx[:loader]
    assert_same ctx, ctx[:loader].ctx
  end

  def test_asking_a_boot_for_its_loader_twice_gets_the_same_one
    b = Terret::Boot.new(Terret::Composition.resolve(profile: offline_profile))
    assert_same b.loader, b.loader
    @booted << b.boot!
    assert_same b.loader.ctx, @booted.last
  end

  def test_the_shipped_headless_template_resolves_with_an_empty_home
    resolved = Terret::Composition.resolve(profile: "headless", bundles: shipped_catalog)
    assert_equal "terret-base", resolved.row("sandbox").row_layer
    assert_equal "Terret::Sandbox::Docker", resolved.row("sandbox").plugin

    rows = resolved.materialize
    sandbox = rows.find { |r| r[:id] == "sandbox" }
    assert_equal "none", sandbox[:config][:network], "the shipped default denies the network"
    fs = rows.find { |r| r[:id] == "fs" }
    assert_equal [], fs[:config][:workspace], "an unedited template grants no workspace"
  end

  # Named explicitly rather than discovered: going through discovery would make
  # the result depend on whatever else happens to be installed on the machine.
  def shipped_catalog
    { "terret" => Terret::Composition.load_bundle(
      File.expand_path("../config/bundle.yml", __dir__), gem_name: "terret"
    ) }
  end
end
