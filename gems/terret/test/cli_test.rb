# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../lib/terret/boot"

# trt, driven in-process with captured IO. start returns an exit status rather
# than calling exit, which is what makes that possible; exactly one test below
# spawns the real executable, to prove the wiring exists.
class CLITest < Minitest::Test
  def setup
    @home_dir = Dir.mktmpdir("terret-home")
    @prev_home = ENV["TERRET_HOME"]
    ENV["TERRET_HOME"] = @home_dir
  end

  def teardown
    ENV["TERRET_HOME"] = @prev_home
    FileUtils.remove_entry(@home_dir) if File.directory?(@home_dir)
  end

  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = Terret::CLI.start(argv, out: out, err: err)
    [status, out.string, err.string]
  end

  def write(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  def profile(name, body) = write(File.join(@home_dir, "profiles", name, "profile.yml"), body)
  def profile_patch(name, body) = write(File.join(@home_dir, "profiles", name, "patch.yml"), body)

  def demo_profile
    profile("demo", <<~YAML)
      bundles: [terret]
      settings:
        workspace: []
        store: { path: /tmp/demo.db }
        model: { main: openrouter/some/model }
        sandbox: { image: demo:latest }
    YAML
    "demo"
  end

  # -- version and usage -----------------------------------------------------

  def test_version_comes_from_the_gems_one_version_constant
    status, out, = run_cli("--version")
    assert_equal 0, status
    assert_equal "trt #{Terret::Meta::VERSION}", out.strip
  end

  def test_help_prints_the_usage_and_succeeds
    status, out, = run_cli("--help")
    assert_equal 0, status
    assert_includes out, "trt <command>"
    Terret::CLI::COMMANDS.each { |c| assert_includes out, c }
  end

  def test_no_command_is_a_usage_error_not_a_crash
    status, _out, err = run_cli
    assert_equal 2, status
    assert_includes err, "no command"
  end

  def test_an_unknown_command_names_itself
    status, _out, err = run_cli("frobnicate", "--profile", "demo")
    assert_equal 2, status
    assert_includes err, "frobnicate"
  end

  def test_a_command_without_a_profile_says_so
    status, _out, err = run_cli("dump-config")
    assert_equal 2, status
    assert_includes err, "--profile"
  end

  def test_an_unknown_flag_is_a_usage_error
    status, _out, err = run_cli("dump-config", "--profile", "demo", "--nope")
    assert_equal 2, status
    assert_includes err, "nope"
  end

  # -- dump-config -----------------------------------------------------------

  def test_dump_config_annotates_every_row_with_the_layer_that_contributed_it
    profile_patch(demo_profile, "rows:\n  - id: sandbox\n    config: { image: patched, network: none }\n")
    status, out, = run_cli("dump-config", "--profile", "demo")

    assert_equal 0, status
    assert_includes out, %(# resolved: profile "demo")
    assert_match(/- id: session_store\s+# row: terret-base/, out)
    assert_match(/config:\s+# config: terret-base/, out)
    assert_match(/config:\s+# config: profiles\/demo\/patch\.yml/, out)
  end

  # The one that matters: this output exists to be pasted into an issue.
  def test_dump_config_never_prints_a_resolved_credential
    demo_profile
    ENV["OPENROUTER_API_KEY"] = "sk-live-must-never-be-printed"
    _status, out, = run_cli("dump-config", "--profile", "demo")

    assert_includes out, "api_key: !env OPENROUTER_API_KEY"
    refute_includes out, "sk-live-must-never-be-printed"
  ensure
    ENV.delete("OPENROUTER_API_KEY")
  end

  def test_dump_config_leaves_setting_references_unresolved_too
    demo_profile
    _status, out, = run_cli("dump-config", "--profile", "demo")
    assert_includes out, "path: !setting store.path"
    refute_includes out, "/tmp/demo.db"
  end

  def test_dump_config_shows_a_disabled_row_rather_than_hiding_it
    _status, out, = run_cli("dump-config", "--profile", demo_profile)
    assert_match(/- id: approvals.*\n.*plugin: Terret::Tools::Approvals\n\s+disabled: true/, out)
  end

  # The swap that turns the sandbox off is the most consequential edit the
  # format allows. Attributing it to the bundle that shipped the row would be
  # the one piece of provenance nobody could afford to have wrong.
  def test_dump_config_names_the_layer_that_swapped_a_plugin
    profile_patch(demo_profile, "rows:\n  - id: sandbox\n    plugin: Terret::Exec::SandboxNone\n")
    _status, out, = run_cli("dump-config", "--profile", "demo")
    assert_match(%r{plugin: Terret::Exec::SandboxNone\s+# plugin: profiles/demo/patch\.yml}, out)
    refute_match(/plugin: Terret::Sandbox::Docker\s+# plugin:/, out,
                 "an unswapped row should not carry a plugin annotation at all")
  end

  def test_dump_config_renders_an_empty_list_as_a_list
    profile_patch(demo_profile, "rows:\n  - id: fs\n    config: { workspace: [] }\n")
    _status, out, = run_cli("dump-config", "--profile", "demo")
    assert_includes out, "workspace: []"
  end

  def test_dump_config_output_reparses_as_yaml_once_the_tags_are_declared
    _status, out, = run_cli("dump-config", "--profile", demo_profile)
    reparsed = Terret::Composition::Visitor.load(out, label: "dump")
    assert_equal Terret::Composition.resolve(profile: "demo").rows.map(&:id),
                 reparsed[:rows].map { |r| r[:id].to_s }
  end

  # -- doctor ----------------------------------------------------------------

  def test_doctor_prints_the_rows_and_is_honest_about_what_it_did_not_check
    status, out, = run_cli("doctor", "--profile", demo_profile)
    assert_equal 0, status
    assert_includes out, "session_store  Terret::Store::SQLite"
    assert_includes out, "approvals"
    assert_includes out, Terret::Doctor::PENDING
  end

  # -- failure ---------------------------------------------------------------

  def test_a_composition_failure_exits_one_with_the_reason_on_stderr
    profile("broken", "bundles: [nosuchbundle]\n")
    status, out, err = run_cli("dump-config", "--profile", "broken")
    assert_equal 1, status
    assert_empty out
    assert_includes err, "nosuchbundle"
  end

  def test_a_missing_profile_exits_one_rather_than_raising
    status, _out, err = run_cli("doctor", "--profile", "ghost")
    assert_equal 1, status
    assert_includes err, "ghost"
  end

  # Every one of these used to leave a backtrace on the terminal: the first two
  # raise outside Composition::Error, and a bad !ruby raises a ScriptError,
  # which is not a StandardError at all.
  def test_a_patch_that_does_not_exist_exits_one_with_a_message
    status, _out, err = run_cli("dump-config", "--profile", demo_profile, "--patch", "/no/such/file.yml")
    assert_equal 1, status
    assert_includes err, "trt:"
    refute_includes err, "cli.rb:"
  end

  def test_a_patch_that_is_a_directory_says_directory_not_missing
    dir = File.join(@home_dir, "somedir")
    FileUtils.mkdir_p(dir)
    status, _out, err = run_cli("dump-config", "--profile", demo_profile, "--patch", dir)
    assert_equal 1, status
    assert_includes err, "directory"
  end

  def test_an_unreadable_patch_exits_one_with_a_message
    path = write(File.join(@home_dir, "locked.yml"), "rows: []\n")
    File.chmod(0o000, path)
    skip "running as a user who can read anything" if File.readable?(path)

    status, _out, err = run_cli("dump-config", "--profile", demo_profile, "--patch", path)
    assert_equal 1, status
    assert_includes err, "cannot be read"
    refute_includes err, "cli.rb:"
  ensure
    File.chmod(0o600, path) if path && File.exist?(path)
  end

  def test_a_ruby_scalar_that_does_not_parse_exits_one_without_a_backtrace
    profile_patch(demo_profile, %(rows:\n  - id: llm\n    config: { model: !ruby "1 +" }\n))
    status, _out, err = run_cli("boot", "--profile", "demo", "--allow-config-ruby")
    assert_equal 1, status
    refute_includes err, "cli.rb:"
    refute_empty err
  end

  # -- boot teardown ---------------------------------------------------------

  def run_cli_boot(profile = "demo")
    out = StringIO.new
    err = StringIO.new
    opts = Terret::CLI::Options.new("boot", profile, [], nil, false)
    status = Terret::CLI.boot(opts, out: out, err: err)
    [status, out.string, err.string]
  end

  # A plain singleton-method swap, restored after the block. Kept local to
  # these tests so the suite stays runnable under the bundler-free lane, where
  # minitest/mock is not on the load path.
  def swapping(mod, name, impl)
    original = mod.method(name)
    mod.singleton_class.define_method(name, impl)
    yield
  ensure
    mod.singleton_class.define_method(name, original)
  end

  # A park that raises instead of catching its Interrupt used to return 1
  # without ever tearing the booted world down. Teardown belongs in an ensure,
  # so a context that came up is always shut down.
  def test_boot_tears_down_even_when_the_park_raises_after_boot_succeeds
    ctx = Object.new
    shut = []
    swapping(Terret, :boot, ->(**_kw) { ctx }) do
      swapping(Terret::CLI, :park, -> { raise "reactor died" }) do
        swapping(Terret::Boot, :shutdown, ->(c, **_kw) { shut << c }) do
          status, = run_cli_boot
          assert_equal 1, status
          assert_equal [ctx], shut, "a booted context must be torn down even when park raises"
        end
      end
    end
  end

  # The clean path still tears down exactly once (and only once).
  def test_boot_tears_down_on_a_clean_stop
    ctx = Object.new
    shut = []
    swapping(Terret, :boot, ->(**_kw) { ctx }) do
      swapping(Terret::CLI, :park, -> {}) do # returns as if the Interrupt was handled
        swapping(Terret::Boot, :shutdown, ->(c, **_kw) { shut << c }) do
          status, = run_cli_boot
          assert_equal 0, status
          assert_equal [ctx], shut
        end
      end
    end
  end

  # A Terret.boot that never returns a context leaves nothing to shut down, and
  # the ensure must not call shutdown with nil.
  def test_a_boot_that_fails_outright_does_not_try_to_shut_down_a_nil_context
    shut = []
    swapping(Terret, :boot, ->(**_kw) { raise "boot blew up" }) do
      swapping(Terret::Boot, :shutdown, ->(c, **_kw) { shut << c }) do
        status, _out, err = run_cli_boot
        assert_equal 1, status
        assert_includes err, "boot failed"
        assert_empty shut, "there is no context to tear down when boot itself failed"
      end
    end
  end

  # -- the executable --------------------------------------------------------

  def test_the_shipped_executable_runs
    exe = File.expand_path("../exe/trt", __dir__)
    assert File.executable?(exe), "#{exe} must be executable"
    out = IO.popen([RbConfig.ruby, exe, "--version"], err: %i[child out], &:read)
    assert_equal 0, $?.exitstatus, out
    assert_equal "trt #{Terret::Meta::VERSION}", out.strip
  end
end
