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

    # Runs one turn for `input`. Returns the turn status symbol.
    def run_turn(agent, input)
      raise TurnAlreadyRunning, "agent #{agent.id} is mid-turn" if agent.status == :running

      ctx      = agent.ctx
      sessions = ctx[:sessions]
      sid      = agent.session_id
      agent.status = :running

      status = :completed
      steps = 0
      steered = []

      pending = input.nil? ? [] : [["user/message", input]]

      begin
        sessions.append(sid, "turn/start", { agent: agent.id })
        loop do
          if agent.cancelled?
            status = :cancelled
            break
          end

          # anything injected since the last step rides along with this one
          steered = agent.drain_inbox
          pending.concat(steered.map { |t| ["context/injected", t] })

          claim = ctx.waterfall("agent/pre_step", Claim.of(pending)) { |c| c }
          if claim.rejected || (steps.zero? && claim.messages.empty? && pending.empty?)
            # a rejected or empty first claim still closes a durable turn that
            # spent no step, so the log records the attempt
            agent.requeue(steered) if claim.rejected
            status = claim.rejected ? :rejected : :empty
            break
          end

          steps += 1
          raise "runaway turn" if steps > MAX_STEPS

          sessions.append(sid, "step/start", { n: steps })
          claim.messages.each { |(type, text)| sessions.append(sid, type, { text: text }) }
          steered = [] # once logged, these must never requeue
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
            status = :cancelled if agent.cancelled?
            break # nothing owed
          end

          calls.each do |tc|
            sessions.append(sid, "tool/call", { id: tc.id, name: tc.name, args: tc.args })
            if agent.cancelled?
              sessions.append(sid, "tool/result",
                              { id: tc.id, content: nil, error: "cancelled before execution" })
              next
            end

            result = ctx[:tools].execute(
              Tools::Call.new(id: tc.id, name: tc.name, args: tc.args, session_id: sid),
              ctx: ctx
            )
            sessions.append(sid, "tool/result",
                            { id: result.id, content: result.content, error: result.error })
          end
          sessions.append(sid, "step/end", step_end)
          # redundant under the sync driver (the next iteration's top check
          # would catch it); becomes load-bearing once tools can yield (§8)
          if agent.cancelled?
            status = :cancelled
            break
          end
          # tools owe another request -> next step
        end
      rescue Exception
        status = :failed
        agent.requeue(steered) unless steered.empty?
        raise
      ensure
        begin
          ctx.serial("agent/turn_stopping", agent)
          payload = { status: status }
          payload[:reason] = agent.cancel_reason if status == :cancelled && agent.cancel_reason
          sessions.append(sid, "turn/end", payload)
        ensure
          agent.clear_cancel!
          agent.status = :idle
        end
      end
      status
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
