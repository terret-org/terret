# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret"

module ApprovalsHarness
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
      { id: "approvals", plugin: Terret::Tools::Approvals },
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

  DEPLOY_CALL = Terret::LLM::ToolCall.new(id: "tc1", name: "deploy", args: { env: "prod" })

  def register_deploy(ctx, approval:, mutating: true)
    ctx.with_owner("deploy-plugin") do
      ctx[:tools].register(name: "deploy", description: "Ship it",
                           params: { env: "string" }, mutating: mutating,
                           approval: approval) { |env:| "deployed to #{env}" }
    end
  end

  def park_script = [{ text: "Deploying.", tool_calls: [DEPLOY_CALL] }, { text: "Done." }]

  # Run a turn in a background thread; wait until the agent parks.
  def park_turn(ctx, agent)
    t = Thread.new { ctx[:loop].run_turn(agent, "ship it") }
    deadline = Time.now + 5
    until agent.status == :waiting_approval
      raise "never parked (status=#{agent.status})" if Time.now > deadline

      sleep 0.005
    end
    t
  end
end

class ApprovalsGateTest < Minitest::Test
  include ApprovalsHarness

  def test_never_and_unmutating_policy_pass_through_without_asking
    [[:never, true], [:policy, false]].each do |approval, mutating|
      ctx, = boot(script: park_script)
      register_deploy(ctx, approval: approval, mutating: mutating)
      agent, session = spawn(ctx)
      assert_equal :completed, ctx[:loop].run_turn(agent, "ship it")
      refute session.events.map(&:type).include?("approval/requested")
      assert_equal "deployed to prod",
                   session.events.find { |e| e.type == "tool/result" }.payload[:content]
    end
  end

  def test_always_parks_and_an_approval_unparks_and_executes
    ctx, = boot(script: park_script)
    register_deploy(ctx, approval: :always)
    agent, session = spawn(ctx)
    turn = park_turn(ctx, agent)

    requested = session.events.find { |e| e.type == "approval/requested" }
    assert_equal({ call_id: "tc1", name: "deploy", args: { env: "prod" } }, requested.payload)
    assert ctx[:approvals].pending?(session.id, "tc1")

    ctx[:sessions].append(session.id, "approval/resolved", { call_id: "tc1", verdict: "approved" })
    assert_equal :completed, turn.value
    assert_equal "deployed to prod",
                 session.events.find { |e| e.type == "tool/result" }.payload[:content]
    assert_equal :idle, agent.status
    refute ctx[:approvals].pending?(session.id, "tc1")
  end

  def test_a_denial_renders_as_an_error_result_and_the_turn_continues
    ctx, = boot(script: park_script)
    register_deploy(ctx, approval: :always)
    agent, session = spawn(ctx)
    turn = park_turn(ctx, agent)

    ctx[:sessions].append(session.id, "approval/resolved",
                          { call_id: "tc1", verdict: "denied", reason: "not on a Friday" })
    assert_equal :completed, turn.value
    result = session.events.find { |e| e.type == "tool/result" }
    assert_nil result.payload[:content]
    assert_match(/denied.*not on a Friday/, result.payload[:error])
  end

  def test_a_verdict_already_in_the_log_settles_without_parking
    # The restart property, minus the restart: the resolved event precedes
    # execution, so the gate must consume it and never park.
    ctx, = boot(script: park_script)
    register_deploy(ctx, approval: :always)
    agent, session = spawn(ctx)
    ctx[:sessions].append(session.id, "approval/resolved", { call_id: "tc1", verdict: "approved" })

    assert_equal :completed, ctx[:loop].run_turn(agent, "ship it")
    assert_equal "deployed to prod",
                 session.events.find { |e| e.type == "tool/result" }.payload[:content]
    # exactly one requested/resolved pair would be wrong: nothing new was requested
    refute session.events.map(&:type).include?("approval/requested")
  end

  def test_a_prior_veto_settles_the_call_before_anyone_is_asked
    ctx, = boot(script: park_script)
    register_deploy(ctx, approval: :always)
    agent, session = spawn(ctx)
    Terret::Tools::AllowList.install(agent.ctx, ["weather"]) # deploy not listed

    assert_equal :completed, ctx[:loop].run_turn(agent, "ship it")
    refute session.events.map(&:type).include?("approval/requested"),
           "a vetoed call must never ask for approval"
    assert_match(/allow list/, session.events.find { |e| e.type == "tool/result" }.payload[:error])
  end

  def test_deny_pending_denies_durably_and_unparks
    ctx, = boot(script: park_script)
    register_deploy(ctx, approval: :always)
    agent, session = spawn(ctx)
    turn = park_turn(ctx, agent)

    ctx[:approvals].deny_pending!(session.id, reason: "cancelled")
    assert_equal :completed, turn.value
    resolved = session.events.find { |e| e.type == "approval/resolved" }
    assert_equal "denied", resolved.payload[:verdict]
    assert_empty ctx[:approvals].pending(session.id)
  end

  def test_pending_lists_requested_without_resolved
    ctx, = boot(script: [])
    _, session = spawn(ctx)
    ctx[:sessions].append(session.id, "approval/requested", { call_id: "a", name: "x", args: {} })
    ctx[:sessions].append(session.id, "approval/requested", { call_id: "b", name: "y", args: {} })
    ctx[:sessions].append(session.id, "approval/resolved",  { call_id: "a", verdict: "approved" })
    assert_equal ["b"], ctx[:approvals].pending(session.id)
  end

  def test_a_vanished_tool_still_renders_a_recoverable_error
    ctx, = boot(script: [{ text: "Trying.", tool_calls: [DEPLOY_CALL] }, { text: "Oh well." }])
    agent, session = spawn(ctx) # deploy never registered
    assert_equal :completed, ctx[:loop].run_turn(agent, "ship it")
    assert_match(/KeyError/, session.events.find { |e| e.type == "tool/result" }.payload[:error])
  end
end
