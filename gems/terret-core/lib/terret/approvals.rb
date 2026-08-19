# frozen_string_literal: true

module Terret
  module Tools
    # ctx[:approvals] — durable human-in-the-loop gating (plan §6.3, §12 M6).
    # An execute-stage middleware parks calls whose definition demands a
    # decision, appends durable approval/requested, and resumes when a
    # matching approval/resolved lands in the log (the socket's approve/deny
    # frames append exactly that). Both sides are durable, so a parked call
    # survives a process death: on resume the gate finds the recorded verdict
    # and never parks. It gates on tools/execute rather than tools/pre_execute
    # so pre_execute vetoes (the per-agent AllowList) settle a call before a
    # human is ever asked.
    class Approvals < Hames::Service
      service_key :approvals
      inject :sessions, :tools, :loop

      def start(ctx)
        @ctx = ctx
        @waiting = {} # [session_id, call_id] => Thread::Queue awaiting one verdict payload

        ctx.on("tools/execute") do |call, next_|
          gate(call, next_)
        end
        ctx.on("session/event") do |ev|
          next unless ev.type == "approval/resolved"

          @waiting.delete([ev.session_id, ev.payload[:call_id]])&.push(ev.payload)
        end
      end

      # Log-derived: requested without a matching resolved, within the OPEN
      # turn. The in-memory waiter map is never consulted — after a restart it
      # is empty while the log still knows what is owed. Nothing is pending
      # once the turn that asked has closed: a request its turn outlived was
      # settled by that turn ending, and a provider is free to reuse the call
      # id afterwards.
      def pending(session_id)
        events = open_turn(session_id)
        resolved = events.filter_map { |e| e.payload[:call_id] if e.type == "approval/resolved" }
        events.filter_map do |e|
          next unless e.type == "approval/requested"
          next if resolved.include?(e.payload[:call_id])

          e.payload[:call_id]
        end
      end

      def pending?(session_id, call_id) = pending(session_id).include?(call_id)

      # Cancel's escape hatch: deny everything parked for a session, durably.
      # Each denial is an ordinary approval/resolved append, so an in-process
      # parked fiber unparks through the same listener as a socket verdict,
      # and a restart-orphaned request settles for good.
      def deny_pending!(session_id, reason: "cancelled")
        pending(session_id).each do |call_id|
          @ctx[:sessions].append(session_id, "approval/resolved",
                                 { call_id: call_id, verdict: "denied", reason: reason })
        end
      end

      private

      def gate(call, next_)
        d = begin
          @ctx[:tools].fetch(call.name)
        rescue KeyError
          nil # vanished tool: fall through — the base renders its recoverable error
        end
        return next_.(call) unless d && requires_approval?(d)

        verdict = recorded_verdict(call) || park(call)
        if verdict[:verdict] == "approved"
          next_.(call)
        else
          reason = verdict[:reason] || "no reason given"
          Result.new(id: call.id, content: nil, error: "#{call.name} denied: #{reason}")
        end
      end

      # :always asks every time; :policy asks when the tool mutates (plan
      # §13's spirit: mutation is what needs a human under policy); :never
      # (the default) passes through.
      def requires_approval?(d)
        d.approval == :always || (d.approval == :policy && d.mutating)
      end

      # Everything appended after the last turn/start, and nothing at all once
      # that turn has closed. Approvals are per-turn state.
      def open_turn(session_id)
        events = @ctx[:sessions].fetch(session_id).events
        opened = events.rindex { |e| e.type == "turn/start" }
        return [] unless opened

        turn = events[(opened + 1)..]
        turn.any? { |e| e.type == "turn/end" } ? [] : turn
      end

      # A verdict already in the log (replay after a restart, or a decision
      # that raced ahead of execution) settles the call without parking. The
      # match is bound to content, not just to the call id: the latest request
      # in the open turn naming this id, this tool, and these args, with a
      # verdict for that id recorded after it. Provider tool call ids are not
      # contractually unique, so an id reused in a later turn — or reused
      # within one turn for a different call — must never inherit an old
      # decision.
      def recorded_verdict(call)
        events = open_turn(call.session_id)
        # Both compared in stored form, and hoisted out of the scan: a tool
        # name is content like its args (the model chooses it), so a scrubber
        # rewrites it on the way into the log and a raw comparison would never
        # match again.
        name = stored_form(call.name)
        args = stored_form(call.args)
        asked = events.rindex do |e|
          e.type == "approval/requested" && e.payload[:call_id] == call.id &&
            e.payload[:name] == name && e.payload[:args] == args
        end
        return nil unless asked

        events[(asked + 1)..].find do |e|
          e.type == "approval/resolved" && e.payload[:call_id] == call.id
        end&.payload
      rescue NonPrimitivePayload
        # A value the log refuses has no stored form to compare against — a
        # Time or some other object a plugin synthesized into args, which the
        # JSON round trip this used to do coerced silently. That is a
        # comparison this method cannot make, not a verdict it found, so it
        # answers nil and the call parks. Park re-uses a standing request where
        # there is one; with no standing request, park's own append of these
        # same args raises there instead — which is what this path has always
        # done with a value the log cannot store, and is left alone. Provider
        # args are JSON primitives, so a model's own call never reaches here.
        nil
      end

      # Args reach the log through Sessions' primitives contract (symbol keys,
      # symbols in value position stringified) AND through any registered
      # scrubber, so the comparison above is against what was really stored.
      # Asking Sessions rather than round-tripping JSON here is what keeps a
      # redacted argument from making an approved call ask a second time:
      # every rewrite the append applies has to be applied to this side too.
      def stored_form(args) = @ctx[:sessions].stored_form(args)

      def park(call)
        q = Thread::Queue.new
        key = [call.session_id, call.id]
        # waiter first, then the durable request: a verdict can never land in
        # the gap between the append's fan-out and the waiter existing
        @waiting[key] = q
        # ...and the gate's own lookup happened before that waiter existed, so
        # a verdict landing in between signalled nothing. Look again now that
        # a signal has somewhere to land, or the pop below waits forever.
        if (raced = recorded_verdict(call))
          return raced
        end

        agent = @ctx[:loop].agent_for_session(call.session_id)
        unless pending?(call.session_id, call.id) # a resume re-parks on the standing request
          @ctx[:sessions].append(call.session_id, "approval/requested",
                                 { call_id: call.id, name: call.name, args: call.args })
        end
        agent&.status = :waiting_approval
        # cooperative under the fiber scheduler (parks the fiber); blocks the
        # thread under plain minitest, where tests resolve from another thread
        q.pop
      ensure
        @waiting.delete(key)
        restore(agent, call.session_id)
      end

      # What the agent goes back to when a parked call comes out, derived from
      # the LOG rather than from the label this park overwrote.
      #
      # A parallel run can park two calls at once (docs/subagents.md §5), and
      # the fiber that unparks first must not announce a turn that is still
      # waiting on a human: the socket reads this status to decide whether a
      # cancel also has to deny_pending!, so a premature :running is a turn
      # nobody can cancel and a sibling parked forever. While anything is
      # still pending for the session, :waiting_approval stays true.
      #
      # And the restore that does happen is decided rather than left to
      # whichever assignment runs last: a cancel requested while the call was
      # parked has not stopped being true just because a verdict landed, so
      # the fiber unparks into a turn that already knows it is stopping and
      # the status says the same thing (docs/subagents.md §8).
      def restore(agent, session_id)
        return unless agent && agent.status == :waiting_approval
        return unless pending(session_id).empty?

        agent.status = agent.cancelled? ? :stopping : :running
      end
    end
  end
end
