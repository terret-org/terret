# frozen_string_literal: true

require "json"
require "time"

module Terret
  module WS
    # Wire codec for docs/protocol.md. Server frames are durable session
    # events serialized as-is, plus hello and error; client frames are the
    # closed §9.2 set. Anything else is BadFrame.
    module Frames
      class BadFrame < StandardError; end

      PROTO = 1

      # required keys per client frame type
      CLIENT = {
        "subscribe" => [:from_seq],
        "inject"    => [:text],
        "cancel"    => [],
        "approve"   => [:call_id],
        "deny"      => [:call_id],
        "set_model" => %i[role model]
      }.freeze

      module_function

      def decode(text)
        h = begin
          JSON.parse(text, symbolize_names: true)
        rescue JSON::ParserError
          raise BadFrame, "frame is not valid JSON"
        end
        raise BadFrame, "frame is not an object" unless h.is_a?(Hash)

        required = CLIENT[h[:type]] or raise BadFrame, "unknown frame type #{h[:type].inspect}"
        missing = required.reject { |k| h.key?(k) }
        raise BadFrame, "#{h[:type]} frame missing #{missing.join(', ')}" unless missing.empty?

        if h[:type] == "subscribe" && !(h[:from_seq].is_a?(Integer) && h[:from_seq] >= 0)
          raise BadFrame, "from_seq must be a non-negative integer"
        end
        # every other typed field degrades to BadFrame here, so junk can never
        # reach a seam as the wrong type and crash the read loop
        %i[text call_id role model reason].each do |k|
          next unless h.key?(k)

          raise BadFrame, "#{k} must be a string" unless h[k].is_a?(String)
        end
        if h.key?(:wake) && ![true, false].include?(h[:wake])
          raise BadFrame, "wake must be true or false"
        end

        h
      end

      def event(ev)
        JSON.generate(id: ev.id, session_id: ev.session_id, seq: ev.seq,
                      at: ev.at.iso8601(6), type: ev.type, payload: ev.payload)
      end

      def hello(session_id:, last_seq:)
        JSON.generate(type: "hello", proto: PROTO, session_id: session_id, last_seq: last_seq)
      end

      def error(code:, message: nil)
        h = { type: "error", code: code }
        h[:message] = message if message
        JSON.generate(h)
      end
    end
  end
end
