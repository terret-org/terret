# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/terret"

class SessionsPrimitivesTest < Minitest::Test
  def sessions_ctx
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions }
    ])
    loader.boot!
  end

  def test_symbols_in_value_position_become_strings
    ctx = sessions_ctx
    s = ctx[:sessions].create
    ev = ctx[:sessions].append(s.id, "turn/end", { status: :failed })
    assert_equal "failed", ev.payload[:status]
  end

  def test_payloads_survive_a_json_round_trip_exactly
    ctx = sessions_ctx
    s = ctx[:sessions].create
    ev = ctx[:sessions].append(s.id, "tool/call",
                               { id: "t1", name: "weather", args: { :city => "CDMX", "n" => 2 } })
    tripped = JSON.parse(JSON.generate(ev.payload), symbolize_names: true)
    assert_equal ev.payload, tripped
    assert_equal 2, ev.payload[:args][:n] # string key coerced to symbol
  end

  def test_non_primitive_payloads_are_rejected
    ctx = sessions_ctx
    s = ctx[:sessions].create
    assert_raises(Terret::NonPrimitivePayload) do
      ctx[:sessions].append(s.id, "user/message", { text: Object.new })
    end
  end

  def test_non_finite_floats_are_rejected_at_the_boundary
    ctx = sessions_ctx
    s = ctx[:sessions].create
    [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |bad|
      assert_raises(Terret::NonPrimitivePayload) do
        ctx[:sessions].append(s.id, "user/message", { value: bad })
      end
    end
  end

  def test_hash_keys_must_be_symbols_or_strings
    ctx = sessions_ctx
    s = ctx[:sessions].create
    assert_raises(Terret::NonPrimitivePayload) do
      ctx[:sessions].append(s.id, "user/message", { Object.new => "x" })
    end
    assert_raises(Terret::NonPrimitivePayload) do
      ctx[:sessions].append(s.id, "user/message", { 1 => "x" })
    end
  end
end
