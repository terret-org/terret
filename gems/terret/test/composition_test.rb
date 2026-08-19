# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/terret/composition"

# Pure resolution: YAML in, ordered rows plus provenance out, nothing mounted
# and no constant resolved (docs/composition.md §7). Every test points
# TERRET_HOME at a tmpdir, so none of this can read the operator's real home.
class CompositionTest < Minitest::Test
  C = Terret::Composition

  def setup
    @home_dir = Dir.mktmpdir("terret-home")
    @gems_dir = Dir.mktmpdir("terret-gems")
    @prev_home = ENV["TERRET_HOME"]
    ENV["TERRET_HOME"] = @home_dir
  end

  def teardown
    ENV["TERRET_HOME"] = @prev_home
    FileUtils.remove_entry(@home_dir) if File.directory?(@home_dir)
    FileUtils.remove_entry(@gems_dir) if File.directory?(@gems_dir)
  end

  # -- fixtures --------------------------------------------------------------

  def write(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  # A bundle on disk, loaded the way discovery loads one.
  def bundle(gem_name, body)
    path = write(File.join(@gems_dir, gem_name, "config", "bundle.yml"), body)
    C.load_bundle(path, gem_name: gem_name)
  end

  def profile(name, body) = write(File.join(@home_dir, "profiles", name, "profile.yml"), body)
  def profile_patch(name, body) = write(File.join(@home_dir, "profiles", name, "patch.yml"), body)
  def home_patch(body) = write(File.join(@home_dir, "patch.yml"), body)

  BASE = <<~YAML
    name: terret-base
    rows:
      - id: sessions
        plugin: Demo::Sessions
      - id: tools
        plugin: Demo::Tools
      - id: llm
        plugin: Demo::LLM
        config:
          api_key: !env DEMO_KEY
          model: gpt-fake
  YAML

  def base_catalog(extra = {}) = { "terret" => bundle("terret", BASE) }.merge(extra)

  def resolve(name = "demo", catalog: base_catalog, patches: [])
    C.resolve(profile: name, patches: patches, bundles: catalog)
  end

  # -- rows and layer order --------------------------------------------------

  def test_bundle_rows_load_in_the_order_the_file_lists_them
    profile("demo", "bundles: [terret]\n")
    assert_equal %w[sessions tools llm], resolve.rows.map(&:id)
  end

  def test_a_profile_stacks_bundles_in_listed_order
    extra = bundle("terret-fortune", <<~YAML)
      name: terret-fortune
      rows:
        - id: fortune
          plugin: Fortune::Teller
    YAML
    profile("demo", "bundles: [terret, terret-fortune]\n")
    rows = resolve(catalog: base_catalog("terret-fortune" => extra)).rows
    assert_equal %w[sessions tools llm fortune], rows.map(&:id)

    profile("reversed", "bundles: [terret-fortune, terret]\n")
    rows = resolve("reversed", catalog: base_catalog("terret-fortune" => extra)).rows
    assert_equal %w[fortune sessions tools llm], rows.map(&:id)
  end

  def test_an_unknown_bundle_name_fails_closed_listing_what_was_discovered
    profile("demo", "bundles: [terret, terret-nope]\n")
    err = assert_raises(C::Error) { resolve }
    assert_includes err.message, "terret-nope"
    assert_includes err.message, "terret" # the discovered set is named
  end

  # -- patches ---------------------------------------------------------------

  def test_a_patch_replaces_a_rows_config_wholesale_and_never_deep_merges
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", <<~YAML)
      rows:
        - id: llm
          config:
            model: gpt-other
    YAML
    llm = resolve.rows.find { |r| r.id == "llm" }
    assert_equal({ model: "gpt-other" }, llm.config)
    refute_includes llm.config.keys, :api_key, "the base row's api_key must be dropped, not merged"
  end

  def test_a_patch_may_swap_the_plugin_on_an_existing_row
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", <<~YAML)
      rows:
        - id: llm
          plugin: Demo::Fake
    YAML
    llm = resolve.rows.find { |r| r.id == "llm" }
    assert_equal "Demo::Fake", llm.plugin
    assert_equal({ api_key: C::Tagged.new(tag: "env", argument: "DEMO_KEY"), model: "gpt-fake" },
                 llm.config, "a patch that mentions no config leaves the config alone")
  end

  def test_layers_apply_bundles_then_profile_patch_then_home_patch_then_cli_patches
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: llm\n    config: { model: from-profile }\n")
    home_patch("rows:\n  - id: llm\n    config: { model: from-home }\n")
    cli = write(File.join(@gems_dir, "cli.yml"), "rows:\n  - id: llm\n    config: { model: from-cli }\n")

    assert_equal "from-home", resolve.rows.find { |r| r.id == "llm" }.config[:model]
    assert_equal "from-cli", resolve(patches: [cli]).rows.find { |r| r.id == "llm" }.config[:model]
  end

  def test_a_patch_can_disable_a_row_without_removing_it_from_the_tree
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: tools\n    disabled: true\n")
    tools = resolve.rows.find { |r| r.id == "tools" }
    assert tools.disabled
    assert_equal %w[sessions tools llm], resolve.rows.map(&:id)
  end

  # -- insertion anchors -----------------------------------------------------

  def test_a_new_row_inserts_after_its_anchor
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: audit\n    plugin: Acme::Audit\n    after: tools\n")
    assert_equal %w[sessions tools audit llm], resolve.rows.map(&:id)
  end

  def test_a_new_row_inserts_before_its_anchor
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: audit\n    plugin: Acme::Audit\n    before: tools\n")
    assert_equal %w[sessions audit tools llm], resolve.rows.map(&:id)
  end

  def test_a_new_row_without_an_anchor_fails_closed_naming_the_id
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: audit\n    plugin: Acme::Audit\n")
    err = assert_raises(C::Error) { resolve }
    assert_includes err.message, "audit"
    assert_includes err.message, "after"
  end

  def test_a_new_row_anchored_to_an_unknown_id_fails_closed_naming_both
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: audit\n    plugin: Acme::Audit\n    after: nosuchrow\n")
    err = assert_raises(C::Error) { resolve }
    assert_includes err.message, "audit"
    assert_includes err.message, "nosuchrow"
  end

  # -- provenance ------------------------------------------------------------

  def test_provenance_records_the_layer_that_contributed_each_row_and_each_config
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", <<~YAML)
      rows:
        - id: llm
          config: { model: patched }
        - id: audit
          plugin: Acme::Audit
          after: tools
    YAML
    by_id = resolve.rows.to_h { |r| [r.id, r] }

    assert_equal "terret-base", by_id["sessions"].row_layer
    assert_equal "terret-base", by_id["sessions"].config_layer
    assert_equal "terret-base", by_id["llm"].row_layer
    assert_equal "profiles/demo/patch.yml", by_id["llm"].config_layer
    assert_equal "profiles/demo/patch.yml", by_id["audit"].row_layer
  end

  # -- tagged scalars --------------------------------------------------------

  def materialize(res, allow_config_ruby: false)
    res.materialize(allow_config_ruby: allow_config_ruby).to_h { |r| [r[:id], r] }
  end

  def test_env_resolves_from_the_environment_and_answers_nil_when_unset
    profile("demo", "bundles: [terret]\n")
    ENV["DEMO_KEY"] = "sk-from-env"
    assert_equal "sk-from-env", materialize(resolve)["llm"][:config][:api_key]
    ENV.delete("DEMO_KEY")
    assert_nil materialize(resolve)["llm"][:config][:api_key]
  ensure
    ENV.delete("DEMO_KEY")
  end

  def test_setting_resolves_a_dotted_path_against_the_profiles_settings_map
    profile("demo", <<~YAML)
      bundles: [terret]
      settings:
        model:
          main: anthropic/claude-opus-4.5
    YAML
    profile_patch("demo", "rows:\n  - id: llm\n    config: { model: !setting model.main }\n")
    assert_equal "anthropic/claude-opus-4.5", materialize(resolve)["llm"][:config][:model]
  end

  def test_setting_fails_closed_on_a_missing_path_naming_the_path
    profile("demo", "bundles: [terret]\nsettings:\n  model:\n    main: x\n")
    profile_patch("demo", "rows:\n  - id: llm\n    config: { model: !setting model.nope }\n")
    err = assert_raises(C::Error) { materialize(resolve) }
    assert_includes err.message, "model.nope"
  end

  def test_ruby_is_refused_without_consent_and_evaluates_with_it
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", %(rows:\n  - id: llm\n    config: { model: !ruby "1 + 1" }\n))
    err = assert_raises(C::Error) { materialize(resolve) }
    assert_includes err.message, "allow_config_ruby"
    assert_equal 2, materialize(resolve, allow_config_ruby: true)["llm"][:config][:model]
  end

  def test_an_unknown_local_tag_fails_closed_naming_the_tag
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: llm\n    config: { model: !bogus whatever }\n")
    err = assert_raises(C::Error) { resolve }
    assert_includes err.message, "!bogus"
  end

  def test_a_ruby_object_tag_is_refused_like_any_other_unknown_tag
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: llm\n    config: { model: !ruby/object:Struct {} }\n")
    err = assert_raises(C::Error) { resolve }
    assert_includes err.message, "ruby/object"
  end

  def test_a_local_tag_on_a_collection_is_refused_rather_than_silently_dropped
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: llm\n    config: !env { a: 1 }\n")
    assert_raises(C::Error) { resolve }
  end

  def test_tags_survive_resolution_unresolved_so_dump_config_can_print_them
    profile("demo", "bundles: [terret]\n")
    ENV["DEMO_KEY"] = "sk-secret"
    tag = resolve.rows.find { |r| r.id == "llm" }.config[:api_key]
    assert_equal C::Tagged.new(tag: "env", argument: "DEMO_KEY"), tag
    assert_equal "!env DEMO_KEY", tag.to_s
  ensure
    ENV.delete("DEMO_KEY")
  end

  # -- discovery -------------------------------------------------------------

  def test_discovery_reads_bundles_off_gemspec_metadata
    dir = File.join(@gems_dir, "terret-fortune")
    write(File.join(dir, "config", "bundle.yml"), "name: fortune\nrows:\n  - id: f\n    plugin: F\n")
    spec = fixture_spec("terret-fortune", dir, "config/bundle.yml")

    found = C.discover_bundles(specs: [spec])
    assert_equal "fortune", found["terret-fortune"].name
    assert_equal %w[f], found["terret-fortune"].rows.map { |r| r[:id] }
  end

  def test_discovery_finds_the_meta_gems_own_bundle_without_gem_installation
    found = C.discover_bundles(specs: [])
    assert found.key?("terret"), "terret-base must resolve from the monorepo checkout"
    assert_equal "terret-base", found["terret"].name
  end

  def test_a_gem_whose_metadata_carries_no_terret_key_is_not_a_bundle
    spec = fixture_spec("plain-gem", @gems_dir, nil)
    refute C.discover_bundles(specs: [spec]).key?("plain-gem")
  end

  def fixture_spec(name, dir, bundle_path)
    spec = Gem::Specification.new do |g|
      g.name = name
      g.version = "1.0.0"
      g.summary = "fixture"
      g.authors = ["t"]
      g.files = []
    end
    spec.metadata = bundle_path ? { "terret" => bundle_path } : {}
    spec.define_singleton_method(:full_gem_path) { dir }
    spec
  end

  # -- home ------------------------------------------------------------------

  def test_terret_home_overrides_the_default_dotfile_directory
    assert_equal @home_dir, Terret::Home.resolve.path
    ENV.delete("TERRET_HOME")
    assert_equal File.expand_path("~/.terret"), Terret::Home.resolve.path
    assert_equal "/somewhere/else", Terret::Home.resolve("/somewhere/else").path
  end

  def test_a_missing_profile_says_where_it_looked
    err = assert_raises(C::Error) { resolve("nosuch") }
    assert_includes err.message, "nosuch"
    assert_includes err.message, @home_dir
  end
end
