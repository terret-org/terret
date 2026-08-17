# frozen_string_literal: true

require "securerandom"
require "digest"
require "json"

module Terret
  SessionEvent = Data.define(:id, :session_id, :seq, :at, :type, :payload)

  class LogInvariantViolation < StandardError; end

  # ctx.sessions — the append-only session log. The single source of the
  # context the model sees: derive_messages projects model history from it,
  # and a digest invariant asserts that what goes out to an adapter is
  # exactly what replaying the log yields ("model-visible means logged").
  class Sessions < Hames::Service
    service_key :sessions

    Session = Struct.new(:id, :events, :parent_id, keyword_init: true)

    def start(ctx)
      @ctx = ctx
      @store = {}
      @dir = config[:jsonl_dir] # optional persistence
    end

    def create(id: SecureRandom.hex(6), parent_id: nil)
      s = Session.new(id:, events: [], parent_id:)
      @store[id] = s
      append(id, "session/created", { parent_id: })
      s
    end

    def fetch(id) = @store.fetch(id)

    def append(session_id, type, payload = {})
      decl = Hames.event(type)
      raise Hames::ContractError, "#{type} is not a durable event" unless decl.durable

      s = fetch(session_id)
      ev = SessionEvent.new(
        id: SecureRandom.hex(8), session_id:, seq: s.events.length,
        at: Time.now.utc, type: type.to_s, payload: payload
      )
      s.events << ev
      persist(ev)
      @ctx.emit("session/event", ev)
      ev
    end

    # Project provider-neutral model history from the durable log.
    def derive_messages(session_id, upto: nil)
      events = fetch(session_id).events
      events = events.take(upto) if upto
      events.filter_map do |ev|
        case ev.type
        when "user/message", "context/injected"
          LLM::Message.new(role: :user, parts: [LLM::Text.new(text: ev.payload[:text])])
        when "assistant/message"
          LLM::Message.new(role: :assistant, parts: ev.payload[:parts])
        when "tool/result"
          LLM::Message.new(role: :tool, parts: [
            LLM::ToolResult.new(id: ev.payload[:id], content: ev.payload[:content],
                                error: ev.payload[:error])
          ])
        end
      end
    end

    # The enforcement point for "model-visible means logged": the loop calls
    # this with the message list it is about to send; a mismatch against the
    # log projection raises in dev/test.
    def assert_log_invariant!(session_id, outbound_messages)
      derived = derive_messages(session_id)
      return if digest(derived) == digest(outbound_messages)

      raise LogInvariantViolation,
            "outbound request diverges from session log projection for #{session_id}"
    end

    def fork(source_id, boundary: nil, child_id: SecureRandom.hex(6))
      src = fetch(source_id)
      child = Session.new(id: child_id, events: [], parent_id: source_id)
      @store[child_id] = child
      events = boundary ? src.events.take(boundary) : src.events.dup
      events.each { |ev| child.events << ev.with(session_id: child_id) }
      append(child_id, "session/forked", { from: source_id, boundary: boundary })
      child
    end

    private

    def digest(messages)
      Digest::SHA256.hexdigest(messages.map(&:inspect).join("\x1e"))
    end

    def persist(ev)
      return unless @dir

      File.open(File.join(@dir, "#{ev.session_id}.jsonl"), "a") do |f|
        f.puts JSON.generate(type: ev.type, seq: ev.seq, at: ev.at.iso8601,
                             payload: ev.payload.inspect)
      end
    end
  end
end
