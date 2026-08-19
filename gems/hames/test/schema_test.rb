# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/hames"

# Hames::Schema is the kernel's own tiny config validator (docs/composition.md
# §9): a plain description of a service's config keys plus the code that checks
# a config hash against it. Pure stdlib — the kernel's zero-dependency rule is a
# design constraint, so no dry-schema.
class HamesSchemaTest < Minitest::Test
  def setup
    Hames::Schema.reset_declared!
  end

  # A class that carries a schema, so the DSL and its inheritance are exercised
  # against real classes rather than anonymous ones.
  class Sandbox < Hames::Service
    service_key :sandbox
    config_schema image:   { type: String, required: true, doc: "container image" },
                  network: { type: String, enum: %w[none bridge host], default: "none",
                             doc: "docker --network mode" },
                  jobs:    { type: Integer, default: 4, doc: "parallel jobs" }
  end

  # A subclass that does not redeclare inherits its parent's schema, the way a
  # test double or a provider variant mounts exactly like its parent.
  class SandboxVariant < Sandbox
    service_key :sandbox_variant
  end

  class Unschemad < Hames::Service
    service_key :bare
  end

  # -- the DSL ---------------------------------------------------------------

  def test_config_schema_stores_a_schema_on_the_class
    schema = Sandbox.config_schema
    assert_kind_of Hames::Schema, schema
    assert_equal %i[image network jobs], schema.keys.keys
  end

  def test_a_class_without_a_schema_reports_nil_the_unschemad_marker
    assert_nil Unschemad.config_schema
  end

  def test_a_subclass_inherits_its_parents_schema
    assert_same Sandbox.config_schema, SandboxVariant.config_schema
  end

  def test_an_empty_schema_is_declared_and_is_not_the_unschemad_marker
    klass = Class.new(Hames::Service) { config_schema({}) }
    refute_nil klass.config_schema, "config_schema({}) declares an empty schema, not unschema'd"
    assert_empty klass.config_schema.keys
  end

  # A functional plugin — one that only responds to apply, not a Service — can
  # extend the DSL and be schema'd too. This is how the OpenRouter plugin, which
  # is not a Service, still gets a schema doctor can read.
  def test_a_functional_plugin_can_extend_the_dsl
    plugin = Class.new do
      extend Hames::Schema::DSL
      config_schema api_key: { type: String, doc: "key" }
      def apply(ctx); end
    end
    assert_kind_of Hames::Schema, plugin.config_schema
    assert_equal %i[api_key], plugin.config_schema.keys.keys
  end

  # -- validation ------------------------------------------------------------

  def test_a_valid_config_has_no_errors_or_warnings
    result = Sandbox.config_schema.validate({ image: "ruby:slim", network: "none", jobs: 8 })
    assert_predicate result, :ok?
    assert_empty result.warnings
  end

  def test_a_missing_required_key_fails_naming_the_subject_and_key
    result = Sandbox.config_schema.validate({ network: "none" }, subject: "sandbox")
    refute_predicate result, :ok?
    assert_match(/sandbox: image/, result.errors.first)
    assert_match(/required/, result.errors.first)
  end

  def test_a_wrong_typed_value_fails_naming_the_key_and_expected_type
    result = Sandbox.config_schema.validate({ image: "x", jobs: "lots" }, subject: "sandbox")
    err = result.errors.find { |e| e.include?("jobs") }
    refute_nil err
    assert_match(/must be an Integer/, err) # article by leading sound, not "a Integer"
    assert_match(/got "lots"/, err)
  end

  # redact: false (the default) names the value — programmatic callers hold
  # plain config and the value is the useful part.
  def test_the_default_message_names_the_rejected_value
    result = Sandbox.config_schema.validate({ image: 1, network: "lan" }, subject: "s")
    assert(result.errors.any? { |e| e.include?("got 1") })
    assert(result.errors.any? { |e| e.include?(%(got "lan")) })
  end

  # redact: true names the TYPE only, never the content — doctor passes this so
  # a materialized !env/!setting secret can never reach the message.
  def test_redact_keeps_a_rejected_values_content_out_of_the_message
    secret = "sk-canary-9f3a-must-not-appear"
    type_result = Hames::Schema.build(n: { type: Integer })
                               .validate({ n: secret }, subject: "s", redact: true)
    refute_empty type_result.errors
    type_result.errors.each { |e| refute_includes e, secret }
    assert_match(/must be an Integer, got a String/, type_result.errors.first)

    enum_result = Hames::Schema.build(mode: { type: String, enum: %w[none host] })
                               .validate({ mode: secret }, subject: "s", redact: true)
    refute_empty enum_result.errors
    enum_result.errors.each { |e| refute_includes e, secret }
    assert_match(/must be one of "none", "host"/, enum_result.errors.first)
  end

  def test_an_enum_violation_fails_naming_the_allowed_set
    result = Sandbox.config_schema.validate({ image: "x", network: "lan" }, subject: "sandbox")
    err = result.errors.find { |e| e.include?("network") }
    refute_nil err
    assert_match(/none/, err)
    assert_match(/bridge/, err)
    assert_match(/host/, err)
  end

  def test_type_accepts_a_union_of_classes
    schema = Hames::Schema.build(workspace: { type: [String, Array] })
    assert_predicate schema.validate({ workspace: "/a" }), :ok?
    assert_predicate schema.validate({ workspace: ["/a", "/b"] }), :ok?
    refute_predicate schema.validate({ workspace: 5 }), :ok?
  end

  def test_a_boolean_type_is_the_true_false_union_and_renders_as_boolean
    schema = Hames::Schema.build(rg: { type: [TrueClass, FalseClass] })
    assert_predicate schema.validate({ rg: false }), :ok?
    result = schema.validate({ rg: "yes" }, subject: "files")
    refute_predicate result, :ok?
    assert_match(/must be a boolean/, result.errors.first)
  end

  # A key that is absent OR present-but-nil is "unset". A non-required unset key
  # is fine — its default applies, and an unset !env resolving to nil is an
  # ordinary state (§5), not a failure.
  def test_a_nil_value_for_a_non_required_key_is_not_an_error
    schema = Hames::Schema.build(api_key: { type: String })
    assert_predicate schema.validate({ api_key: nil }), :ok?
    assert_predicate schema.validate({}), :ok?
  end

  def test_a_nil_value_for_a_required_key_is_the_required_error
    schema = Hames::Schema.build(path: { type: String, required: true })
    result = schema.validate({ path: nil }, subject: "session_store")
    refute_predicate result, :ok?
    assert_match(/path is required/, result.errors.first)
  end

  # Config rows grow, so a row carrying a key from a newer version of a gem is a
  # warning about drift, not a boot that refuses.
  def test_extra_keys_warn_rather_than_fail
    result = Sandbox.config_schema.validate({ image: "x", surprise: 1 }, subject: "sandbox")
    assert_predicate result, :ok?, "an extra key must not be an error"
    assert_equal 1, result.warnings.length
    assert_match(/surprise/, result.warnings.first)
  end

  # A default fills a MISSING key at read time; it does not merge into config
  # (config layering is wholesale-replace). So validation of a missing defaulted
  # key passes without the schema mutating the config it was handed.
  def test_a_default_does_not_merge_into_the_validated_config
    config = { image: "x" }
    Sandbox.config_schema.validate(config)
    refute config.key?(:network), "validation must not inject a default into the config"
    refute config.key?(:jobs)
  end

  # -- the registry ----------------------------------------------------------

  def test_declaring_a_schema_registers_the_class_for_the_catalog
    klass = Class.new(Hames::Service) { config_schema foo: { type: String } }
    assert_includes Hames::Schema.declared.keys, klass
    assert_same klass.config_schema, Hames::Schema.declared[klass]
  end
end
