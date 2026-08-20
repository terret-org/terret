# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../lib/terret/boot"

# A third-party-style plugin: a real Hames::Service that declares NO schema. It
# stands in for the genuine unaudited case doctor's `unschema'd` now signals,
# since every first-party service declares a schema (an empty one when it reads
# no config). Named at the top level because a plugin: is a constant resolved
# out of YAML, same as any other row's.
class CLITestUnauditedPlugin < Hames::Service
  service_key :cli_test_unaudited
end

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

  # acp is a registered command (else this would be "unknown command"), and it
  # needs a profile like the others. Serving over stdio is exercised end to end
  # in terret-acp's cli_test; here we only pin the routing.
  def test_acp_is_a_known_command_that_needs_a_profile
    status, _out, err = run_cli("acp")
    assert_equal 2, status
    assert_includes err, "--profile"
    assert_includes Terret::CLI::COMMANDS, "acp"
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

  # !env/!setting stay unresolved here, but a LITERAL secret typed straight into
  # a config value is a plain scalar and used to print in full — and this output
  # exists to be pasted into an issue. A secret-shaped literal is redacted.
  def test_dump_config_redacts_a_literal_secret_typed_into_a_value
    demo_profile
    profile_patch("demo", %(rows:\n  - id: llm\n    config: { api_key: "sk-live-literal-abcdef123456" }\n))
    _status, out, = run_cli("dump-config", "--profile", "demo")
    refute_includes out, "sk-live-literal-abcdef123456"
    assert_includes out, "redacted"
  end

  # Row ids are validated at resolution, but a plugin NAME is printed verbatim
  # and never validated (it is a constant path with ::). A newline in a patched
  # plugin: could forge a provenance line; dump-config renders it control-safe.
  def test_dump_config_neutralizes_a_control_character_in_a_plugin_name
    demo_profile
    profile_patch("demo", %(rows:\n  - id: sessions\n    plugin: "Ok::Real\\nfake: forged"\n))
    _status, out, = run_cli("dump-config", "--profile", "demo")
    refute_match(/^fake: forged/, out)
    assert_includes out, "Real\\nfake"
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

  def test_doctor_reports_a_healthy_profile_as_all_ok_and_exits_zero
    status, out, = run_cli("doctor", "--profile", demo_profile)
    assert_equal 0, status
    assert_match(/row\s+plugin\s+status/, out)
    assert_match(/session_store\s+Terret::Store::SQLite\s+ok/, out)
    refute_includes out, "error:"
  end

  # A plugin that declares no schema is reported, not failed. Every first-party
  # service now declares one, so unschema'd signals an external/unaudited plugin
  # — exercised here with a fixture that resolves but carries no schema.
  def test_doctor_marks_an_unaudited_plugin_unschemad_and_stays_green
    profile_patch(demo_profile, "rows:\n  - id: audit\n    plugin: CLITestUnauditedPlugin\n    after: sessions\n")
    status, out, = run_cli("doctor", "--profile", "demo")
    assert_equal 0, status
    assert_match(/audit\s+CLITestUnauditedPlugin\s+unschema'd/, out)
  end

  # The other half of that semantic: a first-party service that reads no config
  # declares an empty schema, so doctor calls it ok — audited, not unschema'd.
  def test_doctor_reports_a_no_config_first_party_service_as_ok
    status, out, = run_cli("doctor", "--profile", demo_profile)
    assert_equal 0, status
    assert_match(/sessions\s+Terret::Sessions\s+ok/, out)
    refute_includes out, "unschema'd"
  end

  def test_doctor_flags_a_wrong_typed_value_naming_the_row_and_key_and_exits_one
    profile_patch(demo_profile, "rows:\n  - id: session_store\n    config: { path: 123 }\n")
    status, out, = run_cli("doctor", "--profile", "demo")
    assert_equal 1, status
    assert_match(/session_store.*error/, out)
    assert_includes out, "path must be a String"
  end

  def test_doctor_flags_a_missing_required_key
    profile_patch(demo_profile, "rows:\n  - id: session_store\n    config: {}\n")
    status, out, = run_cli("doctor", "--profile", "demo")
    assert_equal 1, status
    assert_includes out, "path is required"
  end

  # A row whose plugin constant does not resolve is exactly what doctor is for
  # (docs/composition.md §1), reported rather than discovered halfway through a
  # boot.
  def test_doctor_reports_a_plugin_that_does_not_resolve_and_exits_one
    profile_patch(demo_profile, "rows:\n  - id: sessions\n    plugin: Terret::Nope::Missing\n")
    status, out, = run_cli("doctor", "--profile", "demo")
    assert_equal 1, status
    assert_match(/sessions.*Terret::Nope::Missing.*error/, out)
  end

  # A plugin: that resolves to a live constant that is not a plugin (a typo
  # hitting String, a module) is a wrong plugin:, not "a plugin with no schema"
  # — it must be an error, not a green unschema'd row.
  def test_doctor_flags_a_resolved_constant_that_is_not_a_plugin
    profile_patch(demo_profile, "rows:\n  - id: sessions\n    plugin: String\n")
    status, out, = run_cli("doctor", "--profile", "demo")
    assert_equal 1, status
    assert_match(/sessions\s+String\s+error.*not a plugin/, out)
    refute_match(/String\s+unschema'd/, out)
  end

  # doctor is the SAFE preview: it "validates config, not the world"
  # (docs/composition.md §9). It must not run a profile's requires to do its
  # job, or `trt doctor` on an untrusted profile — the documented safe way to
  # inspect one before booting — is itself arbitrary code execution. A
  # path-shaped require is reported, never executed, without --allow-config-ruby.
  def test_doctor_does_not_execute_a_path_shaped_profile_require
    evil = File.join(@home_dir, "evil_doctor.rb")
    File.write(evil, "$evil_doctor_ran = true\n")
    profile("demo", <<~YAML)
      bundles: [terret]
      plugins:
        - #{evil}
      settings:
        workspace: []
        store: { path: /tmp/demo.db }
        model: { main: openrouter/some/model }
        sandbox: { image: demo:latest }
    YAML

    _status, out, = run_cli("doctor", "--profile", "demo")
    refute $evil_doctor_ran, "doctor must not require a filesystem path from a profile"
    assert_includes out, "evil_doctor.rb"
  ensure
    $evil_doctor_ran = nil
  end

  # doctor prints a plugin name into its table and, when the constant does not
  # resolve, into the error detail. A newline in a patched plugin: could forge a
  # table row; doctor renders both control-safe.
  def test_doctor_neutralizes_a_control_character_in_a_plugin_name
    profile_patch(demo_profile, %(rows:\n  - id: sessions\n    plugin: "Ok::Real\\nfake row forged"\n))
    _status, out, = run_cli("doctor", "--profile", "demo")
    refute_match(/^fake row forged/, out)
  end

  # A bad !ruby in a ROW is attributed to that row and does not abort the run;
  # boot-level !ruby is covered elsewhere, this locks the per-row doctor path.
  def test_doctor_attributes_a_bad_ruby_scalar_to_its_row
    profile_patch(demo_profile, %(rows:\n  - id: loop\n    config: { max_agents: !ruby "1 +" }\n))
    status, out, = run_cli("doctor", "--profile", "demo", "--allow-config-ruby")
    assert_equal 1, status
    assert_match(/loop.*error.*ruby/, out)
    assert_match(/session_store\s+Terret::Store::SQLite\s+ok/, out, "the rest of the table still renders")
  end

  # A bad !ruby/!setting in settings: is reported as its own error line, and the
  # row table still renders rather than the whole run aborting.
  def test_doctor_reports_a_settings_level_failure_without_hiding_the_table
    profile("badsettings", <<~YAML)
      bundles: [terret]
      settings:
        workspace: []
        store: { path: /tmp/x.db }
        model: { main: openrouter/some/model }
        sandbox: { image: x:latest }
        danger: !ruby "1 + 1"
    YAML
    status, out, = run_cli("doctor", "--profile", "badsettings")
    assert_equal 1, status
    assert_match(/error\s+.*settings.*ruby/, out)
    assert_match(/row\s+plugin\s+status/, out, "the row table must still render")
  end

  # Config rows grow: a key from a newer gem version warns about drift rather
  # than failing a boot.
  def test_doctor_warns_on_an_extra_key_without_going_red
    profile_patch(demo_profile, "rows:\n  - id: loop\n    config: { max_agents: 4, surprise: 1 }\n")
    status, out, = run_cli("doctor", "--profile", "demo")
    assert_equal 0, status
    assert_match(/loop.*warn/, out)
    assert_includes out, "surprise"
  end

  # Doctor validates config, not the world: an unset !env is an informational
  # line, never a failure. The entire value of the command is that its exit
  # status can be trusted in CI.
  def test_doctor_reports_env_markers_as_informational_never_as_failures
    demo_profile
    ENV.delete("OPENROUTER_API_KEY")
    status, out, = run_cli("doctor", "--profile", "demo")
    assert_equal 0, status
    assert_match(/info\s+OPENROUTER_API_KEY: unset/, out)
    refute_includes out, "error:"
  end

  # The promise doctor.rb and composition.md §9 make: doctor validates AFTER
  # materialize, so a validation error whose message echoed the value would
  # print a resolved secret. An Integer-typed key wired to !env resolves to the
  # (string) secret and type-mismatches — the reachable leak vector.
  def test_doctor_never_echoes_a_resolved_value_in_a_validation_error
    profile_patch(demo_profile, "rows:\n  - id: loop\n    config: { max_agents: !env DOCTOR_CANARY }\n")
    ENV["DOCTOR_CANARY"] = "sk-canary-must-never-be-printed"
    status, out, = run_cli("doctor", "--profile", "demo")
    assert_equal 1, status
    assert_match(/loop.*error.*must be an Integer/, out)
    refute_includes out, "sk-canary-must-never-be-printed"
  ensure
    ENV.delete("DOCTOR_CANARY")
  end

  def test_doctor_reports_a_set_env_marker_as_set
    demo_profile
    ENV["OPENROUTER_API_KEY"] = "sk-present"
    status, out, = run_cli("doctor", "--profile", "demo")
    assert_equal 0, status
    assert_match(/info\s+OPENROUTER_API_KEY: set/, out)
    refute_includes out, "sk-present", "doctor must not print the resolved secret"
  ensure
    ENV.delete("OPENROUTER_API_KEY")
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
