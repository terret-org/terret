# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

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

    # JSONL provider: one file per session, one JSON envelope per line, made
    # for grepping. at carries microseconds so Time round-trips exactly.
    class JSONL < Hames::Service
      service_key :session_store

      def start(_ctx)
        @dir ||= config.fetch(:dir).tap { |d| FileUtils.mkdir_p(d) }
      end

      def append(event)
        File.open(path(event.session_id), "a") do |f|
          f.puts JSON.generate(
            id: event.id, session_id: event.session_id, seq: event.seq,
            at: event.at.iso8601(6), type: event.type, payload: event.payload
          )
        end
      end

      def read(session_id, from_seq: 0)
        return [] unless File.exist?(path(session_id))

        File.foreach(path(session_id)).filter_map do |line|
          h = begin
            JSON.parse(line, symbolize_names: true)
          rescue JSON::ParserError
            next # a torn line (crash mid-write) loses itself, not the session
          end
          next if h[:seq] < from_seq

          SessionEvent.new(id: h[:id], session_id: h[:session_id], seq: h[:seq],
                           at: Time.iso8601(h[:at]), type: h[:type], payload: h[:payload])
        end
      end

      def session_ids
        Dir[File.join(@dir, "*.jsonl")].map { |f| File.basename(f, ".jsonl") }
      end

      private

      def path(session_id) = File.join(@dir, "#{session_id}.jsonl")
    end
  end
end
