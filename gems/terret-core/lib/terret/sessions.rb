# frozen_string_literal: true

require "securerandom"
require "digest"
require "json"

module Terret
  SessionEvent = Data.define(:id, :session_id, :seq, :at, :type, :payload)

  class LogInvariantViolation < StandardError; end
  class NonPrimitivePayload < StandardError; end

  # ctx.sessions — the append-only session log. The single source of the
  # context the model sees: derive_messages projects model history from it,
  # and a digest invariant asserts that what goes out to an adapter is
  # exactly what replaying the log yields ("model-visible means logged").
  class Sessions < Hames::Service
    service_key :sessions
    inject :session_store

    Session = Struct.new(:id, :events, :parent_id, keyword_init: true)

    def start(ctx)
      @ctx = ctx
      @store = ctx[:session_store]
      @cache = {}
    end

    def create(id: SecureRandom.hex(6), parent_id: nil)
      s = Session.new(id:, events: [], parent_id:)
      @cache[id] = s
      append(id, "session/created", { parent_id: })
      s
    end

    def fetch(id) = @cache.fetch(id)

    def append(session_id, type, payload = {})
      decl = Hames.event(type)
      raise Hames::ContractError, "#{type} is not a durable event" unless decl.durable

      s = fetch(session_id)
      ev = SessionEvent.new(
        id: SecureRandom.hex(8), session_id:, seq: s.events.length,
        at: Time.now.utc, type: type.to_s, payload: normalize_payload(payload)
      )
      s.events << ev
      @store.append(ev)
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
          LLM::Message.new(role: :assistant,
                           parts: ev.payload[:parts].map { |p| LLM.decode_part(p) })
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
      @cache[child_id] = child
      events = boundary ? src.events.take(boundary) : src.events.dup
      events.each do |ev|
        copy = ev.with(session_id: child_id)
        child.events << copy
        @store.append(copy)
      end
      append(child_id, "session/forked", { from: source_id, boundary: boundary })
      child
    end

    def read(session_id, from_seq: 0) = @store.read(session_id, from_seq: from_seq)

    def session_ids = @store.session_ids

    private

    # The primitives contract: durable payloads hold only strings, numbers,
    # booleans, nil, arrays, and symbol-keyed hashes of the same. Symbols in
    # value position become strings; string keys become symbols. Anything
    # else raises — typed objects are encoded at the edges (LLM.encode_part).
    def normalize_payload(value)
      case value
      when String, Integer, true, false, nil then value
      when Float
        raise NonPrimitivePayload, "non-finite Float is not storable" unless value.finite?

        value
      when Symbol then value.to_s
      when Array then value.map { |v| normalize_payload(v) }
      when Hash
        value.each_with_object({}) do |(k, v), out|
          key = case k
                when Symbol then k
                when String then k.to_sym
                else raise NonPrimitivePayload, "#{k.class} is not a storable hash key"
                end
          raise NonPrimitivePayload, "duplicate key #{key.inspect} after coercion" if out.key?(key)

          out[key] = normalize_payload(v)
        end
      else
        raise NonPrimitivePayload, "#{value.class} is not storable; encode it first"
      end
    end

    def digest(messages)
      Digest::SHA256.hexdigest(messages.map(&:inspect).join("\x1e"))
    end
  end
end
