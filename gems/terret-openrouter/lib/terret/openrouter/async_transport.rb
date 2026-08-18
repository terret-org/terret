# frozen_string_literal: true

require "async"
require "async/http/client"
require "async/http/endpoint"

module Terret
  module OpenRouter
    # Default transport: streams over async-http on the Fiber scheduler.
    # Sync reuses a running reactor when called from inside one and spins a
    # temporary reactor otherwise, so the adapter blocks correctly in both
    # plain Ruby and Async callers. The connection stays open only for the
    # duration of the block, which is why the contract yields rather than
    # returns: an SSE body must be consumed before the response closes.
    class AsyncTransport
      CONNECT_ERRORS = [SystemCallError, SocketError, IOError, Async::TimeoutError].freeze

      def initialize(timeout: 120)
        @timeout = timeout
      end

      def call(url:, headers:, body:)
        Sync do
          endpoint = Async::HTTP::Endpoint.parse(url, timeout: @timeout)
          client = Async::HTTP::Client.new(endpoint)
          begin
            response = begin
              client.post(endpoint.path, headers, body)
            rescue *CONNECT_ERRORS => e
              raise LLM::RetryableError, "connection failed: #{e.class}: #{e.message}"
            end
            begin
              chunks = Enumerator.new { |y| response.body&.each { |c| y << c } }
              yield response.status, chunks
            ensure
              response.close
            end
          ensure
            client.close
          end
        end
      end
    end
  end
end
