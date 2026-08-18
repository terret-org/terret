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

  def test_injected_context_rides_along_with_the_waking_message
    ctx, = boot(script: [{ text: "noted" }])
    agent, session = spawn(ctx)
    agent.inject("FYI: user prefers metric units")
    ctx[:loop].run_turn(agent, "hello")

    user_events = session.events.select { |e| e.type == "user/message" }
    assert_equal ["hello", "FYI: user prefers metric units"],
                 user_events.map { |e| e.payload[:text] }
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
      step/start user/message assistant/message step/end
      turn/end
    ], chunkless

    steer = session.events.select { |e| e.type == "user/message" }.last
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
    texts = session.events.select { |e| e.type == "user/message" }.map { |e| e.payload[:text] }
    assert_equal ["second try", "remember the umbrella"], texts
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

  def test_respawning_an_id_replaces_the_registry_entry
    ctx, = boot(script: [{ text: "hi" }])
    session = ctx[:sessions].create
    first  = ctx[:loop].spawn_agent(session_id: session.id)
    second = ctx[:loop].spawn_agent(session_id: session.id)

    assert_same second, ctx[:loop].agent(first.id)
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
