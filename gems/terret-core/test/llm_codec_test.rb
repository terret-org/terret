# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/terret"

# The part codec is the typed edge of the primitives contract: durable logs
# hold only storage-shaped hashes; adapters see only Data objects.
class LLMPartCodecTest < Minitest::Test
  L = Terret::LLM

  PARTS = [
    L::Text.new(text: "hello"),
    L::ToolCall.new(id: "tc1", name: "weather", args: { city: "CDMX" }),
    L::ToolResult.new(id: "tc1", content: "22C", error: nil),
    L::ToolResult.new(id: "tc2", content: nil, error: "denied")
  ].freeze

  def test_every_part_type_round_trips_through_primitives_and_json
    PARTS.each do |part|
      encoded = L.encode_part(part)
      tripped = JSON.parse(JSON.generate(encoded), symbolize_names: true)
      assert_equal part, L.decode_part(tripped)
    end
  end

  def test_encoded_parts_carry_storage_names_not_class_names
    assert_equal "tool_call", L.encode_part(PARTS[1])[:type]
    refute_match(/Terret/, JSON.generate(L.encode_part(PARTS[1])))
  end

  def test_unknown_part_and_unknown_tag_raise
    assert_raises(ArgumentError) { L.encode_part(Object.new) }
    assert_raises(ArgumentError) { L.decode_part({ type: "hologram" }) }
  end
end
