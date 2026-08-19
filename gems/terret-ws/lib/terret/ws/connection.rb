# frozen_string_literal: true

require "async"
require "json"
require_relative "frames"
require_relative "bounded_queue"

module Terret
  module WS
    # The per-client protocol engine (docs/protocol.md). Transport is
    # injectable exactly like the openrouter adapter's: tests drive it with
    # an in-memory socket; the real endpoint adapts async-websocket to the
    # same io contract — read -> String|nil (nil on close), write(String),
    # close. One Connection serves one agent. Frames land on existing seams;
    # everything outbound is a durable session event serialized as-is.
    class Connection
      attr_reader :agent

      def initialize(ctx:, agent:, io:, runner:, resumer: ->(_agent) {}, queue_limit: 256)
        @ctx = ctx
        @agent = agent
        @io = io
        @runner = runner # ->(agent, text) { start a turn task owned by the server }
        @resumer = resumer # ->(agent) { re-enter the log's open turn, same rooting }
        @sid = agent.session_id
        @queue_limit = queue_limit
        @queue = BoundedQueue.new(queue_limit)
        @tail = nil
        @live = false
        @floor = 0
      end

      # Serve until the client goes away. A writer task drains the bounded
      # queue so a slow socket never blocks session/event dispatch.
      def run
        Sync do |task|
          writer = task.async do
            while (text = @queue.pop)
              @io.write(text)
            end
          rescue StandardError => e
            warn "terret-ws: #{@sid}: writer failed: #{e.class}: #{e.message}"
          ensure
            @io.close
          end

          hello
          while (text = @io.read)
            begin
              dispatch(text)
            rescue StandardError => e
              # docs/protocol.md: any unexpected server-side failure while
              # serving this connection surfaces as internal, then closes.
              warn "terret-ws: #{@sid}: dropping connection on dispatch error: #{e.class}: #{e.message}"
              shutdown(code: "internal")
              break
            end
          end
        ensure
          dispose
          writer&.wait
        end
      end

      # Queue an error and stop; the writer drains first so the client sees
      # why it was dropped (superseded, lagged). Idempotent: the tail is
      # disposed so later appends cannot re-enter and wipe the error frame.
      def shutdown(code:)
        @tail&.call
        @tail = nil
        return if @queue.closed?

        @queue.clear
        @queue.push(Frames.error(code: code))
        @queue.close
      end

      private

      def sessions = @ctx[:sessions]

      # Precondition: the session is resolved (Sessions#create/resume) before
      # a Connection is built — fetch here never sees an unknown sid.
      def hello
        last = sessions.fetch(@sid).events.last&.seq || -1
        push_frame(Frames.hello(session_id: @sid, last_seq: last))
      end

      def dispatch(text)
        frame = Frames.decode(text)
        case frame[:type]
        when "subscribe" then handle_subscribe(frame[:from_seq])
        when "inject" then handle_inject(frame[:text], frame.fetch(:wake, false))
        when "cancel" then handle_cancel(frame[:reason])
        when "approve" then handle_resolution(frame[:call_id], "approved", nil)
        when "deny"    then handle_resolution(frame[:call_id], "denied", frame[:reason])
        when "set_model" then handle_set_model(frame[:role], frame[:model])
        when "set_policy" then handle_set_policy(frame[:patterns])
        else
          raise Frames::BadFrame, "#{frame[:type]} is not supported yet"
        end
      rescue Frames::BadFrame => e
        push_frame(Frames.error(code: "bad_frame", message: e.message))
      end

      # A client that can't even take protocol frames is gone.
      def push_frame(text)
        return if @queue.push(text)

        shutdown(code: "lagged")
      end

      # Replay-then-tail with no gap and no duplicate. Live events buffer
      # while the replay reads and flushes; the flush loops until it drains
      # because wait_push yields, and the final empty-check-to-flip is pure
      # array work — nothing can slip between them on one reactor.
      def handle_subscribe(from_seq)
        @tail&.call
        @live = false
        @floor = from_seq
        buffered = []
        @tail = @ctx.on("session/event") do |ev|
          next unless ev.session_id == @sid && ev.seq >= @floor

          if @live
            push_event(ev)
          elsif buffered.size >= @queue_limit
            # too far behind before the tail even started
            shutdown(code: "lagged")
          else
            buffered << ev
          end
        rescue StandardError => e
          # a socket-side failure must never surface into Sessions#append
          warn "terret-ws: #{@sid}: dropping connection on listener error: #{e.class}: #{e.message}"
          shutdown(code: "internal")
        end

        replayed = sessions.read(@sid, from_seq: from_seq)
        return unless replay(replayed)

        last = replayed.empty? ? from_seq - 1 : replayed.last.seq
        until buffered.empty?
          batch = buffered.select { |ev| ev.seq > last }
          buffered.clear
          return unless replay(batch)

          last = batch.last.seq unless batch.empty?
        end
        @live = true
      end

      # Replay runs in the connection's own fiber, so it waits for the writer
      # to drain instead of dropping the client — a long log must never look
      # like a slow reader. False when the queue closed mid-replay.
      def replay(events)
        events.each { |ev| return false unless @queue.wait_push(Frames.event(ev)) }
        true
      end

      # A wake on an idle agent whose log holds an open turn resumes that
      # turn — the text rides its next step as context/injected — instead of
      # starting a new one. That is the autonomous restart story: after a
      # deploy, the first stimulus picks the turn back up.
      def handle_inject(text, wake)
        if wake && @agent.status == :idle && @ctx[:loop].resumable?(@sid)
          @agent.inject(text)
          @resumer.call(@agent)
        elsif wake && @agent.status == :idle
          @runner.call(@agent, text)
        else
          @agent.inject(text)
        end
      end

      def handle_cancel(reason)
        case @agent.status
        when :running
          @agent.cancel(reason)
        when :waiting_approval
          # cancel first, THEN deny: the parked fiber unparks into a turn
          # that already knows it is cancelled; each denial is durable
          @agent.cancel(reason)
          @ctx[:approvals].deny_pending!(@sid, reason: reason || "cancelled")
        else
          push_frame(Frames.error(code: "not_running"))
        end
      end

      # call_id is deliberately not id: it is a foreign key to the tool/call
      # event's id, and the wire-facing name in docs/protocol.md.
      #
      # Approvals are an opt-in row: without it, approve/deny is unsupported.
      # With it, only a call with a standing approval/requested (and no
      # verdict yet) accepts one — anything else answers stale_call and
      # appends nothing, so a double approve or a typo cannot pollute the
      # log. A verdict landing for an idle agent whose turn is still open in
      # the log means no fiber is parked (the process restarted since it
      # parked) — resume the turn.
      def handle_resolution(call_id, verdict, reason)
        unless @ctx.service?(:approvals)
          return push_frame(Frames.error(code: "unsupported",
                                         message: "no approvals service is mounted"))
        end
        unless @ctx[:approvals].pending?(@sid, call_id)
          return push_frame(Frames.error(code: "stale_call",
                                         message: "#{call_id} has no pending approval"))
        end

        payload = { call_id: call_id, verdict: verdict }
        payload[:reason] = reason if reason
        sessions.append(@sid, "approval/resolved", payload)
        @resumer.call(@agent) if @agent.status == :idle && @ctx[:loop].resumable?(@sid)
      end

      def handle_set_model(role, model)
        @ctx[:llm].set_role(role, model)
      rescue ArgumentError => e
        push_frame(Frames.error(code: "bad_frame", message: e.message))
      end

      def handle_set_policy(patterns)
        unless patterns.is_a?(Array) && patterns.all? { |p| p.is_a?(String) }
          return push_frame(Frames.error(code: "bad_frame",
                                         message: "patterns must be an array of strings"))
        end

        Tools::AllowList.update(@ctx, @sid, patterns)
      end

      def push_event(ev)
        return if @queue.push(Frames.event(ev))

        # the client fell too far behind: drop it rather than stall the loop
        shutdown(code: "lagged")
      end

      def dispose
        @tail&.call
        @tail = nil
        @queue.close
      end
    end
  end
end
