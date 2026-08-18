# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret"

class CompactorTest < Minitest::Test
  def boot(script:, budget: nil, summarizer: Terret::RoleSummarizer)
    Hames.reset_events!
    Terret.declare_events!

    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service,
        config: { roles: { main: "fake/scripted", compactor: "fake/scripted" } } },
      { id: "loop",     plugin: Terret::Loop },
      { id: "summarizer", plugin: summarizer },
      { id: "compactor", plugin: Terret::Compactor, config: budget ? { budget: budget } : {} }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))
    [ctx, loader]
  end

  def spawn(ctx)
    session = ctx[:sessions].create
    [ctx[:loop].spawn_agent(session_id: session.id), session]
  end

  # A summarizer that declines every request (Morph-without-a-key shape).
  class DecliningSummarizer < Hames::Service
    service_key :summarizer
    def start(_ctx); end
    def summarize(_history) = nil
  end

  def test_compact_appends_the_boundary_event_with_the_contractual_upto_seq
    # script: one turn step, then the role summarizer's reply (same fake adapter)
    ctx, = boot(script: [{ text: "A long conversation." }, { text: "SUMMARY: we talked." }])
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "hello")

    compacted = ctx[:compactor].compact!(session.id)

    assert_equal "session/compacted", compacted.type
    assert_equal compacted.seq - 1, compacted.payload[:upto_seq],
                 "upto_seq must be the immediately preceding seq (plan §12 M6 note)"
    assert_equal "SUMMARY: we talked.", compacted.payload[:summary]
  end

  def test_the_projection_replaces_the_prefix_and_the_invariant_holds_after
    ctx, = boot(script: [{ text: "First reply." },
                         { text: "SUMMARY: greeted." },
                         { text: "Second reply." }])
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "hello")
    ctx[:compactor].compact!(session.id)

    derived = ctx[:sessions].derive_messages(session.id)
    assert_equal 1, derived.length
    assert_equal "SUMMARY: greeted.", derived.first.text

    # the next turn runs on the compacted projection; the loop asserts the
    # invariant on every request, so completing is the proof
    assert_equal :completed, ctx[:loop].run_turn(agent, "and now?")
    assert_equal ["SUMMARY: greeted.", "and now?", "Second reply."],
                 ctx[:sessions].derive_messages(session.id).map(&:text)
  end

  def test_the_budget_trigger_compacts_after_an_overweight_turn
    heavy = { prompt_tokens: 900, completion_tokens: 5, cost: 0.1 }
    light = { prompt_tokens: 10,  completion_tokens: 5, cost: 0.01 }
    ctx, = boot(script: [{ text: "small", usage: light },
                         { text: "big", usage: heavy },
                         { text: "SUMMARY: big talk." }],
                budget: 500)
    agent, session = spawn(ctx)

    ctx[:loop].run_turn(agent, "one")
    refute session.events.map(&:type).include?("session/compacted"), "light turn must not compact"

    ctx[:loop].run_turn(agent, "two")
    compacted = session.events.select { |e| e.type == "session/compacted" }
    assert_equal 1, compacted.length
    assert_equal compacted.first.seq - 1, compacted.first.payload[:upto_seq]
  end

  def test_the_budget_hot_reloads
    heavy = { prompt_tokens: 900, completion_tokens: 5, cost: 0.1 }
    ctx, loader = boot(script: [{ text: "big", usage: heavy },
                                { text: "big again", usage: heavy },
                                { text: "SUMMARY: later." }])
    agent, session = spawn(ctx)

    ctx[:loop].run_turn(agent, "one") # no budget configured: never compacts
    refute session.events.map(&:type).include?("session/compacted")

    loader.reconfigure!("compactor", { budget: 500 })
    ctx[:loop].run_turn(agent, "two")
    assert session.events.map(&:type).include?("session/compacted"),
           "a hot-set budget must arm the trigger without a remount"
  end

  def test_the_latest_compaction_supersedes_earlier_ones
    ctx, = boot(script: [{ text: "r1" }, { text: "S1" }, { text: "r2" }, { text: "S2" }])
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "a")
    ctx[:compactor].compact!(session.id)
    ctx[:loop].run_turn(agent, "b")
    ctx[:compactor].compact!(session.id)

    assert_equal ["S2"], ctx[:sessions].derive_messages(session.id).map(&:text)
  end

  def test_a_declining_summarizer_skips_the_boundary_and_the_turn_survives
    heavy = { prompt_tokens: 900, completion_tokens: 5, cost: 0.1 }
    ctx, = boot(script: [{ text: "big", usage: heavy }],
                budget: 500, summarizer: DecliningSummarizer)
    agent, session = spawn(ctx)

    assert_equal :completed, ctx[:loop].run_turn(agent, "hello")
    assert session.events.map(&:type).include?("turn/end")
    refute session.events.map(&:type).include?("session/compacted")
    assert_nil ctx[:compactor].compact!(session.id), "manual compact! reports the decline as nil"
  end

  def test_compacting_an_empty_session_refuses
    ctx, = boot(script: [])
    session = ctx[:sessions].create
    assert_raises(ArgumentError) { ctx[:compactor].compact!(session.id) }
  end

  def test_a_raising_summarizer_is_isolated_by_the_trigger
    # No :compactor role on the adapter map -> RoleSummarizer's resolve raises
    # KeyError inside the trigger listener; Task 2's emit isolation keeps the
    # turn/end append (and the turn) alive. Manual compact! raises through.
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop",     plugin: Terret::Loop },
      { id: "summarizer", plugin: Terret::RoleSummarizer },
      { id: "compactor", plugin: Terret::Compactor, config: { budget: 1 } }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(
      [{ text: "hi", usage: { prompt_tokens: 10, completion_tokens: 1, cost: 0.0 } }]
    ))
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)

    assert_equal :completed, ctx[:loop].run_turn(agent, "hello")
    assert session.events.map(&:type).include?("turn/end")
    refute session.events.map(&:type).include?("session/compacted")
    assert_raises(KeyError) { ctx[:compactor].compact!(session.id) }
  end
end
