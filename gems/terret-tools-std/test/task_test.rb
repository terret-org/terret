# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret/tools_std"

# Task declares :parallel, and only a reactor can actually overlap a fan-out
# of them.
ASYNC_AVAILABLE = begin
  require "async"
  true
rescue LoadError
  false
end unless defined?(ASYNC_AVAILABLE)

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

  # `approval: :never` on Task is only honest because everything the child
  # does passes the child's own gate. What that gate cannot do is ask a human
  # about a session no human can see, so it refuses — and the refusal comes
  # back to the parent as an answer instead of hanging its turn forever.
  def test_an_approval_inside_a_child_comes_back_as_a_denial_rather_than_hanging
    write = Terret::LLM::ToolCall.new(id: "c1", name: "write_file", args: { path: "x" })
    ctx, = boot(script: [{ text: "Writing.", tool_calls: [write] },
                         { text: "I was not allowed to write it." }],
                extra_rows: [{ id: "approvals", plugin: Terret::Tools::Approvals }])
    ctx.with_owner("writer") do
      ctx[:tools].register(name: "write_file", description: "w", params: { path: "string" },
                           mutating: true, approval: :policy) { |path:| "wrote #{path}" }
    end
    parent, session = spawn(ctx)

    result = nil
    t = Thread.new do
      result = call(ctx, parent, session.id, description: "write it", prompt: "write the file")
    end
    joined = t.join(5)
    t.kill unless joined
    assert joined, "the parent's Task call never returned; the child parked"

    assert_nil result.error
    assert_match(/\AI was not allowed to write it\./, result.content)
    child_id = result.content[/child session (\S+)\z/, 1]
    child = ctx[:sessions].fetch(child_id)
    assert_equal "write_file denied: no approver can reach a subagent session",
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

  # "Nothing to say" and "was stopped" are different facts, and a model that
  # cannot tell them apart will summarize a cancelled delegation as an answer.
  def test_a_stopped_child_reads_differently_from_one_with_nothing_to_say
    stop = Terret::LLM::ToolCall.new(id: "c1", name: "stop_me", args: {})
    ctx, = boot(script: [{ text: "Working on it.", tool_calls: [stop] }])
    ctx.with_owner("stopper") do
      ctx[:tools].register(name: "stop_me", description: "s", params: {}) do |session_id:|
        ctx[:loop].agent_for_session(session_id).cancel("stopped from inside")
        "stopping"
      end
    end
    parent, session = spawn(ctx)

    result = call(ctx, parent, session.id, description: "stop it", prompt: "start then stop")

    child_id = result.content[/child session (\S+)$/, 1]
    assert_equal "Working on it.\n--- terret ---\nchild session #{child_id}\n" \
                 "the subagent's turn ended cancelled rather than completing",
                 result.content
    assert_equal "cancelled", ctx[:sessions].fetch(child_id).events.last.payload[:status]
  end

  def test_an_omitted_prompt_is_a_readable_result_rather_than_an_argument_error
    ctx, = boot(script: [])
    parent, session = spawn(ctx)

    result = call(ctx, parent, session.id, description: "forgot the prompt")

    assert_nil result.content
    assert_match(/needs a prompt/, result.error)
  end

  # Nothing forbids a child from delegating in turn; the agent cap is the only
  # ceiling, and a deployment that does not want this says so in its allow
  # list rather than here.
  def test_a_child_can_itself_delegate
    inner = Terret::LLM::ToolCall.new(id: "c1", name: "Task",
                                      args: { description: "ask again", prompt: "what is it?" })
    ctx, = boot(script: [{ text: "Delegating further.", tool_calls: [inner] },
                         { text: "the grandchild answer" },
                         { text: "my child said: the grandchild answer" }])
    parent, session = spawn(ctx)

    result = call(ctx, parent, session.id, description: "delegate", prompt: "go")

    assert_match(/\Amy child said: the grandchild answer/, result.content)
    child_id = result.content[/child session (\S+)$/, 1]
    child = ctx[:sessions].fetch(child_id)
    inner_result = child.events.find { |e| e.type == "tool/result" }.payload[:content]
    grandchild_id = inner_result[/child session (\S+)$/, 1]

    refute_nil grandchild_id
    assert_equal 3, [session.id, child_id, grandchild_id].uniq.length
    assert_equal "the grandchild answer",
                 ctx[:sessions].derive_messages(grandchild_id).last.text
    [child_id, grandchild_id].each do |sid|
      assert_nil ctx[:loop].agent_for_session(sid), "every child is disposed on its way out"
    end
  end

  # The reason Task declares :parallel at all: a fan-out of delegations is one
  # run under one barrier, and the results come back in call order.
  def test_two_task_calls_in_one_message_go_out_as_one_parallel_run
    skip "async is not installed" unless ASYNC_AVAILABLE

    a = Terret::LLM::ToolCall.new(id: "tc1", name: "Task",
                                  args: { description: "one", prompt: "first" })
    b = Terret::LLM::ToolCall.new(id: "tc2", name: "Task",
                                  args: { description: "two", prompt: "second" })
    ctx, = boot(script: [{ text: "Both at once.", tool_calls: [a, b] },
                         { text: "child one" }, { text: "child two" },
                         { text: "Both are back." }])
    parent, session = spawn(ctx)

    assert_equal :completed, Async { ctx[:loop].run_turn(parent, "go") }.wait

    results = session.events.select { |e| e.type == "tool/result" }
    assert_equal %w[tc1 tc2], results.map { |e| e.payload[:id] }
    assert_equal ["child one", "child two"],
                 results.map { |e| e.payload[:content].lines.first.chomp }.sort
    children = results.map { |e| e.payload[:content][/child session (\S+)$/, 1] }
    assert_equal 2, children.uniq.length, "each delegation gets its own session"
    children.each { |sid| assert_nil ctx[:loop].agent_for_session(sid) }
  end
end
