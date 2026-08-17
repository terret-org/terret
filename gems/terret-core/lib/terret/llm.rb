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
    MessageStop = Data.define(:stop_reason) # :end_turn | :tool_use

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
    # Script: array of hashes { text:, tool_calls: [ToolCall, ...] }.
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
        yield MessageStop.new(stop_reason: calls.empty? ? :end_turn : :tool_use)
        Message.new(role: :assistant, parts: parts)
      end
    end
  end
end
