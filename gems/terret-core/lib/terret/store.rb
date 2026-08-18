# frozen_string_literal: true

module Terret
  # ctx[:session_store] — the persistence seam behind ctx.sessions. Providers
  # durably record SessionEvents (whose payloads are primitives by the append
  # contract) and hand them back exactly. Swapping the provider is a config
  # row edit; Sessions never knows which one it is talking to. start is
  # idempotent on every provider so an instance can ride across reboots.
  module Store
    # In-memory provider: the test default. Events are immutable, so sharing
    # objects with Sessions' working set costs nothing.
    class Memory < Hames::Service
      service_key :session_store

      def start(_ctx)
        @events ||= Hash.new { |h, k| h[k] = [] }
      end

      def append(event) = @events[event.session_id] << event

      def read(session_id, from_seq: 0)
        @events.fetch(session_id, []).select { |ev| ev.seq >= from_seq }
      end

      # Order is provider-defined; recency must be derived from event timestamps.
      def session_ids = @events.keys
    end
  end
end
