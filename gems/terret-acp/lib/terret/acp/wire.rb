# frozen_string_literal: true

require "json"

module Terret
  module ACP
    # JSON-RPC 2.0 framing for ACP v1 (docs/acp.md, "Framing"). The transport
    # is newline-delimited — one JSON object per line, no LSP `Content-Length`
    # headers — so the Server reads a line and hands it here, and every frame
    # this builds is a single line: JSON.generate escapes an embedded newline
    # to `\n`, which is what keeps one frame from splitting into two.
    #
    # A codec, not a socket: it holds no IO. The Server owns the duplex pair
    # (input.gets / output.write) exactly as terret-ws's Connection owns its
    # injectable io. stdlib json only — the interface gems carry their own
    # transport deps, the kernel and this codec carry none.
    module Wire
      JSONRPC = "2.0"

      # A decoded inbound frame, already classified. `kind` is one of
      # :request, :notification, :response, :invalid, :parse_error — the
      # Server switches on it before it ever looks at `method`, so a garbage
      # line becomes an error frame instead of a crashed read loop.
      Message = Data.define(:kind, :id, :method, :params, :result, :error) do
        def request? = kind == :request
        def notification? = kind == :notification
      end

      module_function

      def request(id:, method:, params: nil)
        h = { jsonrpc: JSONRPC, id: id, method: method }
        h[:params] = params unless params.nil?
        frame(h)
      end

      def notification(method:, params: nil)
        h = { jsonrpc: JSONRPC, method: method }
        h[:params] = params unless params.nil?
        frame(h)
      end

      def response(id:, result:)
        frame(jsonrpc: JSONRPC, id: id, result: result)
      end

      def error(id:, code:, message:, data: nil)
        err = { code: code, message: message }
        err[:data] = data unless data.nil?
        frame(jsonrpc: JSONRPC, id: id, error: err)
      end

      # One line, guaranteed. JSON.generate never emits a raw newline (it
      # escapes one inside a string), so the guard is belt-and-braces against a
      # future generator swap rather than something reachable today.
      def frame(hash)
        line = JSON.generate(hash)
        raise ArgumentError, "a frame must not contain an embedded newline" if line.include?("\n")

        line
      end

      # Never raises: a malformed line from an editor gets an answer, not a
      # dropped agent. The Server maps :parse_error to -32700 and :invalid to
      # -32600. A response arriving here (we send no client requests, so we
      # expect none) is classified rather than mistaken for a request.
      def decode(line)
        parsed = begin
          JSON.parse(line, symbolize_names: true)
        rescue JSON::ParserError
          return blank(:parse_error)
        end
        return blank(:invalid) unless parsed.is_a?(Hash)

        if parsed.key?(:method)
          kind = parsed.key?(:id) ? :request : :notification
          Message.new(kind: kind, id: parsed[:id], method: parsed[:method],
                      params: parsed[:params], result: nil, error: nil)
        elsif parsed.key?(:result) || parsed.key?(:error)
          Message.new(kind: :response, id: parsed[:id], method: nil, params: nil,
                      result: parsed[:result], error: parsed[:error])
        else
          Message.new(kind: :invalid, id: parsed[:id], method: nil, params: nil,
                      result: nil, error: nil)
        end
      end

      def blank(kind)
        Message.new(kind: kind, id: nil, method: nil, params: nil, result: nil, error: nil)
      end
    end
  end
end
