# frozen_string_literal: true

# Behavioral contract every session store provider must satisfy. Include
# into a Minitest class that defines `build_store` returning a started
# provider instance.
module StoreContract
  def contract_event(session_id, seq, type: "user/message", payload: { text: "e#{seq}" })
    Terret::SessionEvent.new(
      id: "id-#{session_id}-#{seq}", session_id: session_id, seq: seq,
      at: Time.at(1_755_000_000 + seq, seq, :microsecond).utc, type: type, payload: payload
    )
  end

  def test_append_then_read_returns_events_in_order
    store = build_store
    3.times { |i| store.append(contract_event("s1", i)) }
    assert_equal [0, 1, 2], store.read("s1").map(&:seq)
    assert_equal %w[e0 e1 e2], store.read("s1").map { |e| e.payload[:text] }
  end

  def test_read_from_seq_replays_the_exact_tail
    store = build_store
    5.times { |i| store.append(contract_event("s1", i)) }
    assert_equal [3, 4], store.read("s1", from_seq: 3).map(&:seq)
  end

  def test_sessions_are_isolated_and_listed
    store = build_store
    store.append(contract_event("s1", 0))
    store.append(contract_event("s2", 0))
    assert_equal [], store.read("s3")
    assert_equal %w[s1 s2], store.session_ids.sort
  end

  def test_envelopes_round_trip_exactly
    store = build_store
    original = contract_event("s1", 0, type: "assistant/message",
                              payload: { parts: [{ type: "text", text: "héllo\nworld" }] })
    store.append(original)
    assert_equal original, store.read("s1").first
  end
end
