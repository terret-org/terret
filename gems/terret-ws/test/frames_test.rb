# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/terret/ws/frames"

class FramesTest < Minitest::Test
  F = Terret::WS::Frames

  def test_decodes_every_client_frame_type
    assert_equal 3, F.decode(%({"type":"subscribe","from_seq":3}))[:from_seq]
    assert_equal "hi", F.decode(%({"type":"inject","text":"hi","wake":true}))[:text]
    assert_nil F.decode(%({"type":"cancel"}))[:reason]
    assert_equal "tc1", F.decode(%({"type":"approve","call_id":"tc1"}))[:call_id]
    assert_equal "meh", F.decode(%({"type":"deny","call_id":"tc1","reason":"meh"}))[:reason]
    assert_equal "main", F.decode(%({"type":"set_model","role":"main","model":"a/b"}))[:role]
  end

  def test_rejects_garbage_unknown_types_and_missing_fields
    assert_raises(F::BadFrame) { F.decode("not json") }
    assert_raises(F::BadFrame) { F.decode("[1,2]") }
    assert_raises(F::BadFrame) { F.decode(%({"type":"launch_missiles"})) }
    assert_raises(F::BadFrame) { F.decode(%({"type":"inject"})) }
    assert_raises(F::BadFrame) { F.decode(%({"type":"subscribe"})) }
    assert_raises(F::BadFrame) { F.decode(%({"type":"subscribe","from_seq":-1})) }
    assert_raises(F::BadFrame) { F.decode(%({"type":"subscribe","from_seq":"0"})) }
  end

  def test_rejects_wrong_typed_fields_before_they_reach_a_seam
    assert_raises(F::BadFrame) { F.decode(%({"type":"set_model","role":123,"model":"a/b"})) }
    assert_raises(F::BadFrame) { F.decode(%({"type":"set_model","role":"main","model":null})) }
    assert_raises(F::BadFrame) { F.decode(%({"type":"inject","text":["hi"]})) }
    assert_raises(F::BadFrame) { F.decode(%({"type":"inject","text":"hi","wake":"yes"})) }
    assert_raises(F::BadFrame) { F.decode(%({"type":"approve","call_id":7})) }
    assert_raises(F::BadFrame) { F.decode(%({"type":"cancel","reason":42})) }
  end

  def test_rejects_non_string_input_and_invalid_utf8_values
    assert_raises(F::BadFrame) { F.decode(nil) }
    assert_raises(F::BadFrame) { F.decode(42) }
    assert_raises(F::BadFrame) { F.decode(%({"type":"inject","text":"\xFF\xFE"})) }
  end

  def test_rejects_a_frame_over_the_size_limit
    huge = %({"type":"inject","text":"#{"x" * (1 << 20)}"})
    assert_raises(F::BadFrame) { F.decode(huge) }
  end

  def test_serializes_the_event_envelope_as_is
    ev = Struct.new(:id, :session_id, :seq, :at, :type, :payload)
             .new("e1", "s1", 4, Time.utc(2026, 8, 18, 4, 10, 11, 123_456), "user/message", { text: "hi" })
    h = JSON.parse(F.event(ev), symbolize_names: true)
    assert_equal({ id: "e1", session_id: "s1", seq: 4,
                   at: "2026-08-18T04:10:11.123456Z",
                   type: "user/message", payload: { text: "hi" } }, h)
  end

  def test_hello_and_error_frames
    assert_equal({ type: "hello", proto: 1, session_id: "s1", last_seq: 7 },
                 JSON.parse(F.hello(session_id: "s1", last_seq: 7), symbolize_names: true))
    assert_equal({ type: "error", code: "lagged" },
                 JSON.parse(F.error(code: "lagged"), symbolize_names: true))
    assert_equal({ type: "error", code: "bad_frame", message: "why" },
                 JSON.parse(F.error(code: "bad_frame", message: "why"), symbolize_names: true))
  end
end
