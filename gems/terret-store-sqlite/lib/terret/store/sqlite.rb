# frozen_string_literal: true

begin
  require "terret"
rescue LoadError
  require_relative "../../../../terret-core/lib/terret" # monorepo path source
end
require "sqlite3"
require "json"
require "time"
require "fileutils"

module Terret
  module Store
    # SQLite provider: the durable default for long-lived processes. WAL for
    # concurrent readers, busy_timeout instead of hand-rolled retries, one
    # row per event keyed (session_id, seq). Appends are synchronous; the
    # per-session writer task from plan §8 is deferred until many-agent
    # load exists.
    class SQLite < Hames::Service
      service_key :session_store
      config_schema path: { type: String, required: true,
                            doc: "SQLite database file for the append-only session log" }

      SCHEMA = <<~SQL
        CREATE TABLE IF NOT EXISTS events (
          session_id TEXT NOT NULL,
          seq        INTEGER NOT NULL,
          id         TEXT NOT NULL,
          at         TEXT NOT NULL,
          type       TEXT NOT NULL,
          payload    TEXT NOT NULL,
          PRIMARY KEY (session_id, seq)
        )
      SQL

      def start(_ctx)
        @db ||= begin
          path = config.fetch(:path)
          FileUtils.mkdir_p(File.dirname(path))
          db = SQLite3::Database.new(path)
          db.busy_timeout = 5_000
          db.execute("PRAGMA journal_mode=WAL")
          db.execute(SCHEMA)
          db
        end
      end

      def stop(_ctx)
        @db&.close
        @db = nil
      end

      def append(event)
        @db.execute(
          "INSERT INTO events (session_id, seq, id, at, type, payload) VALUES (?, ?, ?, ?, ?, ?)",
          [event.session_id, event.seq, event.id, event.at.iso8601(6),
           event.type, JSON.generate(event.payload)]
        )
      end

      def read(session_id, from_seq: 0)
        rows = @db.execute(
          "SELECT id, seq, at, type, payload FROM events WHERE session_id = ? AND seq >= ? ORDER BY seq",
          [session_id, from_seq]
        )
        rows.map do |id, seq, at, type, payload|
          SessionEvent.new(id:, session_id:, seq:, at: Time.iso8601(at), type: type,
                           payload: JSON.parse(payload, symbolize_names: true))
        end
      end

      def session_ids
        @db.execute("SELECT DISTINCT session_id FROM events ORDER BY session_id").flatten
      end
    end
  end
end
