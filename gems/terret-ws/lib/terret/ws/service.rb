# frozen_string_literal: true

require "openssl"
require_relative "connection"

module Terret
  module WS
    # ctx[:ws] — the socket interface plugin. Owns bearer auth, the
    # one-connection-per-agent rule, and turn tasks. Turn tasks are rooted on
    # the server, never on a connection: a dropped client must not cancel a
    # turn (plan §9.3). In v1 the agent id names the session.
    class Service < Hames::Service
      service_key :ws
      inject :sessions, :loop, :llm

      def start(ctx)
        @ctx = ctx
        @tokens = config[:tokens] || {}
        @queue_limit = config[:queue_limit] || 256
        @heartbeat = config[:heartbeat] || 20
        @connections = {}
      end

      attr_reader :heartbeat

      # Constant-time bearer check, per agent id, before the agent exists.
      def authorized?(session_id, token)
        expected = @tokens[session_id.to_s]
        return false unless expected && token

        OpenSSL::Digest::SHA256.digest(expected.to_s) ==
          OpenSSL::Digest::SHA256.digest(token.to_s)
      end

      # Serve one client over io until it closes. runner_task owns the turn
      # tasks so they outlive the connection handler.
      def attach(session_id:, token:, io:, runner_task: Async::Task.current)
        unless authorized?(session_id, token)
          io.write(Frames.error(code: "unauthorized"))
          io.close
          return
        end

        sid = session_id.to_s
        resolve_session(sid)
        agent = @ctx[:loop].agent("agent-#{sid}") || @ctx[:loop].spawn_agent(session_id: sid)
        @connections[sid]&.shutdown(code: "superseded")
        conn = Connection.new(ctx: @ctx, agent: agent, io: io,
                              runner: runner(runner_task), queue_limit: @queue_limit)
        @connections[sid] = conn
        conn.run
      ensure
        @connections.delete(sid) if sid && @connections[sid].equal?(conn)
      end

      # Blocks serving websocket upgrades. Lazily requires the endpoint so
      # nothing needs async-websocket until something listens.
      def serve(port:, host: "127.0.0.1")
        require_relative "endpoint"
        Endpoint.new(self, host: host, port: port).run
      end

      private

      def resolve_session(sid)
        sessions = @ctx[:sessions]
        sessions.session_ids.include?(sid) ? sessions.resume(sid) : sessions.create(id: sid)
      end

      def runner(task)
        lambda do |agent, text|
          task.async do
            @ctx[:loop].run_turn(agent, text)
          rescue => e
            warn "terret-ws: turn failed for #{agent.id}: #{e.class}: #{e.message}"
          end
        end
      end
    end
  end
end
