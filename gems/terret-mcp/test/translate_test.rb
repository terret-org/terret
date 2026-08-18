# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret/mcp/translate"

class TranslateTest < Minitest::Test
  T = Terret::MCP::Translate

  FakeTool = Struct.new(:name, :description, :input_schema)
  FakeContent = Struct.new(:type, :text, :mime_type, :uri)
  FakeResult = Struct.new(:content, :structured_content, keyword_init: true) do
    def error? = false
    def structured? = !structured_content.nil?
  end
  FakeError = Struct.new(:content, keyword_init: true) do
    def error? = true
    def structured_content = nil
    def structured? = false
    def text = content.map(&:text).compact.join("\n")
  end

  def test_namespaces_and_maps_a_tool_definition
    tool = FakeTool.new("search", "Find things", { "type" => "object", "properties" => {} })
    reg = T.definition_args(server: "nexus", tool: tool, approval: :policy)

    assert_equal "mcp__nexus__search", reg[:name]
    assert_equal "Find things", reg[:description]
    assert_equal({ "type" => "object", "properties" => {} }, reg[:params])
    assert_equal :policy, reg[:approval]
    assert reg[:mutating], "unknown remote effects default to mutating"
  end

  def test_rejects_bad_server_names
    assert_raises(ArgumentError) { T.assert_server_name!("no spaces") }
    assert_raises(ArgumentError) { T.assert_server_name!("Upper") }
    assert_equal "ok-name_1", T.assert_server_name!("ok-name_1")
  end

  def test_structured_content_wins_and_is_returned_as_primitives
    result = FakeResult.new(content: [FakeContent.new("text", "ignored", nil)],
                            structured_content: { "total" => 3 })
    assert_equal({ "total" => 3 }, T.result_content(result))
  end

  def test_text_items_join_and_binary_items_degrade_to_placeholders
    result = FakeResult.new(content: [
      FakeContent.new("text", "line one", nil),
      FakeContent.new("image", nil, "image/png"),
      FakeContent.new("text", "line two", nil)
    ], structured_content: nil)
    assert_equal "line one\n[image image/png]\nline two", T.result_content(result)
  end

  def test_an_error_result_maps_to_the_error_channel
    err = FakeError.new(content: [FakeContent.new("text", "boom", nil)])
    assert_nil T.result_content(err)
    assert_equal "boom", T.result_error(err)
  end

  def test_a_falsy_structured_result_still_wins_over_text
    result = FakeResult.new(content: [FakeContent.new("text", "fallback", nil)],
                            structured_content: false)
    assert_equal false, T.result_content(result)
  end

  def test_resource_links_surface_their_uri_in_the_placeholder
    result = FakeResult.new(content: [FakeContent.new("resource_link", nil, nil, "doc://guide")],
                            structured_content: nil)
    assert_equal "[resource_link doc://guide]", T.result_content(result)
  end
end
