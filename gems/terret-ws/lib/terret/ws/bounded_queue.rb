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

      def clear = @items.clear

      def close
        @closed = true
        @waiting.signal
      end
    end
  end
end
