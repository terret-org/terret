# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret"

module SubagentsHarness
  def boot(script:, extra_rows: [], loop_config: {})
    Hames.reset_events!
    Terret.declare_events!

    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop",     plugin: Terret::Loop, config: loop_config },
      { id: "subagents", plugin: Terret::Subagents },
      *extra_rows
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))
    [ctx, loader]
  end

  # A caller of the seam is always an agent, so every test spawns one and
  # hands `run` that agent's fork — never the root.
  def spawn(ctx, id: "parent")
    session = ctx[:sessions].create
    [ctx[:loop].spawn_agent(session_id: session.id, id: id), session]
  end
end

class SubagentSeamTest < Minitest::Test
  include SubagentsHarness

  def test_run_spawns_a_child_completes_a_turn_and_returns_text_session_and_usage
    ctx, = boot(script: [{ text: "the answer is 42",
                           usage: { prompt_tokens: 9, completion_tokens: 4, cost: 0.002 } }])
    parent, parent_session = spawn(ctx)

    result = ctx[:subagents].run(prompt: "what is the answer?", ctx: parent.ctx)

    assert_equal "the answer is 42", result.text
    refute_equal parent_session.id, result.session_id
    assert_equal({ prompt_tokens: 9, completion_tokens: 4, cost: 0.002, steps: 1 }, result.usage)

    # A fresh session, not a fork of the parent's: the child sees the prompt
    # it was given and nothing else (docs/subagents.md §2).
    child = ctx[:sessions].fetch(result.session_id)
    chunkless = child.events.map(&:type).reject { |t| t == "assistant/chunk" }
    assert_equal %w[session/created turn/start step/start user/message
                    assistant/message step/end turn/end], chunkless
    assert_equal "what is the answer?",
                 child.events.find { |e| e.type == "user/message" }.payload[:text]
    assert_nil child.parent_id

    # The parent's log gains no new durable event; the only thread from a
    # parent transcript to a child's is the tool result the Task tool renders.
    assert_equal %w[session/created], parent_session.events.map(&:type)
    assert_nil ctx[:loop].agent_for_session(result.session_id)
  end

  def test_the_child_agent_is_disposed_after_run_even_when_the_turn_raises
    ctx, = boot(script: []) # an exhausted FakeAdapter script raises mid-turn
    parent, = spawn(ctx)
    disposed = []
    ctx.on("agent/disposed") { |sid| disposed << sid }

    err = assert_raises(Terret::Tools::Failure) do
      ctx[:subagents].run(prompt: "go", ctx: parent.ctx)
    end

    assert_equal 1, disposed.length, "the child must be disposed even when its turn raised"
    assert_nil ctx[:loop].agent_for_session(disposed.first)
    # The session id is the pointer to the whole story; the stack is not.
    assert_includes err.message, disposed.first
    refute_match(/loop\.rb|subagents\.rb/, err.message)
  end

  def test_the_child_sees_the_parents_roster_and_policy_floor
    alpha = Terret::LLM::ToolCall.new(id: "c1", name: "alpha", args: {})
    ctx, = boot(script: [{ text: "Calling alpha.", tool_calls: [alpha] },
                         { text: "alpha said hello" }])
    parent, = spawn(ctx)
    parent.ctx.with_owner("parent-tools") do
      ctx[:tools].register(name: "alpha", description: "the parent's own tool",
                           params: {}, ctx: parent.ctx) { "hello from alpha" }
    end
    Terret::Tools::AllowList.install(parent.ctx, ["alpha"])

    result = ctx[:subagents].run(prompt: "use alpha", ctx: parent.ctx)

    assert_equal "alpha said hello", result.text
    child = ctx[:sessions].fetch(result.session_id)
    assert_equal "hello from alpha",
                 child.events.find { |e| e.type == "tool/result" }.payload[:content]
  end

  # Deny-by-default carries down: a subagent is not an escalation path.
  def test_the_child_cannot_escape_the_parents_allow_list
    danger = Terret::LLM::ToolCall.new(id: "c1", name: "danger", args: {})
    ctx, = boot(script: [{ text: "Trying danger.", tool_calls: [danger] },
                         { text: "I was refused." }])
    ran = false
    ctx.with_owner("root-tools") do
      ctx[:tools].register(name: "danger", description: "root's own", params: {}) { ran = true }
    end
    parent, = spawn(ctx)
    Terret::Tools::AllowList.install(parent.ctx, ["alpha"])

    result = ctx[:subagents].run(prompt: "run danger", ctx: parent.ctx)

    refute ran, "a child must never reach a tool its parent's allow list denies"
    assert_equal "I was refused.", result.text
    child = ctx[:sessions].fetch(result.session_id)
    assert_equal "danger is not on the allow list",
                 child.events.find { |e| e.type == "tool/result" }.payload[:error]
  end

  # The roster is global by design (visibility is the AllowList's job), so what
  # is scoped to a fork is POLICY — and another agent's policy must never reach
  # this child, in either direction.
  def test_another_agents_policy_does_not_govern_the_child
    alpha = Terret::LLM::ToolCall.new(id: "c1", name: "alpha", args: {})
    ctx, = boot(script: [{ text: "Calling alpha.", tool_calls: [alpha] },
                         { text: "alpha said hello" }])
    ctx.with_owner("root-tools") do
      ctx[:tools].register(name: "alpha", description: "root's own", params: {}) { "hello from alpha" }
    end
    parent, = spawn(ctx, id: "parent")
    stranger, = spawn(ctx, id: "stranger")
    Terret::Tools::AllowList.install(stranger.ctx, ["nothing"])

    result = ctx[:subagents].run(prompt: "use alpha", ctx: parent.ctx)

    assert_equal "alpha said hello", result.text
    child = ctx[:sessions].fetch(result.session_id)
    assert_equal "hello from alpha",
                 child.events.find { |e| e.type == "tool/result" }.payload[:content]
  end

  # Sole provider: "what is a subagent in this deployment" is one answer for
  # the whole process, decided in a config row.
  def test_a_second_provider_registration_refuses
    err = assert_raises(Hames::ContractError) do
      boot(script: [], extra_rows: [{ id: "subagents_two", plugin: Terret::Subagents }])
    end
    assert_match(/subagents already registered/, err.message)
  end

  # A child holds a registry slot for the length of its run, so a fan-out of
  # Task calls is bounded by the same cap as the fleet.
  def test_run_refuses_when_the_agent_cap_is_reached
    ctx, = boot(script: [{ text: "never reached" }], loop_config: { max_agents: 1 })
    parent, = spawn(ctx)

    err = assert_raises(Terret::AgentCapExceeded) do
      ctx[:subagents].run(prompt: "go", ctx: parent.ctx)
    end
    assert_match(/max_agents/, err.message)
  end
end
