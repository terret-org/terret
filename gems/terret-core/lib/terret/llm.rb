# frozen_string_literal: true

module Terret
  module LLM
    # Provider-neutral vocabulary. Adapters translate these to wire formats.
    Text       = Data.define(:text)
    ToolCall   = Data.define(:id, :name, :args)
    ToolResult = Data.define(:id, :content, :error)
    Message    = Data.define(:role, :parts) do
      def tool_calls = parts.grep(ToolCall)
      def text = parts.grep(Text).map(&:text).join
    end

    Request = Data.define(:model, :system, :messages, :tools)

    # Stream events yielded by adapters.
    TextDelta   = Data.define(:text)
    ToolCallEnd = Data.define(:tool_call)
    Usage       = Data.define(:prompt_tokens, :completion_tokens, :cost)
    StreamError = Data.define(:message, :code) # surfaced mid-stream, then raised
    MessageStop = Data.define(:stop_reason) # :end_turn | :tool_use

    # Adapter failures. Retryable covers 429/overload/5xx and transport drops
    # before any bytes streamed; everything else raises through immediately.
    class AdapterError < StandardError
      attr_reader :status, :body

      def initialize(message, status: nil, body: nil)
        super(message)
        @status = status
        @body = body
      end
    end

    class RetryableError < AdapterError; end

    # Shared behaviour for real adapters: jittered exponential backoff around
    # anything raising RetryableError. Sleeper is injectable for tests.
    class AdapterBase
      def initialize(max_attempts: 4, base_delay: 0.5, sleeper: ->(s) { sleep(s) })
        @max_attempts = max_attempts
        @base_delay = base_delay
        @sleeper = sleeper
      end

      def with_retries
        attempt = 0
        begin
          yield
        rescue RetryableError
          attempt += 1
          raise if attempt >= @max_attempts

          # equal jitter: uniform over (half, full] of base * 2^n
          cap = @base_delay * (2**(attempt - 1))
          @sleeper.call(cap * (0.5 + rand * 0.5))
          retry
        end
      end
    end

    # ctx.llm — the adapter seam. `llm/stream` is a waterfall wrapping every
    # request: middleware may rewrite the request or replace the stream.
    class Service < Hames::Service
      service_key :llm

      def start(_ctx)
        @adapters = {}
        @roles    = config[:roles] || {} # :main => "fake/scripted"
      end

      def register_adapter(name, adapter)
        @adapters[name.to_s] = adapter
        -> { @adapters.delete(name.to_s) }
      end

      def resolve(role)
        spec = @roles.fetch(role) { raise KeyError, "no model role #{role.inspect}" }
        provider, model = spec.split("/", 2)
        [@adapters.fetch(provider), model]
      end

      # Streams the request through the `llm/stream` waterfall; the base of
      # the waterfall invokes the resolved adapter. Yields StreamEvents,
      # returns the final assistant Message.
      def stream(ctx, role:, request:, &on_event)
        adapter, model = resolve(role)
        req = request.with(model: model)
        ctx.waterfall("llm/stream", req) do |final_req|
          adapter.stream(final_req, &on_event)
        end
      end
    end

    # Deterministic scripted adapter for tests, demos, and record/replay.
    # Script: array of hashes { text:, tool_calls: [ToolCall, ...], usage: }.
    class FakeAdapter
      def initialize(script)
        @script = script.dup
      end

      def stream(_request)
        step = @script.shift or raise "FakeAdapter script exhausted"
        parts = []
        if (t = step[:text])
          t.chars.each_slice(8) { |chunk| yield TextDelta.new(text: chunk.join) }
          parts << Text.new(text: t)
        end
        calls = Array(step[:tool_calls])
        calls.each do |tc|
          yield ToolCallEnd.new(tool_call: tc)
          parts << tc
        end
        yield Usage.new(**step[:usage]) if step[:usage]
        yield MessageStop.new(stop_reason: calls.empty? ? :end_turn : :tool_use)
        Message.new(role: :assistant, parts: parts)
      end
    end
  end
end
