# frozen_string_literal: true

module Terret
  # Raised when run_turn is called on an agent already mid-turn: concurrent
  # turns would interleave the durable log, so this refuses loudly instead.
  class TurnAlreadyRunning < StandardError; end

  # Raised when run_turn is called on a session whose log still holds an open
  # turn. A second turn/start would strand whatever the open turn owes —
  # resumable? scans from the LAST turn/start — and leave the projection
  # carrying an assistant tool call with no result, which a real adapter
  # rejects outright, forever. Resume the open turn instead.
  class TurnOpenInLog < StandardError; end

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

    def reconfigure(config)
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
      # Only an idle agent is asked this: while it is mid-turn the log's open
      # turn is its own, TurnAlreadyRunning is the accurate answer, and the
      # socket's raced-wake requeue is written against it.
      if agent.status == :idle && resumable?(agent.session_id)
        raise TurnOpenInLog,
              "session #{agent.session_id} has an open turn; resume_turn it"
      end

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

      # A transient failure here (an LLM outage) must leave the turn open for
      # the next stimulus: closing it would strand the owed tool call for good.
      turning(agent, close_on_failure: false) do |state, _sessions, _sid|
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
    def turning(agent, close_on_failure: true)
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
          if state.status != :failed || close_on_failure
            payload = { status: state.status }
            payload[:reason] = agent.cancel_reason if state.status == :cancelled && agent.cancel_reason
            sessions.append(sid, "turn/end", payload)
          end
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
        # A provider's deltas break at token boundaries, so a credential can
        # straddle two of them: "...is sk-a" + "bc123def" defeats a pattern
        # that matches the whole secret perfectly, and the tail lands in the
        # log verbatim. The carry holds the last `hold` bytes back until more
        # text arrives, so a scrubber sees the shape whole (§13, docs/exec.md
        # §6). Chunks are replay/UI fidelity and are NOT projected by
        # derive_messages, so re-chunking cannot move the digest — only their
        # concatenation is contractual, and that is unchanged.
        carry = +""
        hold  = sessions.scrubbing? ? scrub_carry : 0
        message = ctx[:llm].stream(ctx, role: :main, request: request) do |ev|
          case ev
          when LLM::TextDelta
            carry << ev.text
            flush_chunks(sessions, sid, carry, hold: hold)
          when LLM::ToolCallEnd, LLM::MessageStop
            flush_chunks(sessions, sid, carry, hold: 0) # the text stream ended here
          when LLM::Usage
            usage = ev
          end
        end
        # Belt and braces for an adapter that ends without a MessageStop. A
        # stream that RAISES loses the held-back tail, which is honest: its
        # assistant/message never lands either, and resume re-requests the step.
        flush_chunks(sessions, sid, carry, hold: 0)
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

    # Resume replays a tool call decoded from the LOG, and the log is
    # scrubbed: an argument that carried a credential carries the replacement
    # token instead. Re-running `deploy --key [REDACTED]` is not a retry of
    # what the model asked for, it is a DIFFERENT command with the same name —
    # and for Bash or Write that difference is a real, irreversible side
    # effect. The M6 at-least-once contract (docs/lifecycle.md) yields to
    # honesty here: the call is refused with a result that says why, and the
    # model's next step decides what to do about it.
    #
    # Only the redactor's own token is known. A scrubber registered directly
    # with some other replacement is not detectable from here, and a call it
    # rewrote still replays — stated in docs/exec.md §6 rather than guessed at.
    def redaction_token(ctx) = ctx.service?(:redactor) ? ctx[:redactor].replacement : nil

    def redacted?(value, token)
      case value
      when String then value.include?(token)
      when Array  then value.any? { |v| redacted?(v, token) }
      when Hash   then value.any? { |_k, v| redacted?(v, token) }
      else false
      end
    end

    # How much streamed text is held back so a scrubber can see a secret that
    # spans two deltas. Read per turn, so a hot-swapped row governs the next
    # one; a secret longer than this window can still straddle the boundary,
    # which is the honest limit of the mechanism (docs/exec.md §6).
    DEFAULT_SCRUB_CARRY = 256

    def scrub_carry = config[:scrub_carry] || DEFAULT_SCRUB_CARRY

    # Append everything but the last `hold` bytes of the buffer as one chunk,
    # consuming exactly what it appended. The cut lands on a character
    # boundary: slicing by bytes can split a multibyte character in half, and
    # those halves are bytes no provider sent — the append boundary refuses
    # them, a layer away from the code that made them.
    def flush_chunks(sessions, sid, buffer, hold:)
      cut = buffer.bytesize - hold
      return if cut <= 0

      prefix = whole_characters(buffer.byteslice(0, cut))
      return if prefix.empty?

      # Consumed first: the buffer is the record of what has NOT been logged,
      # and it must not still claim text that an append is already carrying.
      buffer.slice!(0, prefix.length)
      sessions.append(sid, "assistant/chunk", { text: prefix })
    end

    def whole_characters(text)
      text = text.byteslice(0, text.bytesize - 1) until text.valid_encoding?
      text
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
      token = redaction_token(ctx)
      owed.each do |tc|
        unless logged.include?(tc.id)
          sessions.append(sid, "tool/call", { id: tc.id, name: tc.name, args: tc.args })
        end
        if token && redacted?(tc.args, token)
          sessions.append(sid, "tool/result",
                          { id: tc.id, content: nil,
                            error: "#{tc.name} was not replayed on resume: its arguments were " \
                                   "redacted in the session log, so the recorded call is not " \
                                   "the call that was made" })
          next
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
