# frozen_string_literal: true

module Terret
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
      @status = :idle
    end

    def inject(text)
      @inbox << text
    end

    def drain_inbox = @inbox.slice!(0..)
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
    end

    def spawn_agent(session_id:, id: "agent-#{session_id}")
      @agents[id] = Agent.new(id:, session_id:, ctx: @ctx.fork)
    end

    # Live-agent lookup for interfaces (§9.2); nil when never spawned.
    def agent(id) = @agents[id]

    # Runs one turn for `input`. Returns the turn status symbol.
    def run_turn(agent, input)
      ctx      = agent.ctx
      sessions = ctx[:sessions]
      sid      = agent.session_id
      agent.status = :running

      sessions.append(sid, "turn/start", { agent: agent.id })
      status = :completed
      steps = 0

      # claim next-step input plus anything waiting in the inbox
      pending = [input, *agent.drain_inbox].compact

      begin
        loop do
          claim = ctx.waterfall("agent/pre_step", Claim.of(pending)) { |c| c }
          if claim.rejected || (steps.zero? && claim.messages.empty? && pending.empty?)
            # a rejected or empty first claim still closes a durable turn that
            # spent no step, so the log records the attempt
            status = claim.rejected ? :rejected : :empty
            break
          end

          steps += 1
          raise "runaway turn" if steps > MAX_STEPS

          sessions.append(sid, "step/start", { n: steps })
          claim.messages.each { |t| sessions.append(sid, "user/message", { text: t }) }
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
            break # nothing owed
          end

          calls.each do |tc|
            sessions.append(sid, "tool/call", { id: tc.id, name: tc.name, args: tc.args })
            result = ctx[:tools].execute(
              Tools::Call.new(id: tc.id, name: tc.name, args: tc.args, session_id: sid)
            )
            sessions.append(sid, "tool/result",
                            { id: result.id, content: result.content, error: result.error })
          end
          sessions.append(sid, "step/end", step_end)
          # tools owe another request -> next step
        end
      rescue Exception
        status = :failed
        raise
      ensure
        ctx.serial("agent/turn_stopping", agent)
        sessions.append(sid, "turn/end", { status: status })
        agent.status = :idle
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
