# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/terret"

module TerretTestHarness
  def boot(script:, extra_rows: [])
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
      *extra_rows
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))
    [ctx, loader]
  end

  def spawn(ctx)
    session = ctx[:sessions].create
    [ctx[:loop].spawn_agent(session_id: session.id), session]
  end
end

class TurnFlowTest < Minitest::Test
  include TerretTestHarness

  WEATHER_CALL = Terret::LLM::ToolCall.new(id: "tc1", name: "weather", args: { city: "CDMX" })

  def two_step_script
    [
      { text: "Checking the weather.", tool_calls: [WEATHER_CALL] },
      { text: "It is 22C in CDMX." }
    ]
  end

  def register_weather(ctx)
    ctx.with_owner("weather-plugin") do
      ctx[:tools].register(name: "weather", description: "Weather lookup",
                           params: { city: "string" }) { |city:| "22C in #{city}" }
    end
  end

  def test_golden_event_order_for_a_two_step_tool_turn
    ctx, = boot(script: two_step_script)
    register_weather(ctx)
    agent, session = spawn(ctx)

    status = ctx[:loop].run_turn(agent, "What's the weather in CDMX?")
    assert_equal :completed, status

    types = session.events.map(&:type)
    chunkless = types.reject { |t| t == "assistant/chunk" }
    assert_equal %w[
      session/created
      turn/start
      step/start user/message assistant/message
      tool/call tool/result step/end
      step/start assistant/message step/end
      turn/end
    ], chunkless

    # chunks precede their assistant/message and reassemble to the exact text
    first_msg = types.index("assistant/message")
    chunk_text = session.events.take(first_msg)
                        .select { |e| e.type == "assistant/chunk" }
                        .map { |e| e.payload[:text] }.join
    assert_equal "Checking the weather.", chunk_text
  end

  def test_derived_history_carries_the_tool_result_into_step_two
    ctx, = boot(script: two_step_script)
    register_weather(ctx)
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "Weather?")

    history = ctx[:sessions].derive_messages(session.id)
    roles = history.map(&:role)
    assert_equal %i[user assistant tool assistant], roles
    assert_equal "22C in CDMX", history[2].parts.first.content
  end

  def test_assistant_message_payloads_are_stored_as_primitives
    ctx, = boot(script: two_step_script)
    register_weather(ctx)
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "Weather?")

    parts = session.events.select { |e| e.type == "assistant/message" }
                   .flat_map { |e| e.payload[:parts] }
    assert(parts.all? { |p| p.is_a?(Hash) && p[:type].is_a?(String) })
    assert_equal parts, JSON.parse(JSON.generate(parts), symbolize_names: true)
  end

  def test_log_invariant_catches_a_side_channel
    ctx, = boot(script: [{ text: "hi" }])
    agent, = spawn(ctx)
    # A misbehaving middleware smuggles an unlogged message into the request:
    ctx.on("agent/request") do |req, next_|
      smuggled = Terret::LLM::Message.new(role: :user,
                                          parts: [Terret::LLM::Text.new(text: "secret")])
      next_.(req.with(messages: req.messages + [smuggled]))
    end
    assert_raises(Terret::LogInvariantViolation) { ctx[:loop].run_turn(agent, "hello") }
  end

  def test_a_failed_turn_still_closes_with_a_durable_turn_end
    ctx, = boot(script: [])
    agent, session = spawn(ctx)

    assert_raises(RuntimeError) { ctx[:loop].run_turn(agent, "hello") }

    assert_equal "turn/end", session.events.last.type
    assert_equal "failed", session.events.last.payload[:status]
    assert_equal :idle, agent.status
  end

  def test_pre_step_rejection_closes_a_durable_zero_step_turn
    ctx, = boot(script: [{ text: "unused" }])
    agent, session = spawn(ctx)
    ctx.on("agent/pre_step") { |_claim, _next_| Terret::Claim.reject(reason: "budget") }

    status = ctx[:loop].run_turn(agent, "hello")
    assert_equal :rejected, status
    assert_equal %w[session/created turn/start turn/end], session.events.map(&:type)
    assert_equal "rejected", session.events.last.payload[:status]
  end

  def test_tools_pre_execute_veto_short_circuits_to_an_error_result
    ctx, = boot(script: two_step_script)
    register_weather(ctx)
    ctx.on("tools/pre_execute") do |call, next_|
      call.name == "weather" ? Terret::Tools::Veto.new(reason: "policy: denied") : next_.(call)
    end
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "Weather?")

    result = session.events.find { |e| e.type == "tool/result" }
    assert_equal "policy: denied", result.payload[:error]
    assert_nil result.payload[:content]
  end

  def test_tools_execute_provider_replacement_swaps_the_execution_world
    ctx, = boot(script: two_step_script)
    register_weather(ctx)
    # a "remote sandbox" replaces execution wholesale — no tool forks
    ctx.on("tools/execute") do |call, _next_|
      Terret::Tools::Result.new(id: call.id, content: "REMOTE:#{call.args[:city]}", error: nil)
    end
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "Weather?")

    result = session.events.find { |e| e.type == "tool/result" }
    assert_equal "REMOTE:CDMX", result.payload[:content]
  end

  def test_unloading_a_plugin_removes_its_tool_from_schemas
    ctx, loader = boot(script: [{ text: "hi" }],
                       extra_rows: [{ id: "weather-plugin", plugin: WeatherPlugin }])
    assert_includes ctx[:tools].schemas.map { |s| s[:name] }, "weather"
    loader.unload!("weather-plugin")
    refute_includes ctx[:tools].schemas.map { |s| s[:name] }, "weather"
  end

  def test_steers_log_as_context_injected_and_input_as_user_message
    ctx, = boot(script: [{ text: "ok" }])
    agent, session = spawn(ctx)
    agent.inject("remember the tone")

    ctx[:loop].run_turn(agent, "hello")

    typed = session.events.filter_map do |e|
      [e.type, e.payload[:text]] if %w[user/message context/injected].include?(e.type)
    end
    assert_equal [["user/message", "hello"], ["context/injected", "remember the tone"]], typed
  end

  def test_injected_context_rides_along_with_the_waking_message
    ctx, = boot(script: [{ text: "noted" }])
    agent, session = spawn(ctx)
    agent.inject("FYI: user prefers metric units")
    ctx[:loop].run_turn(agent, "hello")

    assert_equal ["hello"],
                 session.events.select { |e| e.type == "user/message" }.map { |e| e.payload[:text] }
    assert_equal ["FYI: user prefers metric units"],
                 session.events.select { |e| e.type == "context/injected" }.map { |e| e.payload[:text] }
  end

  def test_a_mid_turn_inject_lands_in_the_next_step
    ctx, = boot(script: two_step_script)
    agent = nil
    ctx.with_owner("steering-tool") do
      ctx[:tools].register(name: "weather", description: "Weather lookup",
                           params: { city: "string" }) do |city:|
        agent.inject("actually, celsius please")
        "22C in #{city}"
      end
    end
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)

    assert_equal :completed, ctx[:loop].run_turn(agent, "What's the weather in CDMX?")

    chunkless = session.events.map(&:type).reject { |t| t == "assistant/chunk" }
    assert_equal %w[
      session/created
      turn/start
      step/start user/message assistant/message
      tool/call tool/result step/end
      step/start context/injected assistant/message step/end
      turn/end
    ], chunkless

    steer = session.events.select { |e| e.type == "context/injected" }.last
    assert_equal "actually, celsius please", steer.payload[:text]
    assert agent.inbox_empty?
  end

  def test_cancel_during_a_tool_records_the_result_then_closes_the_turn
    ctx, = boot(script: two_step_script)
    agent = nil
    ctx.with_owner("cancelling-tool") do
      ctx[:tools].register(name: "weather", description: "Weather lookup",
                           params: { city: "string" }) do |city:|
        agent.cancel("user hit stop") # deterministic stand-in for a racing cancel frame
        "22C in #{city}"
      end
    end
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)

    assert_equal :cancelled, ctx[:loop].run_turn(agent, "What's the weather in CDMX?")

    chunkless = session.events.map(&:type).reject { |t| t == "assistant/chunk" }
    assert_equal %w[
      session/created
      turn/start
      step/start user/message assistant/message
      tool/call tool/result step/end
      turn/end
    ], chunkless

    turn_end = session.events.last
    assert_equal "cancelled", turn_end.payload[:status]
    assert_equal "user hit stop", turn_end.payload[:reason]
    assert_equal :idle, agent.status
    refute agent.cancelled? # the flag does not leak into the next turn
  end

  def test_cancel_set_before_the_turn_closes_it_with_no_step
    ctx, = boot(script: [{ text: "hi" }])
    agent, session = spawn(ctx)
    agent.cancel(nil)

    assert_equal :cancelled, ctx[:loop].run_turn(agent, "hello?")
    assert_equal %w[session/created turn/start turn/end], session.events.map(&:type)
    assert_nil session.events.last.payload[:reason]
  end

  def test_a_cancelled_turn_leaves_queued_steers_for_the_next_turn
    ctx, = boot(script: [{ text: "hi" }])
    agent, = spawn(ctx)
    agent.cancel(nil)
    agent.inject("still relevant later")

    assert_equal :cancelled, ctx[:loop].run_turn(agent, "hello?")
    refute agent.inbox_empty?, "a cancelled turn must not consume the inbox"
  end

  def test_run_turn_refuses_a_concurrent_call_on_a_running_agent
    ctx, = boot(script: [{ text: "hi" }])
    agent, = spawn(ctx)
    agent.status = :running

    assert_raises(Terret::TurnAlreadyRunning) { ctx[:loop].run_turn(agent, "hello") }
  end

  def test_a_pre_step_exception_requeues_the_drained_steer_and_unwedges_the_agent
    ctx, = boot(script: [{ text: "hi" }])
    agent, session = spawn(ctx)
    agent.inject("don't lose me")
    ctx.on("agent/pre_step") { |_claim, _next_| raise "boom" }

    assert_raises(RuntimeError) { ctx[:loop].run_turn(agent, "hello") }

    refute agent.inbox_empty?, "the steer drained before the exception must be requeued"
    assert_equal :idle, agent.status
    assert_equal "turn/end", session.events.last.type
    assert_equal "failed", session.events.last.payload[:status]
  end

  def test_a_cancel_raised_from_pre_step_closes_a_final_no_tool_step_as_cancelled
    ctx, = boot(script: [{ text: "hi" }])
    agent, session = spawn(ctx)
    ctx.on("agent/pre_step") do |claim, next_|
      agent.cancel(nil)
      next_.(claim)
    end

    assert_equal :cancelled, ctx[:loop].run_turn(agent, "hello")

    chunkless = session.events.map(&:type).reject { |t| t == "assistant/chunk" }
    assert_equal %w[
      session/created
      turn/start
      step/start user/message assistant/message step/end
      turn/end
    ], chunkless
    assert_equal "cancelled", session.events.last.payload[:status]
  end

  def test_cancel_from_one_tool_handler_skips_execution_of_the_next_tool_in_the_same_step
    call_a = Terret::LLM::ToolCall.new(id: "tc-a", name: "tool_a", args: {})
    call_b = Terret::LLM::ToolCall.new(id: "tc-b", name: "tool_b", args: {})
    ctx, = boot(script: [{ text: "two tools", tool_calls: [call_a, call_b] }])
    agent = nil
    b_ran = false
    ctx.with_owner("two-tool-plugin") do
      ctx[:tools].register(name: "tool_a", description: "A", params: {}) do
        agent.cancel("stop")
        "a-result"
      end
      ctx[:tools].register(name: "tool_b", description: "B", params: {}) do
        b_ran = true
        "b-result"
      end
    end
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)

    assert_equal :cancelled, ctx[:loop].run_turn(agent, "go")

    refute b_ran, "tool B must never execute once cancel landed"
    results = session.events.select { |e| e.type == "tool/result" }
    assert_equal "a-result", results[0].payload[:content]
    assert_nil results[1].payload[:content]
    assert_equal "cancelled before execution", results[1].payload[:error]
  end

  def test_a_rejected_claim_requeues_the_drained_steer_for_the_next_turn
    ctx, = boot(script: [{ text: "ok" }])
    reject_once = true
    ctx.with_owner("budget-guard") do
      ctx.on("agent/pre_step") do |claim, next_|
        if reject_once
          reject_once = false
          Terret::Claim.reject(reason: "over budget")
        else
          next_.(claim)
        end
      end
    end
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    agent.inject("remember the umbrella")

    assert_equal :rejected, ctx[:loop].run_turn(agent, "weather?")
    refute agent.inbox_empty?, "a rejected claim must not eat the steer"

    assert_equal :completed, ctx[:loop].run_turn(agent, "second try")
    typed = session.events.filter_map do |e|
      [e.type, e.payload[:text]] if %w[user/message context/injected].include?(e.type)
    end
    assert_equal [["user/message", "second try"], ["context/injected", "remember the umbrella"]], typed
  end

  def test_usage_reported_by_the_adapter_lands_in_the_step_end_payload
    ctx, = boot(script: [{ text: "hi", usage: { prompt_tokens: 12, completion_tokens: 3, cost: 0.0001 } }])
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "hello")

    step_end = session.events.find { |e| e.type == "step/end" }
    assert_equal({ prompt_tokens: 12, completion_tokens: 3, cost: 0.0001 },
                 step_end.payload[:usage])
  end

  def test_step_end_payload_omits_usage_when_the_adapter_reports_none
    ctx, = boot(script: [{ text: "hi" }])
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "hello")

    step_end = session.events.find { |e| e.type == "step/end" }
    refute step_end.payload.key?(:usage)
  end

  def test_prompt_sections_render_in_priority_order_and_dispose
    ctx, = boot(script: [{ text: "hi" }])
    d = nil
    ctx.with_owner("style") do
      ctx[:prompt].register_section("tone", priority: 10) { "Be terse." }
      d = ctx[:prompt].register_section("zz", priority: 5) { "First." }
    end
    assert_equal "First.\n\nBe terse.", ctx[:prompt].render
    d.call
    assert_equal "Be terse.", ctx[:prompt].render
  end

  def test_spawned_agents_are_findable_by_id
    ctx, = boot(script: [{ text: "hi" }])
    agent, = spawn(ctx)

    assert_same agent, ctx[:loop].agent(agent.id)
    assert_nil ctx[:loop].agent("agent-nowhere")
  end

  def test_respawning_an_id_raises_instead_of_replacing_the_registry_entry
    ctx, = boot(script: [{ text: "hi" }])
    session = ctx[:sessions].create
    ctx[:loop].spawn_agent(session_id: session.id)
    assert_raises(Terret::AgentExists) { ctx[:loop].spawn_agent(session_id: session.id) }
  end

  def test_a_pre_execute_listener_on_the_agents_fork_fires_for_that_agent_only
    ctx, = boot(script: two_step_script)
    register_weather(ctx)
    session_a = ctx[:sessions].create
    session_b = ctx[:sessions].create
    agent_a = ctx[:loop].spawn_agent(session_id: session_a.id)
    agent_b = ctx[:loop].spawn_agent(session_id: session_b.id)

    agent_a.ctx.with_owner("policy-a") do
      agent_a.ctx.on("tools/pre_execute") do |call, _next_|
        Terret::Tools::Veto.new(reason: "agent A may not use tools")
      end
    end

    assert_equal :completed, ctx[:loop].run_turn(agent_a, "weather?")
    vetoed = session_a.events.find { |e| e.type == "tool/result" }
    assert_equal "agent A may not use tools", vetoed.payload[:error]

    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(two_step_script))
    assert_equal :completed, ctx[:loop].run_turn(agent_b, "weather?")
    fine = session_b.events.find { |e| e.type == "tool/result" }
    assert_equal "22C in CDMX", fine.payload[:content]
  end

  def test_execute_refuses_to_run_without_a_context
    ctx, = boot(script: [{ text: "hi" }])
    register_weather(ctx)
    assert_raises(ArgumentError) do
      ctx[:tools].execute(Terret::Tools::Call.new(id: "t", name: "weather", args: {}, session_id: "s"))
    end
  end

  def test_the_allow_list_denies_unlisted_tools_and_globs_namespaces
    ctx, = boot(script: two_step_script)
    register_weather(ctx)
    agent, session = spawn(ctx)
    Terret::Tools::AllowList.install(agent.ctx, ["mcp__nexus__*"])

    assert_equal :completed, ctx[:loop].run_turn(agent, "weather?")
    denied = session.events.find { |e| e.type == "tool/result" }
    assert_equal "weather is not on the allow list", denied.payload[:error]
  end

  def test_the_allow_list_admits_matching_tools_and_is_reversible
    ctx, = boot(script: two_step_script)
    register_weather(ctx)
    agent, session = spawn(ctx)
    disposer = Terret::Tools::AllowList.install(agent.ctx, %w[weather])

    assert_equal :completed, ctx[:loop].run_turn(agent, "weather?")
    fine = session.events.find { |e| e.type == "tool/result" }
    assert_equal "22C in CDMX", fine.payload[:content]

    disposer.call # removing the list removes the gate entirely
    assert_kind_of Proc, disposer
  end

  def test_the_allow_list_wildcard_is_load_bearing
    ctx, = boot(script: [{ text: "hi" }])
    ctx.with_owner("mcp-ish") do
      ctx[:tools].register(name: "mcp__nexus__search", description: "namespaced",
                           params: {}) { "found" }
    end
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    Terret::Tools::AllowList.install(agent.ctx, ["mcp__nexus__*"])

    result = ctx[:tools].execute(
      Terret::Tools::Call.new(id: "t", name: "mcp__nexus__search", args: {}, session_id: session.id),
      ctx: agent.ctx
    )
    assert_nil result.error, "a name matching only via the glob must be admitted"
    assert_equal "found", result.content
  end

  def test_handler_bugs_keep_their_class_and_domain_failures_do_not
    ctx, = boot(script: [{ text: "hi" }])
    ctx.with_owner("tools") do
      ctx[:tools].register(name: "buggy", description: "", params: {}) { raise "oops" }
      ctx[:tools].register(name: "doomed", description: "", params: {}) { raise Terret::Tools::Failure, "not today" }
    end
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)

    bug = ctx[:tools].execute(
      Terret::Tools::Call.new(id: "a", name: "buggy", args: {}, session_id: session.id), ctx: agent.ctx
    )
    assert_equal "RuntimeError: oops", bug.error

    domain = ctx[:tools].execute(
      Terret::Tools::Call.new(id: "b", name: "doomed", args: {}, session_id: session.id), ctx: agent.ctx
    )
    assert_equal "not today", domain.error
  end

  def test_calling_an_unknown_tool_is_an_error_result_not_a_failed_turn
    ctx, = boot(script: [
      { text: "Trying.", tool_calls: [Terret::LLM::ToolCall.new(id: "t1", name: "vanished", args: {})] },
      { text: "Recovered." }
    ])
    agent, session = spawn(ctx)

    assert_equal :completed, ctx[:loop].run_turn(agent, "go")
    result = session.events.find { |e| e.type == "tool/result" }
    assert_match(/\AKeyError: /, result.payload[:error])
  end

  class WeatherPlugin < Hames::Service
    inject :tools
    def start(ctx)
      ctx[:tools].register(name: "weather", description: "Weather", params: {}) { "sunny" }
    end
  end
end

class SessionForkTest < Minitest::Test
  include TerretTestHarness

  def test_fork_copies_events_to_boundary_and_records_lineage
    ctx, = boot(script: [{ text: "hello there" }])
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "hi")

    boundary = session.events.length - 2
    child = ctx[:sessions].fork(session.id, boundary: boundary)

    assert_equal boundary + 1, child.events.length
    assert_equal "session/forked", child.events.last.type
    assert_equal session.id, child.events.last.payload[:from]
    assert(child.events.take(boundary).all? { |e| e.session_id == child.id })
  end
end

class AgentLifecycleTest < Minitest::Test
  include TerretTestHarness

  def test_spawning_a_taken_id_raises_instead_of_silently_replacing
    ctx, = boot(script: [])
    s = ctx[:sessions].create
    ctx[:loop].spawn_agent(session_id: s.id)
    assert_raises(Terret::AgentExists) { ctx[:loop].spawn_agent(session_id: s.id) }
  end

  def test_one_live_agent_per_session
    ctx, = boot(script: [])
    s = ctx[:sessions].create
    ctx[:loop].spawn_agent(session_id: s.id, id: "a1")
    assert_raises(Terret::AgentExists) { ctx[:loop].spawn_agent(session_id: s.id, id: "a2") }
  end

  def test_agent_for_session_finds_the_live_agent
    ctx, = boot(script: [])
    s = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: s.id)
    assert_same agent, ctx[:loop].agent_for_session(s.id)
    assert_nil ctx[:loop].agent_for_session("nope")
  end

  def test_dispose_agent_disposes_the_fork_and_frees_both_slots
    ctx, = boot(script: [])
    s = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: s.id)
    fired = []
    agent.ctx.on("session/event") { |ev| fired << ev.type }

    ctx[:loop].dispose_agent(agent.id)
    ctx[:sessions].append(s.id, "user/message", { text: "after" })

    assert_empty fired, "a disposed agent's fork must not keep listening"
    assert_nil ctx[:loop].agent(agent.id)
    assert_nil ctx[:loop].agent_for_session(s.id)
    # the slot is genuinely free: respawning works
    ctx[:loop].spawn_agent(session_id: s.id)
  end

  def test_dispose_refuses_a_busy_agent
    ctx, = boot(script: [])
    s = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: s.id)
    agent.status = :running
    assert_raises(Terret::TurnAlreadyRunning) { ctx[:loop].dispose_agent(agent.id) }
    agent.status = :waiting_approval
    assert_raises(Terret::TurnAlreadyRunning) { ctx[:loop].dispose_agent(agent.id) }
  end

  def test_the_agent_cap_holds
    ctx2, = boot_with_cap(2)
    a = ctx2[:sessions].create
    b = ctx2[:sessions].create
    c = ctx2[:sessions].create
    ctx2[:loop].spawn_agent(session_id: a.id)
    ctx2[:loop].spawn_agent(session_id: b.id)
    err = assert_raises(Terret::AgentCapExceeded) { ctx2[:loop].spawn_agent(session_id: c.id) }
    assert_match(/max_agents/, err.message)
  end

  private

  def boot_with_cap(n)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop",     plugin: Terret::Loop, config: { max_agents: n } }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new([]))
    [ctx, loader]
  end
end

class ResumeTurnTest < Minitest::Test
  include TerretTestHarness

  DEPLOY_CALL = Terret::LLM::ToolCall.new(id: "tc9", name: "deploy", args: { env: "prod" })

  def register_deploy(ctx, approval: :always)
    ctx.with_owner("deploy-plugin") do
      ctx[:tools].register(name: "deploy", description: "Ship it",
                           params: { env: "string" }, mutating: true,
                           approval: approval) { |env:| "deployed to #{env}" }
    end
  end

  # What a kill -9 leaves behind: an open turn, an assistant message owing a
  # tool result, the call and the approval request logged, no resolution.
  def craft_dangling_log(ctx, session)
    sid = session.id
    sessions = ctx[:sessions]
    sessions.append(sid, "turn/start", { agent: "agent-#{sid}" })
    sessions.append(sid, "step/start", { n: 1 })
    sessions.append(sid, "user/message", { text: "ship it" })
    sessions.append(sid, "assistant/message",
                    { parts: [Terret::LLM.encode_part(Terret::LLM::Text.new(text: "Deploying.")),
                              Terret::LLM.encode_part(DEPLOY_CALL)] })
    sessions.append(sid, "tool/call", { id: "tc9", name: "deploy", args: { env: "prod" } })
    sessions.append(sid, "approval/requested", { call_id: "tc9", name: "deploy", args: { env: "prod" } })
  end

  def boot_with_approvals(script)
    boot(script: script, extra_rows: [{ id: "approvals", plugin: Terret::Tools::Approvals }])
  end

  def test_resumable_reads_the_open_turn_from_the_log
    ctx, = boot_with_approvals([])
    session = ctx[:sessions].create
    refute ctx[:loop].resumable?(session.id)
    craft_dangling_log(ctx, session)
    assert ctx[:loop].resumable?(session.id)
  end

  def test_resume_with_a_recorded_approval_completes_the_turn
    # the model owes one more step after the tool result: script has one entry
    ctx, = boot_with_approvals([{ text: "Deployed." }])
    register_deploy(ctx)
    session = ctx[:sessions].create
    craft_dangling_log(ctx, session)
    ctx[:sessions].append(session.id, "approval/resolved", { call_id: "tc9", verdict: "approved" })
    agent = ctx[:loop].spawn_agent(session_id: session.id)

    assert_equal :completed, ctx[:loop].resume_turn(agent)

    types = session.events.map(&:type)
    assert_equal 1, types.count("turn/start"), "resume must not open a second turn"
    assert_equal 1, types.count("turn/end")
    result = session.events.find { |e| e.type == "tool/result" }
    assert_equal "deployed to prod", result.payload[:content]
    # the crashed step closes without usage (it died with the process)
    step_end = session.events.find { |e| e.type == "step/end" }
    assert_equal({ n: 1 }, step_end.payload)
    # and the turn continued: the scripted "Deployed." landed as step 2
    assert_equal "Deployed.",
                 Terret::LLM.decode_part(session.events.select { |e| e.type == "assistant/message" }
                                                       .last.payload[:parts].first).text
  end

  def test_resume_with_no_verdict_parks_again
    ctx, = boot_with_approvals([{ text: "Deployed." }])
    register_deploy(ctx)
    session = ctx[:sessions].create
    craft_dangling_log(ctx, session)
    agent = ctx[:loop].spawn_agent(session_id: session.id)

    t = Thread.new { ctx[:loop].resume_turn(agent) }
    deadline = Time.now + 5
    until agent.status == :waiting_approval
      raise "never re-parked" if Time.now > deadline

      sleep 0.005
    end
    # no SECOND approval/requested: the pending one still stands
    assert_equal 1, session.events.count { |e| e.type == "approval/requested" }

    ctx[:sessions].append(session.id, "approval/resolved", { call_id: "tc9", verdict: "approved" })
    assert_equal :completed, t.value
  end

  def test_resume_after_a_crash_before_the_model_replied_re_requests
    ctx, = boot_with_approvals([{ text: "Here you go." }])
    session = ctx[:sessions].create
    sid = session.id
    ctx[:sessions].append(sid, "turn/start", { agent: "agent-#{sid}" })
    ctx[:sessions].append(sid, "step/start", { n: 1 })
    ctx[:sessions].append(sid, "user/message", { text: "hello?" })
    agent = ctx[:loop].spawn_agent(session_id: sid)

    assert_equal :completed, ctx[:loop].resume_turn(agent)
    # the dead step/start stays unclosed; stepping continued at n=2
    assert_equal [1, 2], session.events.select { |e| e.type == "step/start" }.map { |e| e.payload[:n] }
  end

  def test_resume_refuses_when_nothing_is_open
    ctx, = boot_with_approvals([{ text: "hi" }])
    agent, = spawn(ctx)
    ctx[:loop].run_turn(agent, "hello")
    assert_raises(ArgumentError) { ctx[:loop].resume_turn(agent) }
  end

  # Turn 1 ends the moment its tool runs (the handler cancels), so the session's
  # last assistant message carries a tool call that turn already resolved. Turn 2
  # then dies with nothing but its turn/start on disk. Owed calls are the OPEN
  # turn's business only: read across the whole projection, a closed turn's
  # settled mutation would run a second time off one crash.
  def test_resume_never_reexecutes_a_previous_turns_resolved_calls
    ctx, = boot_with_approvals([{ text: "Deploying.", tool_calls: [DEPLOY_CALL] }])
    runs = 0
    agent = nil
    ctx.with_owner("deploy-plugin") do
      ctx[:tools].register(name: "deploy", description: "Ship it",
                           params: { env: "string" }, mutating: true) do |env:|
        runs += 1
        agent.cancel("user hit stop")
        "deployed to #{env}"
      end
    end
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)

    assert_equal :cancelled, ctx[:loop].run_turn(agent, "ship it")
    assert_equal 1, runs

    ctx[:sessions].append(session.id, "turn/start", { agent: agent.id }) # the crash
    status = ctx[:loop].resume_turn(agent)

    assert_equal 1, runs, "a call resolved inside a closed turn must never re-execute"
    assert_equal 1, session.events.count { |e| e.type == "tool/call" && e.payload[:id] == "tc9" }
    assert_equal 1, session.events.count { |e| e.type == "tool/result" }
    # nothing was owed and nothing new arrived: the crashed turn closes empty
    assert_equal :empty, status
    assert_equal "turn/end", session.events.last.type
  end

  def test_the_invariant_holds_across_a_resume
    ctx, = boot_with_approvals([{ text: "Deployed." }])
    register_deploy(ctx)
    session = ctx[:sessions].create
    craft_dangling_log(ctx, session)
    ctx[:sessions].append(session.id, "approval/resolved", { call_id: "tc9", verdict: "approved" })
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    ctx[:loop].resume_turn(agent) # assert_log_invariant! runs inside every step; no raise = held
    ctx[:sessions].assert_log_invariant!(session.id, ctx[:sessions].derive_messages(session.id))
  end
end
