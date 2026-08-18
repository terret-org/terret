# frozen_string_literal: true

require "async"
require "async/http/server"
require "async/http/endpoint"
require "async/websocket/adapters/http"
require "protocol/http/response"
require_relative "frames"

module Terret
  module WS
    # The real transport: async-websocket bound to GET /agents/{id}/ws.
    # Everything protocol-shaped lives in Connection; this file only adapts
    # a websocket to Connection's io contract and keeps the link alive with
    # pings under load-balancer idle timeouts (plan §9.4).
    class Endpoint
      PATH = %r{\A/agents/([^/]+)/ws\z}

      def initialize(service, host:, port:)
        @service = service
        @host = host
        @port = port
      end

      def run
        Sync do |task|
          http = Async::HTTP::Endpoint.parse("http://#{@host}:#{@port}")
          app = ->(request) { upgrade(request, task) }
          Async::HTTP::Server.new(app, http).run
        end
      end

      private

      def upgrade(request, root_task)
        m = request.path.match(PATH) or
          return Protocol::HTTP::Response[404, {}, ["not found"]]

        token = bearer(request)
        response = Async::WebSocket::Adapters::HTTP.open(request) do |ws|
          io = SocketIO.new(ws)
          pinger = root_task.async do
            loop do
              sleep @service.heartbeat
              ws.send_ping("")
            end
          end
          begin
            @service.attach(session_id: m[1], token: token, io: io, runner_task: root_task)
          ensure
            pinger.stop
          end
        end
        response || Protocol::HTTP::Response[400, {}, ["websocket upgrade required"]]
      end

      def bearer(request)
        request.headers["authorization"]&.[](/\ABearer (.+)\z/i, 1)
      end

      # Adapts Async::WebSocket::Connection to Connection's io contract.
      class SocketIO
        def initialize(ws) = @ws = ws

        def read
          @ws.read&.to_str
        rescue EOFError, Errno::ECONNRESET, Protocol::WebSocket::ClosedError
          nil
        end

        def write(text)
          @ws.write(text)
          @ws.flush
        end

        def close(*) = @ws.close
      end
    end
  end
end
