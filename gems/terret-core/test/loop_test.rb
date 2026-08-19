# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../lib/terret"

# The barrier is Async-native and terret-core depends on nothing: without a
# reactor a parallel run still completes as a group, just one call at a time.
# Proving that it OVERLAPS needs the reactor, so those tests need the gem.
ASYNC_AVAILABLE = begin
  require "async"
  true
rescue LoadError
  false
end unless defined?(ASYNC_AVAILABLE)

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

  # Cancellation is cooperative and honored at boundaries, so between the
  # request and the boundary there is a real interval where the agent is still
  # working and is no longer going to finish. Through M7 that interval was
  # indistinguishable from :running, which costs an operator real time.
  def test_a_cancel_mid_turn_says_the_agent_is_stopping
    ctx, = boot(script: two_step_script)
    agent = nil
    inside = nil
    ctx.with_owner("cancelling-tool") do
      ctx[:tools].register(name: "weather", description: "Weather lookup",
                           params: { city: "string" }) do |city:|
        agent.cancel("user hit stop")
        inside = agent.status
        "22C in #{city}"
      end
    end
    at_close = []
    ctx.on("agent/turn_stopping") do |a|
      at_close << a.status
      nil
    end
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)

    assert_equal :cancelled, ctx[:loop].run_turn(agent, "weather?")

    assert_equal :stopping, inside
    assert_equal [:stopping], at_close, "the window stays visible until the turn closes"
    assert_equal :idle, agent.status
    assert_equal "cancelled", session.events.last.payload[:status]
  end

  # :stopping is a sub-state of a running turn. A cancel with no turn to stop
  # leaves the agent idle — an idle agent that could not start a turn because
  # of a stale status would be wedged by it.
  def test_a_cancel_on_an_idle_agent_leaves_it_idle
    ctx, = boot(script: [{ text: "hi" }])
    agent, = spawn(ctx)

    agent.cancel("too soon")

    assert_equal :idle, agent.status
    assert_equal :cancelled, ctx[:loop].run_turn(agent, "hello?")
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

  # Disposal is the one signal root-mounted, session-keyed runtime state (a
  # shell's bash, a terminal's PTY) gets to reap what this agent opened — the
  # fork's own disposal never reaches it.
  def test_dispose_agent_emits_agent_disposed_with_the_session_id
    ctx, = boot(script: [])
    s = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: s.id)
    seen = []
    ctx.on("agent/disposed") { |sid| seen << sid }

    ctx[:loop].dispose_agent(agent.id)
    assert_equal [s.id], seen
  end

  # A raising fork disposer must not leak a cap slot: the registry entry is
  # freed in an ensure, so a disposal that blew up partway still returns the
  # slot it held. Without it a run of them exhausts max_agents while
  # Subagents#dispose only warns, and the child stays registered forever.
  def test_dispose_agent_frees_the_slot_even_when_a_fork_disposer_raises
    ctx, = boot(script: [])
    s = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: s.id)
    agent.ctx.effect { -> { raise "disposer boom" } }

    assert_raises(RuntimeError) { ctx[:loop].dispose_agent(agent.id) }
    assert_equal :done, agent.status
    assert_nil ctx[:loop].agent(agent.id), "the id slot must be freed despite the raise"
    assert_nil ctx[:loop].agent_for_session(s.id), "the session slot must be freed despite the raise"
    ctx[:loop].spawn_agent(session_id: s.id) # the slot is genuinely free
  end

  # The loop is a plugin, and its teardown has to take its agents with it: an
  # idle fork left mounted keeps its per-agent policy listeners and forked tool
  # registrations alive past the shutdown meant to end them. Boot.shutdown
  # unloads each row through loader.unload!, which calls this stop hook.
  def test_stop_disposes_every_agent_the_loop_holds_when_the_row_unloads
    ctx, loader = boot(script: [])
    loop_svc = ctx[:loop]
    a = ctx[:sessions].create
    b = ctx[:sessions].create
    agent_a = loop_svc.spawn_agent(session_id: a.id)
    agent_b = loop_svc.spawn_agent(session_id: b.id)
    disposed = []
    agent_a.ctx.effect { -> { disposed << agent_a.id } }
    agent_b.ctx.effect { -> { disposed << agent_b.id } }

    loader.unload!("loop")

    assert_equal [agent_a.id, agent_b.id].sort, disposed.sort,
                 "the loop's teardown must dispose every agent it spawned"
    assert_equal :done, agent_a.status
    assert_equal :done, agent_b.status
    assert_nil loop_svc.agent(agent_a.id)
    assert_nil loop_svc.agent(agent_b.id)
  end

  # Idempotent: a second stop (a re-run shutdown, or the loader disposing owner
  # effects after stop already ran) finds no agents and does nothing.
  def test_stop_is_idempotent
    ctx, = boot(script: [])
    loop_svc = ctx[:loop]
    s = ctx[:sessions].create
    loop_svc.spawn_agent(session_id: s.id)

    loop_svc.stop(ctx)
    loop_svc.stop(ctx) # must not raise
  end

  # A reaping bug in one listener must not strand disposal: emit isolates it.
  def test_dispose_agent_survives_a_raising_agent_disposed_listener
    ctx, = boot(script: [])
    s = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: s.id)
    ctx.on("agent/disposed") { |_sid| raise "boom" }

    ctx[:loop].dispose_agent(agent.id) # must not raise
    assert_nil ctx[:loop].agent(agent.id)
    assert_nil ctx[:loop].agent_for_session(s.id)
    ctx[:loop].spawn_agent(session_id: s.id) # the slot is genuinely free
  end

  # :done is terminal. A disposed agent's context is gone along with every
  # effect it owned, so the handle refuses rather than half-working against a
  # dead fork.
  def test_a_disposed_agent_is_done_and_refuses_another_turn
    ctx, = boot(script: [{ text: "hi" }])
    s = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: s.id)

    ctx[:loop].dispose_agent(agent.id)

    assert_equal :done, agent.status
    err = assert_raises(Terret::AgentDisposed) { ctx[:loop].run_turn(agent, "hello") }
    assert_match(/disposed/, err.message)
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

  def test_max_agents_hot_reloads
    ctx, loader = boot_with_cap(1)
    a = ctx[:sessions].create
    b = ctx[:sessions].create
    ctx[:loop].spawn_agent(session_id: a.id)
    assert_raises(Terret::AgentCapExceeded) { ctx[:loop].spawn_agent(session_id: b.id) }

    loader.reconfigure!("loop", { max_agents: 2 })
    ctx[:loop].spawn_agent(session_id: b.id) # the raised spawn now succeeds, no restart
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

  # A second turn/start over an open turn strands the owed call forever
  # (resumable? scans from the LAST turn/start) and leaves the projection
  # holding an assistant tool call with no result — a hard 400 on a real
  # adapter, permanently.
  def test_run_turn_refuses_a_session_whose_log_holds_an_open_turn
    ctx, = boot_with_approvals([{ text: "Deployed." }])
    register_deploy(ctx)
    session = ctx[:sessions].create
    craft_dangling_log(ctx, session)
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    before = session.events.length

    assert_raises(Terret::TurnOpenInLog) { ctx[:loop].run_turn(agent, "ship it") }
    assert_equal before, session.events.length, "the refusal must append nothing"
    assert ctx[:loop].resumable?(session.id), "the open turn must still be resumable"
    assert_equal :idle, agent.status
  end

  # A transient failure mid-resume (an LLM outage) must leave the turn open so
  # the next stimulus picks it up. Closing it with turn/end status failed would
  # brick the session: the owed tool call can never be completed after that.
  def test_a_failed_resume_leaves_the_turn_open_for_the_next_one
    ctx, = boot_with_approvals([]) # exhausted script: the adapter raises
    register_deploy(ctx)
    session = ctx[:sessions].create
    craft_dangling_log(ctx, session)
    ctx[:sessions].append(session.id, "approval/resolved", { call_id: "tc9", verdict: "approved" })
    agent = ctx[:loop].spawn_agent(session_id: session.id)

    assert_raises(RuntimeError) { ctx[:loop].resume_turn(agent) }
    refute session.events.map(&:type).include?("turn/end"), "a failed resume must not close the turn"
    assert ctx[:loop].resumable?(session.id)
    assert_equal :idle, agent.status

    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new([{ text: "Deployed." }]))
    assert_equal :completed, ctx[:loop].resume_turn(agent)
    assert_equal "turn/end", session.events.last.type
  end

  # run_turn keeps the old contract: a failure there is terminal for the turn,
  # and the log says so.
  def test_a_failed_run_turn_still_closes_with_a_failed_turn_end
    ctx, = boot_with_approvals([])
    agent, session = spawn(ctx)

    assert_raises(RuntimeError) { ctx[:loop].run_turn(agent, "hello") }
    assert_equal "failed", session.events.last.payload[:status]
  end
end

class HotPolicyTest < Minitest::Test
  include TerretTestHarness

  PING = Terret::LLM::ToolCall.new(id: "tp1", name: "ping", args: {})

  def register_ping(ctx)
    ctx.with_owner("ping-plugin") do
      ctx[:tools].register(name: "ping", description: "Pong", params: {}) { "pong" }
    end
  end

  def test_policy_updates_take_effect_without_reinstall
    ctx, = boot(script: [{ text: "Pinging.", tool_calls: [PING] }, { text: "done" },
                         { text: "Pinging.", tool_calls: [PING.with(id: "tp2")] }, { text: "done" }])
    register_ping(ctx)
    agent, session = spawn(ctx)
    Terret::Tools::AllowList.install(agent.ctx, ["nothing"]) # floor denies

    ctx[:loop].run_turn(agent, "ping please")
    first = session.events.find { |e| e.type == "tool/result" }
    assert_match(/allow list/, first.payload[:error])

    Terret::Tools::AllowList.update(ctx, session.id, ["ping"])
    ctx[:loop].run_turn(agent, "again")
    last = session.events.select { |e| e.type == "tool/result" }.last
    assert_equal "pong", last.payload[:content]
  end

  def test_the_last_policy_update_wins
    ctx, = boot(script: [])
    _, session = spawn(ctx)
    Terret::Tools::AllowList.update(ctx, session.id, ["a"])
    Terret::Tools::AllowList.update(ctx, session.id, ["b"])
    ev = session.events.select { |e| e.type == "policy/updated" }
    assert_equal 2, ev.length
    assert_equal ["b"], ev.last.payload[:patterns]
  end

  def test_a_hot_policy_survives_a_restart_by_replay
    dir = File.join(Dir.mktmpdir("terret-policy"), "store")
    # life A: JSONL store, floor allows ping, hot update denies everything
    ctx, = boot_jsonl(dir, script: [])
    session = ctx[:sessions].create(id: "p1")
    Terret::Tools::AllowList.update(ctx, "p1", ["nothing"])

    # life B: fresh boot, same dir; the embedder reinstalls only the BOOT floor
    ctx2, = boot_jsonl(dir, script: [{ text: "Pinging.", tool_calls: [PING] }, { text: "done" }])
    register_ping(ctx2)
    ctx2[:sessions].resume("p1")
    agent = ctx2[:loop].spawn_agent(session_id: "p1")
    Terret::Tools::AllowList.install(agent.ctx, ["ping"]) # boot floor says yes...

    ctx2[:loop].run_turn(agent, "ping?")
    result = ctx2[:sessions].fetch("p1").events.find { |e| e.type == "tool/result" }
    assert_match(/allow list/, result.payload[:error],
                 "...but the logged policy says no, and the log wins")
  end

  def test_policy_is_projection_invisible
    ctx, = boot(script: [])
    _, session = spawn(ctx)
    Terret::Tools::AllowList.update(ctx, session.id, ["x"])
    assert_empty ctx[:sessions].derive_messages(session.id)
  end

  # A session this context cannot read may carry a policy far stricter than
  # the boot floor. Falling back to the floor there grants MORE authority than
  # anyone configured, so an unknown session gets none.
  def test_an_unreadable_session_denies_every_call
    ctx, = boot(script: [])
    register_ping(ctx)
    agent, = spawn(ctx)
    Terret::Tools::AllowList.install(agent.ctx, ["ping"]) # the floor says yes

    call = Terret::Tools::Call.new(id: "x1", name: "ping", args: {}, session_id: "not-a-session")
    result = nil
    warned = capture_warn { result = ctx[:tools].execute(call, ctx: agent.ctx) }

    assert_nil result.content
    assert_match(/allow list/, result.error)
    assert_match(/not-a-session/, warned)
  end

  def test_a_warm_session_is_served_from_cache_without_rescanning
    ctx, = boot(script: [{ text: "Pinging.", tool_calls: [PING] }, { text: "done" },
                         { text: "Pinging.", tool_calls: [PING.with(id: "tp2")] }, { text: "done" }])
    register_ping(ctx)
    agent, session = spawn(ctx)
    Terret::Tools::AllowList.install(agent.ctx, ["ping"]) # floor allows; never updated

    scans = count_scans do
      ctx[:loop].run_turn(agent, "ping please")
      ctx[:loop].run_turn(agent, "again")
    end

    results = session.events.select { |e| e.type == "tool/result" }.map { |e| e.payload[:content] }
    assert_equal %w[pong pong], results, "both calls run under the floor policy"
    assert_equal 1, scans[session.id],
                 "the log is scanned once; the second call is served from the per-install cache"
  end

  def test_a_hot_update_primes_the_cache_so_the_next_call_does_not_rescan
    ctx, = boot(script: [{ text: "Pinging.", tool_calls: [PING] }, { text: "done" }])
    register_ping(ctx)
    agent, session = spawn(ctx)
    Terret::Tools::AllowList.install(agent.ctx, ["nothing"]) # floor denies

    Terret::Tools::AllowList.update(ctx, session.id, ["ping"]) # fan-out primes the cache

    scans = count_scans { ctx[:loop].run_turn(agent, "ping now") }

    last = session.events.select { |e| e.type == "tool/result" }.last
    assert_equal "pong", last.payload[:content], "the hot-updated policy governs the call"
    assert_equal 0, scans[session.id],
                 "policy/updated primed the cache via session/event; the call reads it, no rescan"
  end

  def capture_warn
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  # Observable for "no rescan": wrap the pure log derivation and tally it per
  # session. active_patterns calls current_patterns only on a cache miss, so a
  # session scanned once and never again is the cache doing its job. Restores
  # the method in ensure so the swap never escapes the block.
  def count_scans
    scans = Hash.new(0)
    mod = Terret::Tools::AllowList
    original = mod.method(:current_patterns)
    mod.singleton_class.send(:define_method, :current_patterns) do |ctx, sid|
      scans[sid] += 1
      original.call(ctx, sid)
    end
    yield
    scans
  ensure
    mod.singleton_class.send(:define_method, :current_patterns, original)
  end

  private

  def boot_jsonl(dir, script:)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::JSONL, config: { dir: dir } },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop",     plugin: Terret::Loop }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))
    [ctx, loader]
  end
end

class RegistryScopeTest < Minitest::Test
  include TerretTestHarness

  def test_an_agent_registered_tool_dies_with_the_agent
    ctx, = boot(script: [])
    s = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: s.id)
    agent.ctx.with_owner("agent-tools") do
      ctx[:tools].register(name: "mine", description: "scoped", params: {},
                           ctx: agent.ctx) { "ok" }
    end
    assert ctx[:tools].schemas.any? { |sc| sc[:name] == "mine" }

    ctx[:loop].dispose_agent(agent.id)
    refute ctx[:tools].schemas.any? { |sc| sc[:name] == "mine" },
           "a tool registered through a fork must not survive the fork's disposal"
  end

  def test_definitions_carry_concurrency_metadata
    ctx, = boot(script: [])
    ctx.with_owner("t") do
      ctx[:tools].register(name: "solo", description: "d", params: {},
                           concurrency: :serial) { "x" }
    end
    assert_equal :serial, ctx[:tools].fetch("solo").concurrency
  end
end

# M7 declared `concurrency:` on every Definition and honored it nowhere. This
# is the consumer: within one assistant message the loop partitions the calls
# into maximal runs, and a run of :parallel definitions executes under one
# barrier (docs/subagents.md §5).
class ToolBarrierTest < Minitest::Test
  include TerretTestHarness

  SLEEP = 0.1

  def batch_script(*names)
    calls = names.each_with_index.map do |n, i|
      Terret::LLM::ToolCall.new(id: "tc#{i + 1}", name: n, args: {})
    end
    [{ text: "Doing them.", tool_calls: calls }, { text: "All done." }]
  end

  # Each tool counts itself in and out, so the peak is what actually overlapped
  # rather than what the wall clock lets us infer.
  def register_slow(ctx, names, concurrency:, meter:)
    ctx.with_owner("slow-tools") do
      names.each do |name|
        ctx[:tools].register(name: name, description: "slow", params: {},
                             concurrency: concurrency) do
          meter[:in_flight] += 1
          meter[:peak] = [meter[:peak], meter[:in_flight]].max
          sleep SLEEP
          meter[:in_flight] -= 1
          "#{name} done"
        end
      end
    end
  end

  def timed_turn(ctx, agent)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Async { ctx[:loop].run_turn(agent, "go") }.wait
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  # The meter is the proof, not the clock. An upper bound on wall time is the
  # one assertion here a loaded CI runner can fail while the code is correct,
  # so overlap is asserted by what was in flight at once and nothing is
  # claimed about how long it took.
  def test_parallel_calls_in_one_message_run_concurrently
    skip "async is not installed" unless ASYNC_AVAILABLE

    ctx, = boot(script: batch_script("slow_a", "slow_b"))
    meter = { in_flight: 0, peak: 0 }
    register_slow(ctx, %w[slow_a slow_b], concurrency: :parallel, meter: meter)
    agent, = spawn(ctx)

    timed_turn(ctx, agent)

    assert_equal 2, meter[:peak], "both parallel calls must be in flight at once"
  end

  def test_serial_calls_never_overlap
    skip "async is not installed" unless ASYNC_AVAILABLE

    ctx, = boot(script: batch_script("slow_a", "slow_b"))
    meter = { in_flight: 0, peak: 0 }
    register_slow(ctx, %w[slow_a slow_b], concurrency: :serial, meter: meter)
    agent, = spawn(ctx)

    elapsed = timed_turn(ctx, agent)

    assert_equal 1, meter[:peak], "a serial call is a barrier of one"
    # Safe in the direction it is asserted: a sleep only ever overshoots, so
    # two sequential ones cannot come in under their sum however slow the
    # machine is. Only overlap could.
    assert_operator elapsed, :>=, SLEEP * 2,
                    "two #{SLEEP}s serial calls took #{elapsed.round(3)}s; they overlapped"
  end

  # Concurrency is allowed to change WHEN work happens. It is not allowed to
  # change what the log says happened: derive_messages projects the model's
  # history from this order and assert_log_invariant! digests against it, so a
  # log whose result order followed completion would replay differently than
  # it ran.
  def test_results_append_in_call_order_regardless_of_completion_order
    skip "async is not installed" unless ASYNC_AVAILABLE

    ctx, = boot(script: batch_script("slow", "quick"))
    finished = []
    ctx.with_owner("mixed-tools") do
      ctx[:tools].register(name: "slow", description: "s", params: {},
                           concurrency: :parallel) do
        sleep SLEEP
        finished << "slow"
        "slow result"
      end
      ctx[:tools].register(name: "quick", description: "q", params: {},
                           concurrency: :parallel) do
        finished << "quick"
        "quick result"
      end
    end
    agent, session = spawn(ctx)

    Async { ctx[:loop].run_turn(agent, "go") }.wait

    assert_equal %w[quick slow], finished, "the second call must really have finished first"
    results = session.events.select { |e| e.type == "tool/result" }
    assert_equal %w[tc1 tc2], results.map { |e| e.payload[:id] }
    assert_equal ["slow result", "quick result"], results.map { |e| e.payload[:content] }
  end

  # A run is launched as a group, so its calls are all logged before any of
  # their results — with no reactor in sight, since the shape of the log is a
  # property of the partition rather than of the scheduler.
  def test_a_parallel_run_logs_every_call_before_any_of_its_results
    ctx, = boot(script: batch_script("p_a", "p_b"))
    ctx.with_owner("pair") do
      %w[p_a p_b].each do |name|
        ctx[:tools].register(name: name, description: "p", params: {},
                             concurrency: :parallel) { "#{name} done" }
      end
    end
    agent, session = spawn(ctx)

    ctx[:loop].run_turn(agent, "go")

    batch = session.events.map(&:type).select { |t| %w[tool/call tool/result].include?(t) }
    assert_equal %w[tool/call tool/call tool/result tool/result], batch
  end

  # Three parallel calls where the MIDDLE one's execution is blown up by a
  # listener rather than by the handler — the one failure shape that escapes
  # Registry#execute's own error-Result rendering.
  def boot_raising_trio(error = RuntimeError.new("listener bug"))
    ctx, = boot(script: batch_script("p_a", "p_b", "p_c"))
    ran = []
    ctx.with_owner("trio") do
      %w[p_a p_b p_c].each do |name|
        ctx[:tools].register(name: name, description: "p", params: {},
                             concurrency: :parallel) do
          ran << name
          "#{name} did real work"
        end
      end
    end
    ctx.on("tools/execute") do |call, next_|
      raise error if call.name == "p_b"

      next_.(call)
    end
    agent, session = spawn(ctx)
    [ctx, agent, session, ran]
  end

  def assert_only_the_middle_call_failed(ctx, session, ran)
    assert_equal %w[p_a p_c], ran.sort, "a sibling's work must not be thrown away"
    results = session.events.select { |e| e.type == "tool/result" }
    assert_equal %w[tc1 tc2 tc3], results.map { |e| e.payload[:id] }
    assert_equal "p_a did real work", results[0].payload[:content]
    assert_nil results[1].payload[:content]
    assert_equal "RuntimeError: listener bug", results[1].payload[:error]
    assert_equal "p_c did real work", results[2].payload[:content]
    assert_equal "completed", session.events.last.payload[:status]

    # The invariant the log exists to hold: every call the projection shows
    # the model has a result under it.
    history = ctx[:sessions].derive_messages(session.id)
    owed = history.select { |m| m.role == :assistant }
                  .flat_map { |m| m.parts.grep(Terret::LLM::ToolCall) }.map(&:id)
    answered = history.select { |m| m.role == :tool }.flat_map(&:parts).map(&:id)
    assert_empty owed - answered, "the projection must never owe a call a result"
  end

  # A tool's own crash has always been an ordinary error Result. A listener
  # that raises AROUND the handler escaped that rendering, and under the
  # barrier it used to take the whole run with it: siblings that had already
  # done their work lost their results, the turn closed `failed`, and the
  # projection was left owing three calls it could never be given results for
  # (`resumable?` is false once the turn has closed, so nothing can repair
  # it). One call's failure is one call's error result.
  def test_a_raising_listener_fails_one_call_without_abandoning_its_siblings
    skip "async is not installed" unless ASYNC_AVAILABLE

    ctx, agent, session, ran = boot_raising_trio

    assert_equal :completed, Async { ctx[:loop].run_turn(agent, "go") }.wait

    assert_only_the_middle_call_failed(ctx, session, ran)
  end

  # The same guarantee where there is no reactor to run the fibers on. That
  # path is not a lesser mode — it is what every plain-minitest run and every
  # host that never loaded async takes — so it is pinned by its own test
  # rather than by the twin above. Testing only the reactor path is exactly
  # what let the two drift apart once.
  def test_a_raising_listener_fails_one_call_with_no_reactor_either
    ctx, agent, session, ran = boot_raising_trio

    assert_equal :completed, ctx[:loop].run_turn(agent, "go")

    assert_only_the_middle_call_failed(ctx, session, ran)
  end

  # A Failure is a domain outcome whose message is the whole story, and the
  # registry renders it message-only one level in. Catching it out here must
  # not start prefixing it with a class name a plugin never chose to show.
  def test_a_listener_raising_a_failure_still_renders_message_only
    ctx, agent, session, = boot_raising_trio(Terret::Tools::Failure.new("that one is out of stock"))

    ctx[:loop].run_turn(agent, "go")

    errored = session.events.select { |e| e.type == "tool/result" }[1]
    assert_equal "that one is out of stock", errored.payload[:error]
  end

  # The serial path is a barrier of one and gets the same guarantee the
  # parallel barrier does: a listener that raises AROUND the handler (the one
  # crash Registry#execute does not itself render) is one call's error result,
  # not a failed turn. Without it the tool/call was logged and the turn closed
  # `failed` with no tool/result under it — and because run_turn appended a
  # turn/end, `resumable?` goes false, so nothing repairs the dangling call. The
  # NEXT turn's derive_messages then projects an assistant tool_call a real
  # provider rejects outright: the failure poisons every turn after it.
  def test_a_raising_listener_on_a_serial_call_does_not_leave_a_dangling_call
    ctx, = boot(script: batch_script("lonely"))
    ran = []
    ctx.with_owner("solo") do
      ctx[:tools].register(name: "lonely", description: "s", params: {}) do
        ran << "lonely"
        "did work"
      end
    end
    ctx.on("tools/execute") do |call, next_|
      raise "listener bug" if call.name == "lonely"

      next_.(call)
    end
    agent, session = spawn(ctx)

    assert_equal :completed, ctx[:loop].run_turn(agent, "go")
    refute_includes ran, "lonely", "the listener raised before the handler could run"

    result = session.events.select { |e| e.type == "tool/result" }.first
    assert_equal "RuntimeError: listener bug", result.payload[:error]
    assert_equal "completed", session.events.last.payload[:status]

    # The invariant the log exists to hold, checked on the serial path: every
    # call the projection shows the model has a result under it, so the next
    # turn's request is well-formed rather than a tool_use with no tool_result.
    history = ctx[:sessions].derive_messages(session.id)
    owed = history.select { |m| m.role == :assistant }
                  .flat_map { |m| m.parts.grep(Terret::LLM::ToolCall) }.map(&:id)
    answered = history.select { |m| m.role == :tool }.flat_map(&:parts).map(&:id)
    assert_empty owed - answered, "a serial call's crash must not leave the projection owing a result"
  end

  # The same message-only rendering the parallel path keeps for a domain
  # Failure, on the serial path: its message is the whole story, unprefixed.
  def test_a_listener_raising_a_failure_on_a_serial_call_renders_message_only
    ctx, = boot(script: batch_script("lonely"))
    ctx.with_owner("solo") do
      ctx[:tools].register(name: "lonely", description: "s", params: {}) { "did work" }
    end
    ctx.on("tools/execute") do |call, next_|
      raise Terret::Tools::Failure, "out of stock" if call.name == "lonely"

      next_.(call)
    end
    agent, session = spawn(ctx)

    assert_equal :completed, ctx[:loop].run_turn(agent, "go")
    result = session.events.select { |e| e.type == "tool/result" }.first
    assert_equal "out of stock", result.payload[:error]
  end

  # A barrier is not interruptible from outside once it starts, so a cancel
  # requested while a run is in flight settles AFTER that run rather than
  # tearing fibers out of the middle of it. Every call in the batch still ends
  # with a result either way; there are simply fewer truncated ones.
  def test_a_cancel_inside_a_parallel_run_truncates_between_runs_not_within_one
    ctx, = boot(script: batch_script("canceller", "sibling", "loner", "later"))
    agent = nil
    ran = []
    ctx.with_owner("four-tools") do
      ctx[:tools].register(name: "canceller", description: "c", params: {},
                           concurrency: :parallel) do
        agent.cancel("user hit stop")
        ran << "canceller"
        "cancelled from here"
      end
      ctx[:tools].register(name: "sibling", description: "s", params: {},
                           concurrency: :parallel) do
        ran << "sibling"
        "sibling ran anyway"
      end
      ctx[:tools].register(name: "loner", description: "l", params: {},
                           concurrency: :serial) { ran << "loner" }
      ctx[:tools].register(name: "later", description: "x", params: {},
                           concurrency: :parallel) { ran << "later" }
    end
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)

    assert_equal :cancelled, ctx[:loop].run_turn(agent, "go")

    assert_equal %w[canceller sibling], ran,
                 "the run already in flight finishes; nothing after it starts"
    results = session.events.select { |e| e.type == "tool/result" }
    assert_equal %w[tc1 tc2 tc3 tc4], results.map { |e| e.payload[:id] },
                 "the projection never holds a call without a result"
    assert_equal "sibling ran anyway", results[1].payload[:content]
    assert_equal "cancelled before execution", results[2].payload[:error]
    assert_equal "cancelled before execution", results[3].payload[:error]
  end
end
