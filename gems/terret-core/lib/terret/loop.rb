# frozen_string_literal: true

module Terret
  # Raised when run_turn is called on an agent already mid-turn: concurrent
  # turns would interleave the durable log, so this refuses loudly instead.
  class TurnAlreadyRunning < StandardError; end

  # Raised on id or session collision in spawn_agent: silent replacement
  # leaked the old agent's forked context and orphaned its mid-turn state
  # (plan §14). Dispose the old agent first, explicitly.
  class AgentExists < StandardError; end

  # The hard cap on agents per process (plan §14, blast-radius): shard by
  # process rather than raising the cap when this bites.
  class AgentCapExceeded < StandardError; end

  # Claimed messages are [type, text] pairs — "user/message" for the turn's
  # input, "context/injected" for steers drained from the inbox — so the log
  # records provenance even after a pre_step listener rewrites the claim.
  Claim = Data.define(:messages, :rejected, :reason) do
    def self.of(messages) = new(messages:, rejected: false, reason: nil)
    def self.reject(reason:) = new(messages: [], rejected: true, reason:)
  end

  class Agent
    attr_reader :id, :session_id, :ctx
    attr_accessor :status

    def initialize(id:, session_id:, ctx:)
      @id = id
      @session_id = session_id
      @ctx = ctx           # a forked, agent-scoped context
      @inbox = []          # injected context waits here until a waking message
      @status = :idle # :idle | :running | :waiting_approval (parked in the tools pipeline)
      @cancelled = false
      @cancel_reason = nil
    end

    def inject(text)
      @inbox << text
    end

    def drain_inbox = @inbox.slice!(0..)

    def inbox_empty? = @inbox.empty?

    # Steers drained for a step that never happened go back to the front of
    # the queue, so a rejected claim cannot silently eat an inject.
    def requeue(items) = @inbox.unshift(*items)

    attr_reader :cancel_reason

    # Cooperative stop: the loop honors it at step boundaries. Mid-stream
    # abort arrives with the async task-tree work (plan §8); until then this
    # is the honest synchronous form. A cancel is per-turn and best-effort:
    # if the turn rejects, fails, or completes before a boundary honors it,
    # the cancel dies with that turn rather than haunting the next one.
    def cancel(reason = nil)
      @cancel_reason = reason
      @cancelled = true
    end

    def cancelled? = !!@cancelled

    def clear_cancel!
      @cancelled = false
      @cancel_reason = nil
    end
  end

  # ctx.loop — the default driver. A step is one model request plus the tool
  # calls it makes; a turn is zero or more steps and closes once nothing is
  # owed. The driver is itself a plugin: replace this row in config and every
  # tool, adapter, and UI keeps working.
  class Loop < Hames::Service
    service_key :loop
    inject :sessions, :tools, :llm, :prompt

    MAX_STEPS = 25

    def start(ctx)
      @ctx = ctx
      @agents = {}
      @by_session = {}
      @max_agents = config[:max_agents] || 128
    end

    def spawn_agent(session_id:, id: "agent-#{session_id}")
      raise AgentExists, "agent #{id} already exists" if @agents.key?(id)
      if (live = @by_session[session_id])
        raise AgentExists, "session #{session_id} already has agent #{live.id}"
      end
      if @agents.size >= @max_agents
        raise AgentCapExceeded,
              "#{@agents.size} agents live; max_agents is #{@max_agents}"
      end

      agent = Agent.new(id:, session_id:, ctx: @ctx.fork)
      @agents[id] = agent
      @by_session[session_id] = agent
      agent
    end

    # Live-agent lookup for interfaces (§9.2); nil when never spawned.
    def agent(id) = @agents[id]

    # Session -> live agent, for services that learn a session id from an
    # event and need the agent (approvals flips status through this).
    def agent_for_session(session_id) = @by_session[session_id]

    # Tear an idle agent down: its forked context disposes (listeners and
    # effects die with it) and both registry slots free. Mid-turn agents
    # refuse — cancel or resolve first.
    def dispose_agent(id)
      agent = @agents.fetch(id)
      unless agent.status == :idle
        raise TurnAlreadyRunning, "agent #{id} is #{agent.status}; dispose only idle agents"
      end

      agent.ctx.dispose!
      @agents.delete(id)
      @by_session.delete(agent.session_id)
      agent
    end

    TurnState = Struct.new(:status, :steered)

    # Runs one turn for `input`. Returns the turn status symbol.
    def run_turn(agent, input)
      turning(agent) do |state, sessions, sid|
        sessions.append(sid, "turn/start", { agent: agent.id })
        step_loop(agent, state, pending: input.nil? ? [] : [["user/message", input]], steps: 0)
      end
    end

    # Continue a turn the log left open (a process death mid-park, plan
    # §6.3/§12 M6). No second turn/start — the open one is already durable.
    # The open step completes first: tool calls owed by the last assistant
    # message that lack a tool/result re-execute through the pipeline, where
    # the approvals gate reads verdicts from the log — an approved call runs,
    # an unresolved one parks again on its standing request. Then stepping
    # continues as normal.
    def resume_turn(agent)
      raise ArgumentError, "session #{agent.session_id} has no open turn" unless resumable?(agent.session_id)

      turning(agent) do |state, _sessions, _sid|
        step_loop(agent, state, pending: [], steps: complete_dangling(agent))
      end
    end

    # The log has a turn/start after its last turn/end.
    def resumable?(session_id)
      events = @ctx[:sessions].fetch(session_id).events
      opened = events.rindex { |e| e.type == "turn/start" }
      return false unless opened

      events[opened..].none? { |e| e.type == "turn/end" }
    end

    private

    # Shared turn envelope: the status guard, the failure rescue, and the
    # turn/end ensure. Both entry points run their body inside it.
    def turning(agent)
      unless agent.status == :idle
        raise TurnAlreadyRunning, "agent #{agent.id} is #{agent.status}"
      end

      ctx      = agent.ctx
      sessions = ctx[:sessions]
      sid      = agent.session_id
      agent.status = :running
      state = TurnState.new(:completed, [])

      begin
        yield state, sessions, sid
      rescue Exception
        state.status = :failed
        agent.requeue(state.steered) unless state.steered.empty?
        raise
      ensure
        begin
          ctx.serial("agent/turn_stopping", agent)
          payload = { status: state.status }
          payload[:reason] = agent.cancel_reason if state.status == :cancelled && agent.cancel_reason
          sessions.append(sid, "turn/end", payload)
        ensure
          agent.clear_cancel!
          agent.status = :idle
        end
      end
      state.status
    end

    # The step cycle run_turn always had, extracted so resume_turn can enter
    # it mid-turn. `pending` holds [type, text] pairs (Task 5); `steps` is
    # how many step/starts the turn has already logged.
    def step_loop(agent, state, pending:, steps:)
      ctx      = agent.ctx
      sessions = ctx[:sessions]
      sid      = agent.session_id

      loop do
        if agent.cancelled?
          state.status = :cancelled
          return
        end

        # anything injected since the last step rides along with this one
        state.steered = agent.drain_inbox
        pending.concat(state.steered.map { |t| ["context/injected", t] })

        claim = ctx.waterfall("agent/pre_step", Claim.of(pending)) { |c| c }
        if claim.rejected || (steps.zero? && claim.messages.empty? && pending.empty?)
          # a rejected or empty first claim still closes a durable turn that
          # spent no step, so the log records the attempt
          agent.requeue(state.steered) if claim.rejected
          state.status = claim.rejected ? :rejected : :empty
          return
        end

        steps += 1
        raise "runaway turn" if steps > MAX_STEPS

        sessions.append(sid, "step/start", { n: steps })
        claim.messages.each { |(type, text)| sessions.append(sid, type, { text: text }) }
        state.steered = [] # once logged, these must never requeue
        pending = []

        history = sessions.derive_messages(sid)
        request = LLM::Request.new(model: nil, system: ctx[:prompt].render(agent:),
                                   messages: history, tools: ctx[:tools].schemas)
        request = ctx.waterfall("agent/request", request)
        sessions.assert_log_invariant!(sid, request.messages)

        usage = nil
        message = ctx[:llm].stream(ctx, role: :main, request: request) do |ev|
          case ev
          when LLM::TextDelta
            sessions.append(sid, "assistant/chunk", { text: ev.text })
          when LLM::Usage
            usage = ev
          end
        end
        sessions.append(sid, "assistant/message",
                        { parts: message.parts.map { |p| LLM.encode_part(p) } })
        step_end = usage ? { n: steps, usage: usage.to_h } : { n: steps }

        calls = message.tool_calls
        if calls.empty?
          sessions.append(sid, "step/end", step_end)
          state.status = :cancelled if agent.cancelled?
          return # nothing owed
        end

        calls.each do |tc|
          sessions.append(sid, "tool/call", { id: tc.id, name: tc.name, args: tc.args })
          if agent.cancelled?
            sessions.append(sid, "tool/result",
                            { id: tc.id, content: nil, error: "cancelled before execution" })
            next
          end

          execute_and_record(ctx, sessions, sid, tc)
        end
        sessions.append(sid, "step/end", step_end)
        # redundant under the sync driver (the next iteration's top check
        # would catch it); becomes load-bearing once tools can yield (§8)
        if agent.cancelled?
          state.status = :cancelled
          return
        end
        # tools owe another request -> next step
      end
    end

    def execute_and_record(ctx, sessions, sid, tc)
      result = ctx[:tools].execute(
        Tools::Call.new(id: tc.id, name: tc.name, args: tc.args, session_id: sid),
        ctx: ctx
      )
      sessions.append(sid, "tool/result",
                      { id: result.id, content: result.content, error: result.error })
    end

    # Close the crash-opened step: execute tool calls the open turn's own last
    # assistant message owes that have no tool/result yet (that event is the
    # truth — a tool/call event may itself have died unwritten; and scoping to
    # the open turn is what keeps a mutation an earlier, closed turn already
    # resolved from running twice), append the missing
    # tool/call events, results, and the step's step/end (without usage: the
    # original step's usage died with the process). Returns the step count so
    # step_loop numbers onward from it. Honest edges: an unclosed step/start
    # with no owed calls stays unclosed and stepping just continues; a turn
    # that crashed after a final no-tool assistant message resumes with one
    # extra model request (the model sees its history and wraps up).
    def complete_dangling(agent)
      ctx      = agent.ctx
      sessions = ctx[:sessions]
      sid      = agent.session_id
      events   = sessions.fetch(sid).events
      turn     = events[events.rindex { |e| e.type == "turn/start" }..]
      steps    = turn.count { |e| e.type == "step/start" }

      resolved = turn.filter_map { |e| e.payload[:id] if e.type == "tool/result" }
      last_assistant = turn.reverse_each.find { |e| e.type == "assistant/message" }
      owed = if last_assistant
               last_assistant.payload[:parts]
                             .map { |p| LLM.decode_part(p) }
                             .grep(LLM::ToolCall)
                             .reject { |tc| resolved.include?(tc.id) }
             else
               [] # the open turn never got a model reply; nothing is owed
             end
      return steps if owed.empty?

      logged = turn.filter_map { |e| e.payload[:id] if e.type == "tool/call" }
      owed.each do |tc|
        unless logged.include?(tc.id)
          sessions.append(sid, "tool/call", { id: tc.id, name: tc.name, args: tc.args })
        end
        execute_and_record(ctx, sessions, sid, tc)
      end
      sessions.append(sid, "step/end", { n: steps })
      steps
    end
  end

  # ctx.prompt — minimal prompt assembly: priority-ordered sections rendered
  # per step; registration is an effect.
  class Prompt < Hames::Service
    service_key :prompt

    def start(ctx)
      @ctx = ctx
      @sections = []
    end

    def register_section(name, priority: 100, &block)
      entry = [priority, name.to_s, block]
      @ctx.effect do
        @sections << entry
        -> { @sections.delete(entry) }
      end
    end

    def render(env = {})
      @sections.sort_by { |(p, n, _)| [p, n] }
               .filter_map { |(_, _, b)| b.call(env) }
               .join("\n\n")
    end
  end
end
