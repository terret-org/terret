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

      # Log-derived: requested without a matching resolved. The in-memory
      # waiter map is never consulted — after a restart it is empty while the
      # log still knows what is owed.
      def pending(session_id)
        events = @ctx[:sessions].fetch(session_id).events
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

      # A verdict already in the log (replay after a restart, or a decision
      # that raced ahead of execution) settles the call without parking.
      def recorded_verdict(call)
        @ctx[:sessions].fetch(call.session_id).events.find do |e|
          e.type == "approval/resolved" && e.payload[:call_id] == call.id
        end&.payload
      end

      def park(call)
        q = Thread::Queue.new
        key = [call.session_id, call.id]
        # waiter first, then the durable request: a verdict can never land in
        # the gap between the append's fan-out and the waiter existing
        @waiting[key] = q
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
        agent.status = :running if agent && agent.status == :waiting_approval
        @waiting.delete(key)
      end
    end
  end
end
