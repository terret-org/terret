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

  # Whatever a third-party gemspec does to itself stays in that gemspec. One
  # bad gem in the Gemfile must not take out every profile on the machine.
  def test_a_gemspec_that_makes_no_sense_is_not_a_bundle_and_not_a_crash
    ["bundle:\n  path: config/bundle.yml\n", "bundle: 7\n", "config/bun\0dle.yml", ""].each do |meta|
      found = C.discover_bundles(specs: [fixture_spec("odd-gem", @gems_dir, meta)])
      assert found.key?("terret"), "discovery must survive #{meta.inspect}"

      entry = found["odd-gem"]
      assert entry.nil? || entry.error,
             "#{meta.inspect}: must be absent or marked broken, never a usable bundle"
    end
  end

  def test_a_gemspec_with_no_gem_path_is_not_a_bundle
    skip "security pass Task 11: bundle-path containment (this fails open today)"
    refute C.discover_bundles(specs: [fixture_spec("no-path", nil, "config/bundle.yml")]).key?("no-path")
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

  def test_a_profile_name_may_not_climb_out_of_the_profiles_directory
    write(File.join(@home_dir, "elsewhere", "profile.yml"), "bundles: []\n")
    err = assert_raises(C::Error) { resolve("../elsewhere") }
    assert_includes err.message, "profile name"
  end

  # -- the tag reader, adversarially -----------------------------------------
  #
  # Everything below is a way of writing !env that is NOT `!env`. Each one used
  # to reach Psych's fall-through and come back as the bare string "DEMO_KEY",
  # which is the exact silent-drop docs/composition.md §5 says this visitor
  # exists to prevent.

  def tagged(text)
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", text)
    resolve.rows.find { |r| r.id == "llm" }.config[:model]
  end

  def assert_refused(text, *fragments)
    err = assert_raises(C::Error) { tagged(text) }
    fragments.each { |f| assert_includes err.message, f }
    err
  end

  def test_the_secondary_handle_spelling_of_a_local_tag_is_refused_not_dropped
    err = assert_refused("rows:\n  - id: llm\n    config: { model: !!env DEMO_KEY }\n", "env")
    assert_includes err.message, "!env", "the refusal should name the tag they meant"
  end

  def test_a_tag_directive_cannot_smuggle_a_local_tag_past_the_reader
    assert_refused("%TAG ! !!\n---\nrows:\n  - id: llm\n    config: { model: !env DEMO_KEY }\n", "env")
  end

  def test_a_verbatim_tag_is_refused_in_both_the_schema_and_private_forms
    assert_refused("rows:\n  - id: llm\n    config: { model: !<tag:yaml.org,2002:env> X }\n", "env")
    assert_refused("rows:\n  - id: llm\n    config: { model: !<x-private:env> X }\n", "x-private:env")
  end

  def test_a_tag_directive_cannot_smuggle_a_ruby_object_tag_either
    assert_refused("%TAG ! !!\n---\nrows:\n  - id: llm\n    config: { model: !ruby/object:Gem::Requirement {} }\n",
                   "ruby/object")
    assert_refused("rows:\n  - id: llm\n    config: { model: !!ruby/object:Gem::Requirement {} }\n",
                   "ruby/object")
  end

  def test_a_yaml_core_type_tag_still_works_because_psych_handles_it_safely
    assert_equal "5", tagged("rows:\n  - id: llm\n    config: { model: !!str 5 }\n")
    assert_equal 5, tagged("rows:\n  - id: llm\n    config: { model: !!int \"5\" }\n")
    assert_equal({ k: 1 }, tagged("rows:\n  - id: llm\n    config: { model: !!map { k: 1 } }\n"))
  end

  # Psych ignores a core tag that does not suit its node — `!!map hello` is the
  # string "hello" — which is the same silent drop, one type system down.
  def test_a_core_type_tag_on_the_wrong_kind_of_node_is_refused
    assert_refused("rows:\n  - id: llm\n    config: { model: !!map hello }\n", "map")
    assert_refused("rows:\n  - id: llm\n    config: { model: !!seq hello }\n", "seq")
    assert_refused("rows:\n  - id: llm\n    config: !!str\n      k: v\n", "str")
  end

  # map and seq are each bound to their own node kind, not to "a collection":
  # !!seq on a mapping is as much a silent drop as !!map on a scalar was.
  def test_a_collection_tag_is_bound_to_its_own_kind_of_collection
    assert_refused("rows:\n  - id: llm\n    config: !!seq\n      k: v\n", "seq")
    assert_refused("rows:\n  - id: llm\n    config: { model: !!map [1] }\n", "map")
  end

  def test_a_core_type_tag_psych_cannot_honour_fails_with_the_file_named
    assert_refused("rows:\n  - id: llm\n    config: { model: !!omap [] }\n", "omap")
    assert_refused("rows:\n  - id: llm\n    config: { model: !!float x }\n", "profiles/demo/patch.yml")
  end

  def test_a_tag_in_key_position_is_refused_rather_than_used_as_a_key
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: llm\n    config: { !setting a.b: 1 }\n")
    err = assert_raises(C::Error) { materialize(resolve) }
    assert_includes err.message, "key"
  end

  def test_an_alias_cycle_is_refused_rather_than_overflowing_the_stack
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: llm\n    config: &c\n      self: *c\n")
    err = assert_raises(C::Error) { resolve }
    assert_includes err.message, "cycle"
  end

  def test_an_alias_cycle_through_a_sequence_is_caught_too
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: llm\n    config:\n      list: &c\n        - *c\n")
    assert_includes assert_raises(C::Error) { resolve }.message, "cycle"
  end

  def test_the_same_anchor_used_twice_is_sharing_and_not_a_cycle
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: llm\n    config:\n      a: &s { k: 1 }\n      b: *s\n      c: { d: *s }\n")
    assert_equal({ k: 1 }, resolve.rows.find { |r| r.id == "llm" }.config[:b])
  end

  # A YAML billion-laughs: 24 lines, under 600 bytes, and an alias graph whose
  # PATHS number 2^24 though its NODES number 24. A cycle check that walks
  # paths rather than nodes turns this file into a hang, which is a denial of
  # service any bundle, patch or profile on the machine could hand you.
  def test_a_shared_alias_graph_is_walked_once_per_node_not_once_per_path
    require "timeout"
    lines = ["rows:", "  - id: llm", "    config:", "      l0: &l0 [x]"]
    (1..24).each { |i| lines << "      l#{i}: &l#{i} [*l#{i - 1}, *l#{i - 1}]" }
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "#{lines.join("\n")}\n")

    Timeout.timeout(10) { resolve }
  end

  def test_a_second_yaml_document_is_refused_rather_than_silently_dropped
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows: []\n---\nrows:\n  - id: llm\n    config: { model: sneaky }\n")
    assert_raises(C::Error) { resolve }
  end

  def test_an_env_name_yaml_allows_but_the_os_does_not_names_the_file
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", %(rows:\n  - id: llm\n    config: { model: !env "X\\u0000Y" }\n))
    err = assert_raises(C::Error) { materialize(resolve) }
    assert_includes err.message, "llm"
  end

  # -- shapes ----------------------------------------------------------------

  def test_a_patch_file_that_is_not_a_rows_mapping_says_so_instead_of_crashing
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "- id: llm\n  config: {}\n")
    err = assert_raises(C::Error) { resolve }
    assert_includes err.message, "rows:"

    profile_patch("demo", "just a scalar\n")
    assert_raises(C::Error) { resolve }
  end

  def test_a_row_config_that_is_not_a_mapping_is_refused_at_the_layer
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: llm\n    config: a string\n")
    err = assert_raises(C::Error) { resolve }
    assert_includes err.message, "llm"
  end

  def test_settings_that_is_not_a_mapping_is_refused_by_name
    profile("demo", "bundles: [terret]\nsettings: nope\n")
    err = assert_raises(C::Error) { resolve }
    assert_includes err.message, "settings"
  end

  def test_disabled_must_be_a_real_boolean_not_any_truthy_scalar
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", %(rows:\n  - id: tools\n    disabled: "false"\n))
    err = assert_raises(C::Error) { resolve }
    assert_includes err.message, "disabled"
  end

  def test_a_row_may_not_anchor_both_before_and_after
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: audit\n    plugin: A\n    before: tools\n    after: tools\n")
    err = assert_raises(C::Error) { resolve }
    assert_includes err.message, "audit"
  end

  # -- provenance, harder ----------------------------------------------------

  def test_a_plugin_swap_records_the_layer_that_swapped_it
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: llm\n    plugin: Demo::Fake\n")
    row = resolve.rows.find { |r| r.id == "llm" }
    assert_equal "terret-base", row.row_layer
    assert_equal "profiles/demo/patch.yml", row.plugin_layer,
                 "turning the sandbox off must not be attributed to the base bundle"
    assert_equal "terret-base", row.config_layer
  end

  def test_a_bundle_cannot_borrow_another_bundles_name_for_its_provenance
    liar = bundle("terret-liar", "name: terret-base\nrows:\n  - id: liar\n    plugin: L\n")
    profile("demo", "bundles: [terret, terret-liar]\n")
    row = resolve(catalog: base_catalog("terret-liar" => liar)).rows.find { |r| r.id == "liar" }
    assert_includes row.row_layer, "terret-liar", "the gem name is the part nobody can forge"
  end

  def test_a_materialize_failure_names_the_row_and_the_layer_that_wrote_it
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", %(rows:\n  - id: llm\n    config: { model: !ruby "1" }\n))
    err = assert_raises(C::Error) { materialize(resolve) }
    assert_includes err.message, "llm"
    assert_includes err.message, "profiles/demo/patch.yml"
  end

  # -- discovery, harder -----------------------------------------------------

  def test_a_bundle_may_not_point_at_a_file_outside_its_own_gem
    dir = File.join(@gems_dir, "terret-sneaky")
    write(File.join(@gems_dir, "outside.yml"), "rows:\n  - id: x\n    plugin: X\n")
    FileUtils.mkdir_p(dir)
    refute C.discover_bundles(specs: [fixture_spec("terret-sneaky", dir, "../outside.yml")])
            .key?("terret-sneaky")
  end

  def test_one_broken_bundle_does_not_break_a_profile_that_never_names_it
    broken = File.join(@gems_dir, "terret-broken")
    write(File.join(broken, "config", "bundle.yml"), "rows: [ this is not: valid: yaml\n")
    profile("demo", "bundles: [terret]\n")
    catalog = C.discover_bundles(specs: [fixture_spec("terret-broken", broken, "config/bundle.yml")])

    # The real terret-base, resolved beside a bundle that cannot parse.
    assert_includes C.resolve(profile: "demo", bundles: catalog).rows.map(&:id), "sandbox"

    profile("greedy", "bundles: [terret-broken]\n")
    err = assert_raises(C::Error) { C.resolve(profile: "greedy", bundles: catalog) }
    assert_includes err.message, "terret-broken"
  end

  # -- home ------------------------------------------------------------------

  def test_a_home_patch_applies_even_when_the_profile_comes_from_the_template
    write(File.join(@home_dir, "profiles", "headless", "patch.yml"),
          "rows:\n  - id: sandbox\n    plugin: Terret::Exec::SandboxNone\n    config: {}\n")
    row = C.resolve(profile: "headless", bundles: shipped_catalog)
           .rows.find { |r| r.id == "sandbox" }
    assert_equal "Terret::Exec::SandboxNone", row.plugin,
                 "an operator's patch.yml must not be dropped for lacking a sibling profile.yml"
  end

  # The meta-gem's own bundle, named explicitly. Going through discovery would
  # make the result depend on whatever else is installed on the machine.
  def shipped_catalog
    { "terret" => C.load_bundle(File.expand_path("../config/bundle.yml", __dir__), gem_name: "terret") }
  end

  # -- shared settings -------------------------------------------------------

  def test_a_setting_referenced_twice_hands_each_row_its_own_copy
    profile("demo", "bundles: [terret]\nsettings:\n  dirs: [/tmp/a]\n")
    profile_patch("demo", <<~YAML)
      rows:
        - id: sessions
          config: { workspace: !setting dirs }
        - id: tools
          config: { workspace: !setting dirs }
    YAML
    rows = materialize(resolve)
    a = rows["sessions"][:config][:workspace]
    b = rows["tools"][:config][:workspace]

    assert_equal a, b
    refute a.equal?(b), "two rows sharing a !setting must not share the object"
    a << "/tmp/b"
    assert_equal ["/tmp/a"], b, "mutating one row's config must not reach another's"
  end

  # -- scalars YAML types but a config does not carry ------------------------

  def test_a_bare_date_says_to_quote_it_rather_than_naming_a_psych_class
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: llm\n    config: { model: 2026-08-19 }\n")
    err = assert_raises(C::Error) { resolve }
    assert_includes err.message, "quote"
    assert_includes err.message, "2026-08-19"
  end

  def test_a_bare_symbol_says_the_same_thing
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: llm\n    config:\n      model: :fake\n")
    assert_includes assert_raises(C::Error) { resolve }.message, "quote"
  end

  # -- merge keys ------------------------------------------------------------

  def test_a_merge_key_whose_value_is_not_a_mapping_is_refused
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", "rows:\n  - id: llm\n    config:\n      <<: !env FOO\n      y: 2\n")
    err = assert_raises(C::Error) { resolve }
    assert_includes err.message, "<<"
    # Quoting does not get you a literal "<<" key — Psych still reads it as a
    # merge — so the refusal has to name the spelling that does.
    assert_includes err.message, "!!str"
  end

  def test_a_well_formed_merge_key_still_merges
    profile("demo", "bundles: [terret]\nsettings: {}\n")
    profile_patch("demo", <<~YAML)
      rows:
        - id: llm
          config:
            <<: &base { a: 1 }
            b: 2
    YAML
    assert_equal({ a: 1, b: 2 }, resolve.rows.find { |r| r.id == "llm" }.config)
  end

  def test_a_merge_key_pointing_at_a_list_of_mappings_merges_all_of_them
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", <<~YAML)
      rows:
        - id: llm
          config:
            a: &a { x: 1 }
            b: &b { y: 2 }
            c:
              <<: [*a, *b]
              z: 3
    YAML
    assert_equal({ x: 1, y: 2, z: 3 }, resolve.rows.find { |r| r.id == "llm" }.config[:c])
  end

  def test_the_tag_the_refusal_recommends_actually_produces_a_literal_key
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", %(rows:\n  - id: llm\n    config:\n      !!str "<<": literal\n      y: 2\n))
    assert_equal({ :"<<" => "literal", y: 2 }, resolve.rows.find { |r| r.id == "llm" }.config)
  end

  # -- unreadable and misdescribed files -------------------------------------

  def test_a_patch_that_is_a_directory_says_so_rather_than_no_such_file
    dir = File.join(@home_dir, "adir")
    FileUtils.mkdir_p(dir)
    profile("demo", "bundles: [terret]\n")
    err = assert_raises(C::Error) { resolve(patches: [dir]) }
    assert_includes err.message, "directory"
  end

  def test_an_unreadable_patch_reports_the_read_failure_by_name
    path = write(File.join(@home_dir, "locked.yml"), "rows: []\n")
    File.chmod(0o000, path)
    skip "running as a user who can read anything" if File.readable?(path)

    profile("demo", "bundles: [terret]\n")
    err = assert_raises(C::Error) { resolve(patches: [path]) }
    assert_includes err.message, "cannot be read"
  ensure
    File.chmod(0o600, path) if path && File.exist?(path)
  end

  def test_a_ruby_scalar_that_does_not_parse_is_a_composition_error
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", %(rows:\n  - id: llm\n    config: { model: !ruby "1 +" }\n))
    err = assert_raises(C::Error) { materialize(resolve, allow_config_ruby: true) }
    assert_includes err.message, "llm"
  end

  def test_a_ruby_scalar_that_raises_at_runtime_is_a_composition_error
    profile("demo", "bundles: [terret]\n")
    profile_patch("demo", %(rows:\n  - id: llm\n    config: { model: !ruby "raise 'nope'" }\n))
    assert_includes assert_raises(C::Error) { materialize(resolve, allow_config_ruby: true) }.message, "nope"
  end
end
