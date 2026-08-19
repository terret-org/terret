# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret"

# Two calls of one parallel run can be parked at the same time, and only a
# reactor can put them there: without one the barrier degrades to sequential
# and the second call never starts while the first is waiting on a human.
ASYNC_AVAILABLE = begin
  require "async"
  true
rescue LoadError
  false
end unless defined?(ASYNC_AVAILABLE)

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
    (@parked ||= []) << t
    await("never parked (status=#{agent.status})") { agent.status == :waiting_approval }
    t
  end

  # A test that fails between the park and its verdict leaves a thread blocked
  # on a queue nothing will ever push to. Nobody is coming with a decision once
  # the test is over, so what is still parked gets killed rather than left to
  # hold the suite.
  def teardown
    @parked&.each { |t| t.kill unless t.join(0.5) }
    @parked = nil
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

  # A cancel requested while a call was parked has not stopped being true just
  # because the human answered, so the gate's restore returns the agent to
  # :stopping rather than to :running — the status now says the same thing the
  # turn does.
  def test_the_approvals_restore_returns_a_cancelled_agent_to_stopping
    ctx, = boot(script: park_script)
    register_deploy(ctx, approval: :always)
    agent, session = spawn(ctx)
    unparked = []
    ctx.on("tools/post_execute") do |result, next_|
      unparked << agent.status
      next_.(result)
    end
    turn = park_turn(ctx, agent)

    # exactly what the socket does with a cancel frame on a parked agent
    agent.cancel("user hit stop")
    ctx[:approvals].deny_pending!(session.id, reason: "user hit stop")

    assert_equal :cancelled, turn.value
    assert_equal [:stopping], unparked
    assert_equal :idle, agent.status
    assert_equal "cancelled", session.events.last.payload[:status]
  end

  def test_an_uncancelled_parked_agent_still_restores_to_running
    ctx, = boot(script: park_script)
    register_deploy(ctx, approval: :always)
    agent, session = spawn(ctx)
    unparked = []
    ctx.on("tools/post_execute") do |result, next_|
      unparked << agent.status
      next_.(result)
    end
    turn = park_turn(ctx, agent)

    ctx[:sessions].append(session.id, "approval/resolved", { call_id: "tc1", verdict: "approved" })

    assert_equal :completed, turn.value
    assert_equal [:running], unparked
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

  # An agent no approver can reach (the subagent provider marks its children)
  # fails closed rather than parking forever on a request nobody will see.
  def test_an_unattended_agent_is_denied_rather_than_parked
    ctx, = boot(script: park_script)
    register_deploy(ctx, approval: :always)
    agent, session = spawn(ctx)
    agent.unattended = true

    t = Thread.new { ctx[:loop].run_turn(agent, "ship it") }
    joined = t.join(5)
    t.kill unless joined
    assert joined, "an unattended agent must never park"

    assert_equal :completed, t.value
    result = session.events.find { |e| e.type == "tool/result" }
    assert_equal "deploy denied: no approver can reach a subagent session", result.payload[:error]
    refute session.events.map(&:type).include?("approval/requested")
  end

  # The rule is about a request nobody can answer. A verdict already in the
  # log WAS answered, so replay honors it exactly as it does for any other
  # agent — a crash-and-resume inside a child is not a second decision.
  def test_a_recorded_verdict_is_still_honored_for_an_unattended_agent
    ctx, = boot(script: [{ text: "Done." }])
    register_deploy(ctx, approval: :always)
    agent, session = stage_open_turn(ctx, resolved: true)
    agent.unattended = true

    assert_equal :completed, ctx[:loop].resume_turn(agent)
    assert_equal "deployed to prod",
                 session.events.find { |e| e.type == "tool/result" }.payload[:content]
  end

  def test_a_vanished_tool_still_renders_a_recoverable_error
    ctx, = boot(script: [{ text: "Trying.", tool_calls: [DEPLOY_CALL] }, { text: "Oh well." }])
    agent, session = spawn(ctx) # deploy never registered
    assert_equal :completed, ctx[:loop].run_turn(agent, "ship it")
    assert_match(/KeyError/, session.events.find { |e| e.type == "tool/result" }.payload[:error])
  end
end

# One assistant message can park two calls at once now that a parallel run
# executes as a group. The status the socket branches on has to keep telling
# the truth through that, because :running on a still-parked turn is a turn
# nobody can cancel.
class ParallelApprovalsTest < Minitest::Test
  include ApprovalsHarness

  def setup
    skip "async is not installed" unless ASYNC_AVAILABLE
  end

  DEPLOY_A = Terret::LLM::ToolCall.new(id: "tc1", name: "deploy_a", args: {})
  DEPLOY_B = Terret::LLM::ToolCall.new(id: "tc2", name: "deploy_b", args: {})

  def two_deploy_script
    [{ text: "Deploying both.", tool_calls: [DEPLOY_A, DEPLOY_B] }, { text: "Done." }]
  end

  # `ran` is the only honest barrier for "the parked fiber has come back":
  # `pending` goes empty inside the appending fiber, before the waiter has
  # been scheduled at all, and the tool/result does not land until the whole
  # run finishes. The handler runs immediately after the gate lets the call
  # through, which is immediately after park's ensure restored the status.
  def register_parallel_deploys(ctx, ran)
    ctx.with_owner("deploys") do
      %w[deploy_a deploy_b].each do |name|
        ctx[:tools].register(name: name, description: "ship", params: {}, mutating: true,
                             approval: :always, concurrency: :parallel) do
          ran << name
          "#{name} shipped"
        end
      end
    end
  end

  def test_a_sibling_still_parked_keeps_the_agent_waiting_approval
    ctx, = boot(script: two_deploy_script)
    ran = []
    register_parallel_deploys(ctx, ran)
    agent, session = spawn(ctx)

    Sync do |task|
      turn = task.async { ctx[:loop].run_turn(agent, "ship it") }
      await("both calls never parked") { ctx[:approvals].pending(session.id).length == 2 }
      assert_equal :waiting_approval, agent.status

      ctx[:sessions].append(session.id, "approval/resolved",
                            { call_id: "tc1", verdict: "approved" })
      await("tc1 never unparked") { ran.include?("deploy_a") }

      assert_equal ["tc2"], ctx[:approvals].pending(session.id)
      assert_equal :waiting_approval, agent.status,
                   "one verdict must not announce a turn that is still parked on another"

      # ...which is the whole point: the socket reads this status to decide
      # whether a cancel needs deny_pending!, so a wrong :running here is a
      # turn that can never be cancelled.
      agent.cancel("user hit stop")
      ctx[:approvals].deny_pending!(session.id, reason: "user hit stop")
      assert_equal :cancelled, task.with_timeout(5) { turn.wait }
    end
  end

  def test_the_last_verdict_of_a_parallel_park_restores_the_agent
    ctx, = boot(script: two_deploy_script)
    register_parallel_deploys(ctx, [])
    agent, session = spawn(ctx)

    Sync do |task|
      turn = task.async { ctx[:loop].run_turn(agent, "ship it") }
      await("both calls never parked") { ctx[:approvals].pending(session.id).length == 2 }

      %w[tc1 tc2].each do |id|
        ctx[:sessions].append(session.id, "approval/resolved", { call_id: id, verdict: "approved" })
      end

      assert_equal :completed, task.with_timeout(5) { turn.wait }
      results = session.events.select { |e| e.type == "tool/result" }
      assert_equal ["deploy_a shipped", "deploy_b shipped"], results.map { |e| e.payload[:content] }
    end
  end
end
