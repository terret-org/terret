# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/terret/acp/wire"

# The JSON-RPC 2.0 codec (docs/acp.md, "Framing"). Newline-delimited frames,
# not LSP Content-Length; a generated frame is one line with no embedded
# newline; a malformed line decodes to a parse error rather than raising.
class WireTest < Minitest::Test
  W = Terret::ACP::Wire

  def parse(frame) = JSON.parse(frame, symbolize_names: true)

  # -- encoding --------------------------------------------------------------

  def test_a_request_encodes_with_jsonrpc_id_method_and_params
    frame = W.request(id: 1, method: "session/prompt", params: { sessionId: "s1" })
    assert_equal({ jsonrpc: "2.0", id: 1, method: "session/prompt",
                   params: { sessionId: "s1" } }, parse(frame))
  end

  def test_a_request_omits_params_when_none_are_given
    assert_equal({ jsonrpc: "2.0", id: 2, method: "x" }, parse(W.request(id: 2, method: "x")))
  end

  def test_a_notification_has_a_method_and_no_id
    frame = W.notification(method: "session/update", params: { sessionId: "s1" })
    h = parse(frame)
    assert_equal "2.0", h[:jsonrpc]
    assert_equal "session/update", h[:method]
    refute h.key?(:id), "a notification carries no id"
  end

  def test_a_response_carries_its_result_under_the_request_id
    assert_equal({ jsonrpc: "2.0", id: 7, result: { stopReason: "end_turn" } },
                 parse(W.response(id: 7, result: { stopReason: "end_turn" })))
  end

  def test_an_error_object_carries_code_and_message
    frame = W.error(id: 9, code: -32601, message: "method not found")
    assert_equal({ jsonrpc: "2.0", id: 9,
                   error: { code: -32601, message: "method not found" } }, parse(frame))
  end

  def test_an_error_can_answer_a_null_id
    # A parse error cannot name the request that caused it (JSON-RPC 2.0 §5.1).
    assert_nil parse(W.error(id: nil, code: -32700, message: "parse error"))[:id]
  end

  # -- framing ---------------------------------------------------------------

  def test_frames_never_contain_an_embedded_newline
    # A newline in the payload would split one frame into two on this wire, so
    # the codec must escape it — JSON.generate does, and this pins it.
    frame = W.notification(method: "session/update",
                           params: { text: "line one\nline two", other: "a\r\nb" })
    refute_includes frame, "\n"
    assert_equal "line one\nline two", parse(frame)[:params][:text]
  end

  # -- decoding --------------------------------------------------------------

  def test_a_request_decodes_to_a_request_message
    msg = W.decode(W.request(id: 3, method: "initialize", params: { protocolVersion: 1 }))
    assert msg.request?
    assert_equal 3, msg.id
    assert_equal "initialize", msg.method
    assert_equal({ protocolVersion: 1 }, msg.params)
  end

  def test_a_notification_decodes_without_an_id
    msg = W.decode(W.notification(method: "session/cancel", params: { sessionId: "s1" }))
    assert msg.notification?
    refute msg.request?
    assert_nil msg.id
    assert_equal "session/cancel", msg.method
  end

  def test_a_malformed_line_decodes_to_a_parse_error_and_never_raises
    msg = W.decode("{not json")
    assert_equal :parse_error, msg.kind
    refute msg.request?
  end

  def test_a_json_value_that_is_not_an_object_is_an_invalid_request
    assert_equal :invalid, W.decode("[1,2,3]").kind
    assert_equal :invalid, W.decode("42").kind
  end

  def test_an_object_with_neither_method_nor_result_is_invalid
    assert_equal :invalid, W.decode(JSON.generate(jsonrpc: "2.0", id: 5)).kind
  end
end
