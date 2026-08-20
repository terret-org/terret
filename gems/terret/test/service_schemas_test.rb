# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret/boot"
require_relative "../lib/terret/schema_gems"

# Every service in the base bundle either declares a config_schema against the
# keys it actually reads, or is deliberately unschema'd. These lock the
# declarations so a service that grows a config key without extending its schema
# is caught here rather than in doctor's silence (docs/composition.md §9).
class ServiceSchemasTest < Minitest::Test
  # The same list rake config:catalog uses, so the catalog and these tests can
  # never disagree about which gems ship schemas.
  Terret::SCHEMA_GEMS.each { |f| require f }

  def schema(klass) = klass.config_schema

  def test_sqlite_store_requires_a_path
    spec = schema(Terret::Store::SQLite).keys[:path]
    assert spec.required
    assert_equal String, spec.type
  end

  def test_docker_sandbox_schemas_its_image_network_and_workspace
    keys = schema(Terret::Sandbox::Docker).keys
    assert_equal %i[image network workspace user docker_bin], keys.keys
    assert_equal [String, Array], keys[:workspace].type
    assert_equal "none", keys[:network].default
  end

  def test_web_fetch_schemas_config_but_not_its_injectable_seams
    keys = schema(Terret::ToolsStd::WebFetch).keys.keys
    assert_includes keys, :allow
    assert_includes keys, :max_bytes
    refute_includes keys, :transport, "an injectable seam is wiring, not YAML config"
    refute_includes keys, :resolver
  end

  def test_the_openrouter_plugin_carries_a_schema_though_it_is_not_a_seam_service
    spec = schema(Terret::OpenRouter::Plugin).keys[:api_key]
    refute_nil spec
    assert_equal String, spec.type
    refute spec.required, "api_key falls back to ENV, so it is not required"
  end

  def test_loop_defaults_max_agents
    assert_equal 128, schema(Terret::Loop).keys[:max_agents].default
  end

  # A service that reads no config declares an empty schema (approvals,
  # subagents) — present, so doctor calls it ok rather than unschema'd.
  def test_a_no_config_service_declares_an_empty_schema
    refute_nil Terret::Subagents.config_schema
    assert_empty Terret::Subagents.config_schema.keys
  end

  # ACP over stdio has no config surface (the transport is the client's own
  # stdin/stdout, auth is the process boundary), so it declares an empty schema
  # rather than being unschema'd.
  def test_the_acp_interface_declares_an_empty_schema
    refute_nil Terret::ACP::Service.config_schema
    assert_empty Terret::ACP::Service.config_schema.keys
  end
end
