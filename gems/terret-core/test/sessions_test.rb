# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/terret"

class SessionsPrimitivesTest < Minitest::Test
  class ExplodingStore < Terret::Store::Memory
    def append(event)
      raise IOError, "disk full" if event.payload[:text] == "boom"

      super
    end
  end

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

  def test_invalid_utf8_raises_non_primitive_payload_at_the_boundary
    ctx = sessions_ctx
    s = ctx[:sessions].create
    junk = "ok \xFF\xFE not utf8".dup.force_encoding(Encoding::UTF_8)
    err = assert_raises(Terret::NonPrimitivePayload) do
      ctx[:sessions].append(s.id, "user/message", { text: junk })
    end
    assert_match(/UTF-8/, err.message)
  end

  def test_binary_strings_raise_and_name_their_encoding
    ctx = sessions_ctx
    s = ctx[:sessions].create
    blob = [0xDE, 0xAD].pack("C*") # ASCII-8BIT with high bytes
    err = assert_raises(Terret::NonPrimitivePayload) do
      ctx[:sessions].append(s.id, "user/message", { text: blob })
    end
    assert_match(/ASCII-8BIT/, err.message)
  end

  def test_convertible_encodings_convert_and_store_as_utf8
    ctx = sessions_ctx
    s = ctx[:sessions].create
    latin = "caf\xE9".dup.force_encoding(Encoding::ISO_8859_1)
    ev = ctx[:sessions].append(s.id, "user/message", { text: latin })
    assert_equal "café", ev.payload[:text]
    assert_equal Encoding::UTF_8, ev.payload[:text].encoding
  end

  def boot_with_store(store)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: store },
      { id: "sessions", plugin: Terret::Sessions }
    ])
    loader.boot!
  end

  def test_resume_rebuilds_a_session_from_the_store_and_continues_appending
    store = Terret::Store::Memory.new
    ctx1 = boot_with_store(store)
    s = ctx1[:sessions].create
    ctx1[:sessions].append(s.id, "user/message", { text: "hello" })

    ctx2 = boot_with_store(store) # same provider instance = same durable state
    resumed = ctx2[:sessions].resume(s.id)
    assert_equal s.events, resumed.events

    n = resumed.events.length
    ev = ctx2[:sessions].append(s.id, "user/message", { text: "again" })
    assert_equal n, ev.seq
  end

  def test_resume_is_idempotent_and_unknown_sessions_raise
    store = Terret::Store::Memory.new
    ctx = boot_with_store(store)
    s = ctx[:sessions].create
    assert_same ctx[:sessions].resume(s.id), ctx[:sessions].resume(s.id)
    assert_raises(KeyError) { ctx[:sessions].resume("nope") }
  end

  def test_replay_from_seq_equals_a_live_tail_from_that_point
    ctx = sessions_ctx
    sessions = ctx[:sessions]
    s = sessions.create
    3.times { |i| sessions.append(s.id, "user/message", { text: "before #{i}" }) }

    from = s.events.length
    tail = []
    ctx.on("session/event") { |ev| tail << ev if ev.session_id == s.id }
    3.times { |i| sessions.append(s.id, "user/message", { text: "after #{i}" }) }

    assert_equal tail, sessions.read(s.id, from_seq: from)
  end

  def test_fork_lineage_survives_resume
    store = Terret::Store::Memory.new
    ctx1 = boot_with_store(store)
    s = ctx1[:sessions].create
    ctx1[:sessions].append(s.id, "user/message", { text: "hello" })
    child = ctx1[:sessions].fork(s.id)

    ctx2 = boot_with_store(store)
    resumed = ctx2[:sessions].resume(child.id)
    assert_equal s.id, resumed.parent_id
    assert_equal child.events, resumed.events
  end

  def test_a_failed_store_append_leaves_no_phantom_event_in_memory
    store = ExplodingStore.new
    ctx = boot_with_store(store)
    s = ctx[:sessions].create
    ctx[:sessions].append(s.id, "user/message", { text: "ok" })

    emitted = []
    ctx.on("session/event") { |ev| emitted << ev }
    assert_raises(IOError) { ctx[:sessions].append(s.id, "user/message", { text: "boom" }) }

    assert_equal 2, s.events.length # session/created + "ok" only, no phantom
    assert_empty emitted # nothing model-visible happened
    assert_equal s.events, ctx[:sessions].read(s.id) # cache == store
  end

  def test_compaction_replaces_prior_history_in_the_projection
    ctx = sessions_ctx
    sessions = ctx[:sessions]
    s = sessions.create
    sessions.append(s.id, "user/message", { text: "old one" })
    sessions.append(s.id, "user/message", { text: "old two" })
    boundary = s.events.last.seq
    sessions.append(s.id, "session/compacted", { upto_seq: boundary, summary: "SUMMARY" })
    sessions.append(s.id, "user/message", { text: "fresh" })

    assert_equal %w[SUMMARY fresh], sessions.derive_messages(s.id).map(&:text)
  end

  def test_the_latest_compaction_wins
    ctx = sessions_ctx
    sessions = ctx[:sessions]
    s = sessions.create
    sessions.append(s.id, "user/message", { text: "ancient" })
    sessions.append(s.id, "session/compacted", { upto_seq: 1, summary: "FIRST" })
    sessions.append(s.id, "user/message", { text: "middle" })
    sessions.append(s.id, "session/compacted", { upto_seq: 3, summary: "SECOND" })
    sessions.append(s.id, "user/message", { text: "fresh" })

    assert_equal %w[SECOND fresh], sessions.derive_messages(s.id).map(&:text)
  end
end

class SessionsUsageTest < Minitest::Test
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

  def test_usage_sums_every_step_end_over_the_log
    sessions = sessions_ctx[:sessions]
    s = sessions.create
    sessions.append(s.id, "step/end", { n: 1, usage: { prompt_tokens: 10, completion_tokens: 5, cost: 0.01 } })
    sessions.append(s.id, "step/end", { n: 2 }) # provider sent no usage
    sessions.append(s.id, "step/end", { n: 3, usage: { prompt_tokens: 40, completion_tokens: 2, cost: 0.005 } })

    assert_equal({ prompt_tokens: 50, completion_tokens: 7, cost: 0.015, steps: 3 },
                 sessions.usage(s.id))
  end

  def test_usage_of_a_fresh_session_is_zero
    sessions = sessions_ctx[:sessions]
    s = sessions.create
    assert_equal({ prompt_tokens: 0, completion_tokens: 0, cost: 0.0, steps: 0 },
                 sessions.usage(s.id))
  end
end

class ApprovalEventsTest < Minitest::Test
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

  def test_approval_events_are_durable_and_invisible_to_the_projection
    sessions = sessions_ctx[:sessions]
    s = sessions.create
    sessions.append(s.id, "approval/requested", { call_id: "tc1", name: "bash" })
    sessions.append(s.id, "approval/resolved",  { call_id: "tc1", verdict: "denied", reason: "nope" })

    types = sessions.read(s.id).map(&:type)
    assert_equal %w[session/created approval/requested approval/resolved], types
    assert_equal [], sessions.derive_messages(s.id)
  end
end
