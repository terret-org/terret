# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret/tools_std"

class TaskToolTest < Minitest::Test
  def boot(script:, extra_rows: [])
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions",  plugin: Terret::Sessions },
      { id: "prompt",    plugin: Terret::Prompt },
      { id: "tools",     plugin: Terret::Tools::Registry },
      { id: "llm",       plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop",      plugin: Terret::Loop },
      { id: "subagents", plugin: Terret::Subagents },
      { id: "std_task",  plugin: Terret::ToolsStd::Task },
      *extra_rows
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))
    [ctx, loader]
  end

  def spawn(ctx, id: "parent")
    session = ctx[:sessions].create
    [ctx[:loop].spawn_agent(session_id: session.id, id: id), session]
  end

  # Task is root-mounted like the rest of the roster, so a call reaches it the
  # way the loop's own pipeline delivers one: through the registry, dispatched
  # on the CALLING agent's fork, carrying that agent's session.
  def call(ctx, agent, session_id, **args)
    ctx[:tools].execute(
      Terret::Tools::Call.new(id: "t1", name: "Task", args: args, session_id: session_id),
      ctx: agent.ctx
    )
  end

  def test_task_registers_with_the_declared_metadata
    ctx, = boot(script: [])
    d = ctx[:tools].fetch("Task")

    refute d.mutating, "the call itself starts a conversation; the child's own effects are gated"
    assert_equal :never, d.approval
    assert_equal :parallel, d.concurrency
  end

  def test_both_parameters_are_required_in_the_schema
    ctx, = boot(script: [])
    params = ctx[:tools].fetch("Task").params

    assert_equal %w[description prompt].sort, Array(params[:required]).map(&:to_s).sort
    assert_equal "string", params.dig(:properties, :description, :type)
    assert_equal "string", params.dig(:properties, :prompt, :type)
  end

  def test_the_result_is_the_childs_final_message_plus_a_ledger_naming_the_child_session
    ctx, = boot(script: [{ text: "the child's answer" }])
    parent, session = spawn(ctx)

    result = call(ctx, parent, session.id, description: "answer it", prompt: "what is it?")

    assert_nil result.error
    child_id = result.content[/child session (\S+)\z/, 1]
    refute_nil child_id, "the ledger line must name the child session"
    refute_equal session.id, child_id
    assert_equal "the child's answer\n--- terret ---\nchild session #{child_id}", result.content
    # The id is a real pointer: the whole story is in that log.
    assert_equal "the child's answer", ctx[:sessions].derive_messages(child_id).last.text
  end

  # Everything the child does passes the CHILD's pipeline. A denial there is
  # an ordinary tool result inside the child's turn, not an error the parent's
  # Task call fails with.
  def test_a_denied_tool_inside_the_child_surfaces_in_the_childs_result
    danger = Terret::LLM::ToolCall.new(id: "c1", name: "danger", args: {})
    ctx, = boot(script: [{ text: "Trying danger.", tool_calls: [danger] },
                         { text: "I could not run that." }])
    ran = false
    ctx.with_owner("root-tools") do
      ctx[:tools].register(name: "danger", description: "root's own", params: {}) { ran = true }
    end
    parent, session = spawn(ctx)
    Terret::Tools::AllowList.install(parent.ctx, ["Task"])

    result = call(ctx, parent, session.id, description: "poke it", prompt: "run danger")

    refute ran
    assert_nil result.error, "a denial inside the child is not a parent error"
    assert_match(/\AI could not run that\./, result.content)
    child_id = result.content[/child session (\S+)\z/, 1]
    child = ctx[:sessions].fetch(child_id)
    assert_equal "danger is not on the allow list",
                 child.events.find { |e| e.type == "tool/result" }.payload[:error]
  end

  # The handler's lookup is the load-bearing line in this tool, and the
  # session it looks up is injected by the registry — never model-supplied.
  def test_a_forged_session_id_argument_cannot_delegate_from_another_agents_context
    danger = Terret::LLM::ToolCall.new(id: "c1", name: "danger", args: {})
    ctx, = boot(script: [{ text: "Trying danger.", tool_calls: [danger] },
                         { text: "I could not run that." }])
    ran = false
    ctx.with_owner("root-tools") do
      ctx[:tools].register(name: "danger", description: "root's own", params: {}) { ran = true }
    end
    parent, session = spawn(ctx, id: "parent")
    permissive, permissive_session = spawn(ctx, id: "permissive")
    Terret::Tools::AllowList.install(parent.ctx, ["Task"])
    Terret::Tools::AllowList.install(permissive.ctx, %w[Task danger])

    result = call(ctx, parent, session.id,
                  description: "escalate", prompt: "run danger",
                  session_id: permissive_session.id)

    refute ran, "a session_id written into the arguments must lose to the call's own"
    child_id = result.content[/child session (\S+)\z/, 1]
    child = ctx[:sessions].fetch(child_id)
    assert_equal "danger is not on the allow list",
                 child.events.find { |e| e.type == "tool/result" }.payload[:error]
  end

  def test_a_call_from_a_session_with_no_live_agent_fails_closed
    ctx, = boot(script: [{ text: "never reached" }])
    parent, = spawn(ctx)
    orphan = ctx[:sessions].create

    result = call(ctx, parent, orphan.id, description: "d", prompt: "p")

    assert_nil result.content
    assert_match(/no live agent/, result.error)
  end
end
