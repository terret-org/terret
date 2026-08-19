# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret"

module ApprovalsHarness
  def boot(script:, extra_rows: [], approvals: { id: "approvals", plugin: Terret::Tools::Approvals })
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
      approvals,
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
    await("never parked (status=#{agent.status})") { agent.status == :waiting_approval }
    t
  end

  def await(message = "condition never held", timeout: 5)
    deadline = Time.now + timeout
    until yield
      raise message if Time.now > deadline

      sleep 0.005
    end
  end

  # The log a process death mid-park leaves behind: an open turn whose last
  # assistant message owes a deploy call that has no result yet.
  def stage_open_turn(ctx, resolved: false)
    session = ctx[:sessions].create
    sid = session.id
    agent = ctx[:loop].spawn_agent(session_id: sid)
    ctx[:sessions].append(sid, "turn/start", { agent: agent.id })
    ctx[:sessions].append(sid, "step/start", { n: 1 })
    ctx[:sessions].append(sid, "user/message", { text: "ship it" })
    ctx[:sessions].append(sid, "assistant/message",
                          { parts: [Terret::LLM.encode_part(DEPLOY_CALL)] })
    ctx[:sessions].append(sid, "tool/call", { id: "tc1", name: "deploy", args: { env: "prod" } })
    ctx[:sessions].append(sid, "approval/requested",
                          { call_id: "tc1", name: "deploy", args: { env: "prod" } })
    if resolved
      ctx[:sessions].append(sid, "approval/resolved", { call_id: "tc1", verdict: "approved" })
    end
    [agent, session]
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

  # Pins the collapse docs/exec.md §5 now states plainly: under this gate
  # :policy on a mutating tool and :always are the same verdict — both park.
  # It is why Bash's sandbox-derived approval changes what the Definition
  # DECLARES rather than what a caller experiences today, and the day a
  # consumer tells the two apart, this test is what makes that deliberate.
  def test_policy_on_a_mutating_tool_parks_exactly_as_always_does
    ctx, = boot(script: park_script)
    register_deploy(ctx, approval: :policy, mutating: true)
    agent, session = spawn(ctx)
    turn = park_turn(ctx, agent)

    assert ctx[:approvals].pending?(session.id, "tc1")
    ctx[:sessions].append(session.id, "approval/resolved", { call_id: "tc1", verdict: "approved" })
    assert_equal :completed, turn.value
    assert_equal "deployed to prod",
                 session.events.find { |e| e.type == "tool/result" }.payload[:content]
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
    # The restart property, with the restart staged in the log: the open turn
    # already carries the request and its verdict, so the resumed call must
    # consume that verdict and never park again.
    ctx, = boot(script: [{ text: "Done." }])
    register_deploy(ctx, approval: :always)
    agent, session = stage_open_turn(ctx, resolved: true)

    assert_equal :completed, ctx[:loop].resume_turn(agent)
    assert_equal "deployed to prod",
                 session.events.find { |e| e.type == "tool/result" }.payload[:content]
    # a second request would mean the gate parked despite a standing verdict
    assert_equal 1, session.events.count { |e| e.type == "approval/requested" }
  end

  def test_a_verdict_from_a_closed_turn_never_settles_a_later_call
    # Provider tool call ids are not contractually unique. An id reused after
    # its turn closed must be asked about again, not silently approved.
    ctx, = boot(script: park_script)
    register_deploy(ctx, approval: :always)
    agent, session = spawn(ctx)
    sid = session.id
    ctx[:sessions].append(sid, "turn/start", { agent: agent.id })
    ctx[:sessions].append(sid, "approval/requested",
                          { call_id: "tc1", name: "deploy", args: { env: "prod" } })
    ctx[:sessions].append(sid, "approval/resolved", { call_id: "tc1", verdict: "approved" })
    ctx[:sessions].append(sid, "turn/end", { status: "completed" })

    turn = park_turn(ctx, agent)
    assert ctx[:approvals].pending?(sid, "tc1"), "the new turn must stand on its own request"
    ctx[:sessions].append(sid, "approval/resolved", { call_id: "tc1", verdict: "denied" })
    assert_equal :completed, turn.value
  end

  def test_a_verdict_does_not_carry_over_to_a_call_with_different_args
    ctx, = boot(script: [])
    register_deploy(ctx, approval: :always)
    agent, session = spawn(ctx)
    sid = session.id
    ctx[:sessions].append(sid, "turn/start", { agent: agent.id })
    ctx[:sessions].append(sid, "approval/requested",
                          { call_id: "tc1", name: "deploy", args: { env: "staging" } })
    ctx[:sessions].append(sid, "approval/resolved", { call_id: "tc1", verdict: "approved" })

    # same open turn, same call id, but prod is not what anyone approved
    call = Terret::Tools::Call.new(id: "tc1", name: "deploy",
                                   args: { env: "prod" }, session_id: sid)
    t = Thread.new { ctx[:tools].execute(call, ctx: agent.ctx) }
    await { session.events.count { |e| e.type == "approval/requested" } == 2 }

    ctx[:sessions].append(sid, "approval/resolved", { call_id: "tc1", verdict: "denied" })
    result = t.value
    assert_nil result.content
    assert_match(/denied/, result.error)
  end

  def test_pending_ignores_requests_from_a_closed_turn
    ctx, = boot(script: [])
    _, session = spawn(ctx)
    sid = session.id
    ctx[:sessions].append(sid, "turn/start", { agent: "a" })
    ctx[:sessions].append(sid, "approval/requested", { call_id: "old", name: "x", args: {} })
    ctx[:sessions].append(sid, "turn/end", { status: "cancelled" })
    ctx[:sessions].append(sid, "turn/start", { agent: "a" })
    ctx[:sessions].append(sid, "approval/requested", { call_id: "new", name: "y", args: {} })

    assert_equal ["new"], ctx[:approvals].pending(sid)
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
    ctx[:sessions].append(session.id, "turn/start", { agent: "a" })
    ctx[:sessions].append(session.id, "approval/requested", { call_id: "a", name: "x", args: {} })
    ctx[:sessions].append(session.id, "approval/requested", { call_id: "b", name: "y", args: {} })
    ctx[:sessions].append(session.id, "approval/resolved",  { call_id: "a", verdict: "approved" })
    assert_equal ["b"], ctx[:approvals].pending(session.id)
  end

  # The gate's verdict lookup and park's waiter install are two statements.
  # A verdict landing between them signals a waiter that does not exist yet,
  # so the pop has nothing left to wake it. There is no seam between the two
  # to schedule a thread into, so this double makes the window deterministic:
  # the gate's lookup misses, park's re-check sees what landed.
  class RacingApprovals < Terret::Tools::Approvals
    def recorded_verdict(call)
      @looked = (@looked || 0) + 1
      @looked == 1 ? nil : super
    end
  end

  def test_park_rechecks_the_log_after_installing_its_waiter
    ctx, = boot(script: [{ text: "Done." }],
                approvals: { id: "approvals", plugin: RacingApprovals })
    register_deploy(ctx, approval: :always)
    agent, session = stage_open_turn(ctx, resolved: true)

    t = Thread.new { ctx[:loop].resume_turn(agent) }
    assert t.join(5), "park wedged on a queue nothing can signal"
    assert_equal :completed, t.value
    assert_equal "deployed to prod",
                 session.events.find { |e| e.type == "tool/result" }.payload[:content]
    assert_equal 1, session.events.count { |e| e.type == "approval/requested" }
  end

  def test_a_vanished_tool_still_renders_a_recoverable_error
    ctx, = boot(script: [{ text: "Trying.", tool_calls: [DEPLOY_CALL] }, { text: "Oh well." }])
    agent, session = spawn(ctx) # deploy never registered
    assert_equal :completed, ctx[:loop].run_turn(agent, "ship it")
    assert_match(/KeyError/, session.events.find { |e| e.type == "tool/result" }.payload[:error])
  end
end
