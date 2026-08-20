# frozen_string_literal: true

require "async/notification"

module Terret
  module ACP
    # Outbound frame queue: non-blocking producer, waiting consumer — the same
    # shape terret-ws uses (ws/bounded_queue.rb), and for the same reason. The
    # producer is `session/event` dispatch, which `Sessions#fan_out` runs
    # SYNCHRONOUSLY inside its drainer: if the write to a slow editor's pipe
    # parked there, every agent's event dispatch in the whole process would
    # stall behind it (co-mounted ws clients, the titler, the compactor) and the
    # emit queue would grow unbounded. So `push` returns false when full instead
    # of blocking, and a dedicated writer fiber — never the drainer — is the one
    # that may park on the pipe.
    #
    # Trimmed from ws's: no `wait_push`, because ACP has no replay path that
    # needs a blocking producer. Every ACP producer is on the dispatch side and
    # must stay non-blocking.
    class BoundedQueue
      def initialize(limit)
        @limit = limit
        @items = []
        @closed = false
        @waiting = Async::Notification.new
      end

      def push(item)
        return false if @closed || @items.size >= @limit

        @items << item
        @waiting.signal
        true
      end

      # Blocks until an item arrives or the queue closes; nil means
      # closed-and-drained.
      def pop
        loop do
          return @items.shift unless @items.empty?
          return nil if @closed

          @waiting.wait
        end
      end

      def closed? = @closed

      def close
        @closed = true
        @waiting.signal
      end
    end
  end
end
