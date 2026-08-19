# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret"

class TitlerTest < Minitest::Test
  def boot(script:, titler_role: true)
    Hames.reset_events!
    Terret.declare_events!

    roles = { main: "fake/scripted" }
    roles[:titler] = "fake/scripted" if titler_role
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service, config: { roles: roles } },
      { id: "loop",     plugin: Terret::Loop },
      { id: "titler",   plugin: Terret::Titler }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))
    [ctx, loader]
  end

  def spawn(ctx)
    session = ctx[:sessions].create
    [ctx[:loop].spawn_agent(session_id: session.id), session]
  end

  def test_the_first_turn_end_titles_the_session_through_the_role
    ctx, = boot(script: [{ text: "Sure, tacos it is." }, { text: "Taco night planning" }])
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "help me plan taco night")

    assert_equal "Taco night planning", ctx[:sessions].title(session.id)
    titled = session.events.select { |e| e.type == "session/titled" }
    assert_equal 1, titled.length
    # titles are metadata: projection-invisible
    refute_includes ctx[:sessions].derive_messages(session.id).map(&:text), "Taco night planning"
  end

  def test_titling_happens_once
    ctx, = boot(script: [{ text: "r1" }, { text: "The Title" }, { text: "r2" }])
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "one")
    ctx[:loop].run_turn(agent, "two") # consumes "r2"; no second title call

    assert_equal 1, session.events.count { |e| e.type == "session/titled" }
    assert_equal "The Title", ctx[:sessions].title(session.id)
  end

  def test_without_a_titler_role_the_first_user_line_is_the_title
    ctx, = boot(script: [{ text: "ok" }], titler_role: false)
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "a very long request about the state of the world and everything else")

    # 40 chars, then title!'s strip: "…state of t"
    assert_equal "a very long request about the state of t", ctx[:sessions].title(session.id)
  end

  def test_title_reader_returns_nil_untitled
    ctx, = boot(script: [])
    session = ctx[:sessions].create
    assert_nil ctx[:sessions].title(session.id)
  end
end
