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

  # Raised when a turn is asked of an agent dispose_agent already tore down.
  # Its forked context is gone along with every effect it owned, so the honest
  # answer is a refusal rather than a turn half-working against a dead fork.
  class AgentDisposed < StandardError; end

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

    # True when no human can be asked about this agent's tool calls. Nothing
    # routes an approval request for a subagent's session to an operator — the
    # parent's log does not even name it (docs/subagents.md §2) — so the
    # approvals gate denies rather than parking on a verdict that can never
    # arrive. Set by the subagent provider on the children it spawns; a
    # top-level agent is attended and parks exactly as it always did.
    attr_accessor :unattended

    def initialize(id:, session_id:, ctx:)
      @id = id
      @session_id = session_id
      @ctx = ctx           # a forked, agent-scoped context
      @inbox = []          # injected context waits here until a waking message
      @unattended = false
      # :idle | :running | :waiting_approval (parked in the tools pipeline) |
      # :stopping (cancelled, still finishing) | :done (disposed, terminal).
      # docs/subagents.md §8: :failed is a TURN status, not an agent one, and
      # :waiting_input stays vocabulary until something parks a turn on it.
      @status = :idle
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
    # is the honest synchronous form.
    #
    # A cancel raised DURING a turn is per-turn and best-effort: whether that
    # turn rejects, fails, or completes before a boundary honors it, turning's
    # ensure clears the flag, so it never haunts the next one. A cancel on an
    # IDLE agent has no turn to clear it and so it persists — the next turn
    # honors it at once and closes cancelled having spent no step, which is
    # what a stop pressed just before a message lands should do.
    #
    # The status moves only from :running: :stopping is a sub-state of a turn
    # that is still working and is no longer going to finish, so there is
    # nothing for it to mean on an idle agent — and an idle agent left
    # non-idle by a cancel could never start the turn that would clear it.
    # A parked agent keeps saying :waiting_approval, which is still true; the
    # approvals gate's restore is what reads the standing cancel and returns
    # it to :stopping rather than to :running.
    def cancel(reason = nil)
      @cancel_reason = reason
      @cancelled = true
      @status = :stopping if @status == :running
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

    # `parent:` is the context the agent's own scope forks from. It defaults to
    # this service's root exactly as it always did, so every interface spawning
    # a top-level agent keeps its call site; the subagent provider is the one
    # caller that passes something else — the CALLING agent's fork, which is
    # what makes a child inherit that agent's roster and policy floor instead
    # of the root's (docs/subagents.md §3).
    def spawn_agent(session_id:, id: "agent-#{session_id}", parent: @ctx)
      raise AgentExists, "agent #{id} already exists" if @agents.key?(id)
      if (live = @by_session[session_id])
        raise AgentExists, "session #{session_id} already has agent #{live.id}"
      end
      if @agents.size >= @max_agents
        raise AgentCapExceeded,
              "#{@agents.size} agents live; max_agents is #{@max_agents}"
      end

      agent = Agent.new(id:, session_id:, ctx: parent.fork)
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
      agent.status = :done # terminal: the handle now refuses a turn outright
      @agents.delete(id)
      @by_session.delete(agent.session_id)
      # Fork disposal reaps the agent's registrations, but the process state a
      # tool call created — ctx[:shell]'s bash, ctx[:terminals]' PTYs — is
      # root-mounted and keyed by session, so it survives the fork. This is the
      # signal those services reap it on; core stays decoupled from the optional
      # exec gem by only emitting, and emit isolates a listener fault so a
      # reaping bug cannot strand the disposal that already happened.
      @ctx.emit("agent/disposed", agent.session_id)
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
      raise AgentDisposed, "agent #{agent.id} was disposed" if agent.status == :done
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
        # log verbatim. A scrubber can only be trusted with text it sees
        # WHOLE, so while anything is scrubbing the entire run is held and
        # appended as ONE chunk at the run's end. That trades live token
        # streaming in the chunk log for the §13 guarantee, and the trade is
        # only affordable because chunks are replay/UI fidelity: they are not
        # projected by derive_messages, so nothing here can move the digest,
        # and only their concatenation is contractual (docs/exec.md §6).
        #
        # Captured once rather than per delta, so one run is governed by one
        # policy even if a scrubber is registered while it streams.
        scrubbing = sessions.scrubbing?
        run = +""
        message = ctx[:llm].stream(ctx, role: :main, request: request) do |ev|
          case ev
          when LLM::TextDelta
            if scrubbing
              run << ev.text
            else
              sessions.append(sid, "assistant/chunk", { text: ev.text })
            end
          when LLM::ToolCallEnd, LLM::MessageStop
            flush_run(sessions, sid, run) # this run of text ended here
          when LLM::Usage
            usage = ev
          end
        end
        # Belt and braces for an adapter that ends without a MessageStop. A
        # stream that RAISES loses the whole held run: run_turn closes the
        # failed turn (close_on_failure), so the next turn starts fresh with
        # no assistant/message for this step either — the chunk log and the
        # authoritative log agree about a step that never completed.
        flush_run(sessions, sid, run)
        sessions.append(sid, "assistant/message",
                        { parts: message.parts.map { |p| LLM.encode_part(p) } })
        step_end = usage ? { n: steps, usage: usage.to_h } : { n: steps }

        calls = message.tool_calls
        if calls.empty?
          sessions.append(sid, "step/end", step_end)
          state.status = :cancelled if agent.cancelled?
          return # nothing owed
        end

        execute_batch(agent, ctx, sessions, sid, calls)
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
    # scrubbed: whatever carried a credential carries the replacement token
    # instead. Re-running `deploy --key [REDACTED]` is not a retry of what the
    # model asked for, it is a DIFFERENT command with the same name — and for
    # Bash or Write that difference is a real, irreversible side effect. The M6
    # at-least-once contract (docs/lifecycle.md) yields to honesty here: the
    # call is refused with a result that says why, and the model's next step
    # decides what to do about it.
    #
    # The NAME is checked as well as the args, though a redacted name could
    # never have resolved anyway: "no such tool" would tell the model its
    # roster is broken, when what actually happened is that the log rewrote
    # its own record of the call. One refusal, one accurate reason, wherever
    # the token landed.
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

    # Append a held run of text as one chunk. No cuts anywhere: a partial run
    # is exactly what a scrubber cannot be shown, and a whole one never splits
    # a multibyte character either.
    def flush_run(sessions, sid, buffer)
      return if buffer.empty?

      # Emptied first: the buffer records what has NOT been logged, and it
      # must not still claim text an append is already carrying.
      text = buffer.dup
      buffer.clear
      sessions.append(sid, "assistant/chunk", { text: text })
    end

    # One assistant message's tool calls, run as maximal runs of the
    # concurrency their definitions declare (docs/subagents.md §5).
    #
    # MAXIMAL runs, rather than every parallel call in the message gathered
    # together, is what preserves a serial call's meaning: it is a barrier of
    # one, and nothing may reorder across it.
    #
    # Cancellation lands BETWEEN runs, because a barrier cannot be interrupted
    # from outside once it starts. Every call still ends with a result either
    # way — the projection may never hold a call without one.
    def execute_batch(agent, ctx, sessions, sid, calls)
      maximal_runs(ctx, calls).each do |concurrent, run|
        if agent.cancelled?
          run.each do |tc|
            log_call(sessions, sid, tc)
            sessions.append(sid, "tool/result",
                            { id: tc.id, content: nil, error: "cancelled before execution" })
          end
          next
        end

        # The whole run is logged before any of it executes: it is launched as
        # a group, so there is no per-call moment to interleave a call event
        # into.
        run.each { |tc| log_call(sessions, sid, tc) }
        results = if concurrent
                    execute_together(ctx, sid, run)
                  else
                    run.map { |tc| execute_call(ctx, sid, tc) }
                  end
        # In CALL order, always. Concurrency may change when work happens; it
        # may not change what the log says happened, because derive_messages
        # projects the model's history from this order and resume rebuilds it.
        results.each do |r|
          sessions.append(sid, "tool/result", { id: r.id, content: r.content, error: r.error })
        end
      end
    end

    # [[concurrent?, [call, ...]], ...]. A lone :parallel call is executed as
    # a run of one — there is nothing to overlap it with, and a fiber for it
    # would buy latency rather than spend it.
    def maximal_runs(ctx, calls)
      calls.chunk_while { |a, b| parallel?(ctx, a) && parallel?(ctx, b) }
           .map { |run| [run.length > 1, run] }
    end

    # An unknown tool is a barrier of one: it cannot be dispatched, and the
    # pipeline renders its "no such tool" error as an ordinary result.
    def parallel?(ctx, call)
      ctx[:tools].fetch(call.name).concurrency == :parallel
    rescue KeyError
      false
    end

    # The barrier: one Async task per call on the one reactor, and dispatch
    # completes only when every call has. Async is not a dependency of this
    # gem — without a reactor the run still completes as a group, one call at
    # a time, exactly the contract Hames' own :parallel dispatch keeps.
    #
    # Nothing a call does escapes its own fiber. Registry#execute already
    # renders a handler's crash as an error Result; a listener that raises
    # AROUND it escapes that rendering, and letting it out here would abandon
    # the whole run — siblings that had already done their work would lose
    # their results, and the projection would be left owing calls it can never
    # be given results for, because the turn closes and `resumable?` goes
    # false. So the same shape is applied one level out: one call's failure is
    # one call's error result, and every other result still appends.
    def execute_together(ctx, sid, run)
      task = defined?(Async::Task) ? Async::Task.current? : nil
      # Guarded on both paths. Without a reactor the run is still a run, and a
      # host that never loaded async must not be the one deployment where a
      # raising listener eats its siblings' results.
      return run.map { |tc| guarded_call(ctx, sid, tc) } unless task

      results = Array.new(run.length)
      children = run.each_with_index.map do |tc, i|
        task.async { results[i] = guarded_call(ctx, sid, tc) }
      end
      # Every sibling is awaited whatever the first wait does, so the batch's
      # bookkeeping finishes even while the task tree is being torn down —
      # Async::Stop is not a StandardError, and a half-awaited run would leave
      # fibers writing into an array nobody is watching. The first exception
      # is re-raised once there is nothing left in flight.
      stopped = nil
      children.each do |child|
        child.wait
      rescue Exception => e # rubocop:disable Lint/RescueException
        stopped ||= e
      end
      raise stopped if stopped

      results
    end

    # The same split Registry#execute makes one level in, so a plugin cannot
    # tell which layer caught it: a Failure's message is the whole story and
    # renders alone, while any other exception keeps its class name, because
    # a crash's class is diagnostics rather than noise.
    def guarded_call(ctx, sid, tc)
      execute_call(ctx, sid, tc)
    rescue Tools::Failure => e
      Tools::Result.new(id: tc.id, content: nil, error: e.message)
    rescue StandardError => e
      Tools::Result.new(id: tc.id, content: nil, error: "#{e.class}: #{e.message}")
    end

    def log_call(sessions, sid, tc)
      sessions.append(sid, "tool/call", { id: tc.id, name: tc.name, args: tc.args })
    end

    def execute_call(ctx, sid, tc)
      ctx[:tools].execute(
        Tools::Call.new(id: tc.id, name: tc.name, args: tc.args, session_id: sid),
        ctx: ctx
      )
    end

    def execute_and_record(ctx, sessions, sid, tc)
      result = execute_call(ctx, sid, tc)
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
        if token && (redacted?(tc.name, token) || redacted?(tc.args, token))
          sessions.append(sid, "tool/result",
                          { id: tc.id, content: nil,
                            error: "#{tc.name} was not replayed on resume: the session log " \
                                   "redacted part of this call, so the recorded call is not " \
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
