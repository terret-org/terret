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
end
