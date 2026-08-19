# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
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

  def test_registered_scrubbers_rewrite_every_string_at_the_append_boundary
    ctx = sessions_ctx
    s = ctx[:sessions].create
    ctx.with_owner("scrub") do
      ctx[:sessions].register_scrubber(->(str) { str.gsub("sk-secret123", "[REDACTED]") })
    end
    ev = ctx[:sessions].append(s.id, "user/message", { text: "key is sk-secret123 ok" })
    assert_equal "key is [REDACTED] ok", ev.payload[:text]
    # the projection sees the same bytes — the invariant holds by construction
    assert_equal "key is [REDACTED] ok",
                 ctx[:sessions].derive_messages(s.id).first.text
  end

  def test_scrubber_registration_is_a_reversible_effect
    ctx = sessions_ctx
    s = ctx[:sessions].create
    disposer = nil
    ctx.with_owner("scrub") do
      disposer = ctx[:sessions].register_scrubber(->(t) { t.gsub("x", "y") })
    end
    disposer.call
    ev = ctx[:sessions].append(s.id, "user/message", { text: "xx" })
    assert_equal "xx", ev.payload[:text]
  end

  def test_scrubbers_fold_in_registration_order
    ctx = sessions_ctx
    s = ctx[:sessions].create
    ctx.with_owner("scrub") do
      ctx[:sessions].register_scrubber(->(t) { t.gsub("one", "two") })
      ctx[:sessions].register_scrubber(->(t) { t.gsub("two", "three") })
    end
    ev = ctx[:sessions].append(s.id, "user/message", { text: "one" })
    assert_equal "three", ev.payload[:text]
  end

  # A deployment's patterns are written against secrets, not against the log's
  # own plumbing, and a generic one (long hex) matches both. Scrubbing an
  # identifier cannot protect anything — the harness minted it — and it can
  # destroy the log: collapsed tool call ids collide, and a provider rejects a
  # request carrying two calls with one id.
  HEX = ->(t) { t.gsub(/[a-f0-9]{6,}/, "[REDACTED]") }

  def scrubbing_ctx(scrubber = HEX)
    ctx = sessions_ctx
    ctx.with_owner("scrub") { ctx[:sessions].register_scrubber(scrubber) }
    ctx
  end

  def test_structural_identifiers_survive_while_content_beside_them_is_scrubbed
    ctx = scrubbing_ctx
    s = ctx[:sessions].create
    ev = ctx[:sessions].append(s.id, "tool/call",
                               { id: "abc123", name: "deploy", args: { token: "abc123" } })
    assert_equal "abc123", ev.payload[:id]
    assert_equal "deploy", ev.payload[:name]
    assert_equal "[REDACTED]", ev.payload[:args][:token]
  end

  def test_two_tool_calls_keep_distinct_ids_under_a_generic_pattern
    ctx = scrubbing_ctx
    s = ctx[:sessions].create
    ids = %w[abc123 def456].map do |id|
      ctx[:sessions].append(s.id, "tool/call", { id: id, name: "x", args: {} }).payload[:id]
    end
    assert_equal %w[abc123 def456], ids, "collapsed ids collide and a provider rejects the request"
  end

  # The encoded parts of an assistant message carry the same identifiers one
  # level down, and decode_part raises on a mangled tag.
  def test_encoded_parts_keep_their_tag_and_identifiers
    ctx = scrubbing_ctx
    s = ctx[:sessions].create
    part = Terret::LLM.encode_part(
      Terret::LLM::ToolCall.new(id: "abc123", name: "deploy", args: { token: "abc123" })
    )
    ev = ctx[:sessions].append(s.id, "assistant/message", { parts: [part] })
    stored = ev.payload[:parts].first
    assert_equal "tool_call", stored[:type]
    assert_equal "abc123", stored[:id]
    assert_equal "[REDACTED]", stored[:args][:token]
    assert_equal [Terret::LLM::ToolCall], ctx[:sessions].fetch(s.id).events.last
                 .payload[:parts].map { |p| Terret::LLM.decode_part(p).class }
  end

  # The exemption is positional, not by name: `args` and a Hash-valued
  # `content` are shaped by the tool author and the model, and `Write` really
  # does take an args[:content] holding a whole file.
  def test_model_supplied_keys_that_shadow_structural_names_are_still_scrubbed
    ctx = scrubbing_ctx
    s = ctx[:sessions].create
    ev = ctx[:sessions].append(s.id, "tool/call",
                               { id: "abc123", name: "Write",
                                 args: { name: "abc123", id: "abc123", content: "abc123" } })
    assert_equal "abc123", ev.payload[:id]
    assert_equal({ name: "[REDACTED]", id: "[REDACTED]", content: "[REDACTED]" }, ev.payload[:args])
  end

  def test_lineage_verdicts_and_policy_are_never_scrubbed
    ctx = scrubbing_ctx
    parent = ctx[:sessions].create(id: "abc123")
    child = ctx[:sessions].fork("abc123", child_id: "def456")
    assert_equal "abc123", child.events.last.payload[:from]
    assert_equal "abc123", ctx[:sessions].resume("def456").parent_id

    ctx[:sessions].append(parent.id, "approval/resolved",
                          { call_id: "abc123", verdict: "approved", reason: "abc123 looked fine" })
    resolved = parent.events.last.payload
    assert_equal "abc123", resolved[:call_id]
    assert_equal "approved", resolved[:verdict]
    assert_equal "[REDACTED] looked fine", resolved[:reason], "a human's words are content"

    ctx[:sessions].append(parent.id, "policy/updated", { patterns: ["abc123*"] })
    assert_equal ["abc123*"], parent.events.last.payload[:patterns],
                 "rewriting the allow list silently changes what the agent may run"
  end

  def test_symbol_values_are_scrubbed_and_stored_as_utf8
    ctx = scrubbing_ctx(->(t) { t.gsub("secret", "[REDACTED]") })
    s = ctx[:sessions].create
    ev = ctx[:sessions].append(s.id, "user/message", { text: :"a secret" })
    assert_equal "a [REDACTED]", ev.payload[:text]
    assert_equal Encoding::UTF_8, ev.payload[:text].encoding
  end

  def test_a_raising_scrubber_propagates_and_stores_nothing
    ctx = scrubbing_ctx(->(_t) { raise ArgumentError, "scrubber bug" })
    s = ctx[:sessions].create
    assert_raises(ArgumentError) { ctx[:sessions].append(s.id, "user/message", { text: "hi" }) }
    assert_equal %w[session/created], s.events.map(&:type)
    assert_equal s.events, ctx[:sessions].read(s.id)
  end

  # The same bleed Registry#register closed: a scrubber a forked agent scope
  # registers must not outlive that scope.
  def test_a_scrubber_can_be_scoped_to_a_forked_context
    ctx = sessions_ctx
    s = ctx[:sessions].create
    fork = ctx.fork
    fork.with_owner("agent") do
      ctx[:sessions].register_scrubber(->(t) { t.gsub("secret", "[REDACTED]") }, ctx: fork)
    end
    assert_equal "a [REDACTED]", ctx[:sessions].append(s.id, "user/message", { text: "a secret" })
                                                .payload[:text]
    fork.dispose!
    assert_equal "a secret", ctx[:sessions].append(s.id, "user/message", { text: "a secret" })
                                           .payload[:text]
  end

  # A scrubber is a plugin, not model data: it may crash loudly, and it must,
  # because the alternative is a poisoned payload landing in the store with
  # nothing left to blame.
  def test_a_scrubber_that_returns_a_non_string_raises_and_names_itself
    ctx = sessions_ctx
    s = ctx[:sessions].create
    ctx.with_owner("scrub") { ctx[:sessions].register_scrubber(->(_t) { nil }) }
    err = assert_raises(Terret::ScrubberContractViolation) do
      ctx[:sessions].append(s.id, "user/message", { text: "hello" })
    end
    assert_match(/NilClass/, err.message)
    assert_match(/sessions_test\.rb/, err.message, "the message must point at the scrubber")
  end

  def test_a_scrubber_that_returns_invalid_utf8_raises_before_anything_is_stored
    ctx = sessions_ctx
    s = ctx[:sessions].create
    ctx.with_owner("scrub") do
      ctx[:sessions].register_scrubber(->(_t) { "\xFF\xFE".dup.force_encoding(Encoding::UTF_8) })
    end
    assert_raises(Terret::ScrubberContractViolation) do
      ctx[:sessions].append(s.id, "user/message", { text: "hello" })
    end
    assert_equal %w[session/created], s.events.map(&:type)
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

class SessionsConcurrencyTest < Minitest::Test
  # JSONL's append opens and writes a file — a genuine yield point, both under
  # the fiber scheduler and between threads. Forcing the switch makes the race
  # deterministic instead of hoping the scheduler lands inside the window.
  class YieldingStore < Terret::Store::JSONL
    def append(event)
      Thread.pass
      super
    end
  end

  def boot(dir)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: YieldingStore, config: { dir: dir } },
      { id: "sessions", plugin: Terret::Sessions }
    ])
    loader.boot!
  end

  def test_concurrent_appenders_never_share_a_seq
    Dir.mktmpdir do |dir|
      sessions = boot(dir)[:sessions]
      s = sessions.create

      threads = 2.times.map do |t|
        Thread.new { 25.times { |i| sessions.append(s.id, "user/message", { text: "#{t}-#{i}" }) } }
      end
      threads.each(&:join)

      seqs = s.events.map(&:seq)
      assert_equal seqs.uniq.length, seqs.length, "two appenders took the same seq"
      assert_equal (0...seqs.length).to_a, seqs.sort
      assert_equal seqs, sessions.read(s.id).map(&:seq), "the store disagrees with memory"
    end
  end

  def test_an_append_from_a_listener_fans_out_after_the_event_it_reacted_to
    Dir.mktmpdir do |dir|
      ctx = boot(dir)
      sessions = ctx[:sessions]
      s = sessions.create

      # registered FIRST, so its nested append happens before the recorder
      # below ever sees the event that triggered it — the compactor and titler
      # both react to turn/end exactly like this
      ctx.on("session/event") do |ev|
        sessions.append(ev.session_id, "session/titled", { title: "derived" }) if ev.type == "turn/end"
      end
      order = []
      ctx.on("session/event") { |ev| order << [ev.seq, ev.type] }

      sessions.append(s.id, "turn/end", { status: "completed" })

      assert_equal order.sort_by(&:first), order, "fan-out overtook the log's own order"
      assert_equal [[1, "turn/end"], [2, "session/titled"]], order
    end
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
