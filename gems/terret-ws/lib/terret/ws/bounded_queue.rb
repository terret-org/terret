# frozen_string_literal: true

require "async/notification"

module Terret
  module WS
    # Outbound frame queue: non-blocking producer, waiting consumer. push
    # returns false when full instead of blocking, because the producer is
    # session/event dispatch and a slow socket must never stall the agent
    # loop (plan §9.3).
    class BoundedQueue
      def initialize(limit)
        @limit = limit
        @items = []
        @closed = false
        @waiting = Async::Notification.new
        @space = Async::Notification.new
      end

      def push(item)
        return false if @closed || @items.size >= @limit

        @items << item
        @waiting.signal
        true
      end

      # Blocking push for the connection's own replay fiber: waits for the
      # writer to drain instead of dropping. Dispatch-path pushes must stay
      # non-blocking — only replay may use this. False when closed.
      def wait_push(item)
        loop do
          return false if @closed
          return true if push(item)

          @space.wait
        end
      end

      # Blocks until an item arrives or the queue closes; nil means
      # closed-and-drained.
      def pop
        loop do
          unless @items.empty?
            item = @items.shift
            @space.signal
            return item
          end
          return nil if @closed

          @waiting.wait
        end
      end

      def clear = @items.clear

      def closed? = @closed

      def close
        @closed = true
        @waiting.signal
        @space.signal
      end
    end
  end
end
