# frozen_string_literal: true

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

      def initialize(ctx:, agent:, io:, runner:, queue_limit: 256)
        @ctx = ctx
        @agent = agent
        @io = io
        @runner = runner # ->(agent, text) { start a turn task owned by the server }
        @sid = agent.session_id
        @queue = BoundedQueue.new(queue_limit)
        @tail = nil
        @live = false
      end

      # Serve until the client goes away. A writer task drains the bounded
      # queue so a slow socket never blocks session/event dispatch.
      def run
        Sync do |task|
          writer = task.async do
            while (text = @queue.pop)
              @io.write(text)
            end
            @io.close
          end

          hello
          while (text = @io.read)
            dispatch(text)
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
        @queue.push(Frames.hello(session_id: @sid, last_seq: last))
      end

      def dispatch(text)
        frame = Frames.decode(text)
        case frame[:type]
        when "subscribe" then handle_subscribe(frame[:from_seq])
        when "inject" then handle_inject(frame[:text], frame.fetch(:wake, false))
        else
          raise Frames::BadFrame, "#{frame[:type]} is not supported yet"
        end
      rescue Frames::BadFrame => e
        @queue.push(Frames.error(code: "bad_frame", message: e.message))
      end

      # Replay-then-tail with no gap and no duplicate, without timing
      # assumptions: buffer live events while the replay reads, then flush
      # the buffer past the replay's last seq and go direct. The flush and
      # the mode flip are pure array work — nothing yields between them.
      def handle_subscribe(from_seq)
        @tail&.call
        @live = false
        buffered = []
        @tail = @ctx.on("session/event") do |ev|
          next unless ev.session_id == @sid

          @live ? push_event(ev) : buffered << ev
        end

        replayed = sessions.read(@sid, from_seq: from_seq)
        replayed.each { |ev| push_event(ev) }
        last = replayed.empty? ? from_seq - 1 : replayed.last.seq
        buffered.each { |ev| push_event(ev) if ev.seq > last }
        @live = true
      end

      def handle_inject(text, wake)
        if wake && @agent.status == :idle
          @runner.call(@agent, text)
        else
          @agent.inject(text)
        end
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
