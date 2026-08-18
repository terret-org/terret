# frozen_string_literal: true

require "json"

module Terret
  module OpenRouter
    # Accumulates parsed streaming chunks into vocabulary StreamEvents and the
    # final assistant Message. Tool-call argument fragments are gathered per
    # index; the calls close on finalize. Pure, no I/O.
    class Accumulator
      STOP_REASONS = {
        "stop" => :end_turn, "tool_calls" => :tool_use,
        "length" => :length, "error" => :error
      }.freeze

      attr_reader :error

      def initialize
        @text = +""
        @calls = {} # index => { id:, name:, args: +"" }
        @stop = nil
        @error = nil
      end

      def feed(chunk)
        if (err = chunk[:error])
          @error = LLM::StreamError.new(message: err[:message], code: err[:code])
          yield @error
        end
        if (usage = chunk[:usage])
          yield LLM::Usage.new(prompt_tokens: usage[:prompt_tokens],
                               completion_tokens: usage[:completion_tokens],
                               cost: usage[:cost])
        end
        choice = chunk[:choices]&.first or return
        @stop = choice[:finish_reason] if choice[:finish_reason]
        delta = choice[:delta] or return
        if (text = delta[:content]) && !text.empty?
          @text << text
          yield LLM::TextDelta.new(text: text)
        end
        Array(delta[:tool_calls]).each { |tc| accumulate_call(tc) }
        nil
      end

      def finalize
        parts = []
        parts << LLM::Text.new(text: @text) unless @text.empty?
        @calls.keys.sort.each do |index|
          slot = @calls[index]
          args = slot[:args].empty? ? {} : JSON.parse(slot[:args], symbolize_names: true)
          call = LLM::ToolCall.new(id: slot[:id], name: slot[:name], args: args)
          yield LLM::ToolCallEnd.new(tool_call: call)
          parts << call
        end
        yield LLM::MessageStop.new(stop_reason: STOP_REASONS.fetch(@stop, :end_turn))
        LLM::Message.new(role: :assistant, parts: parts)
      end

      private

      def accumulate_call(tc)
        slot = @calls[tc[:index]] ||= { id: nil, name: nil, args: +"" }
        slot[:id] = tc[:id] if tc[:id]
        if (fn = tc[:function])
          slot[:name] = fn[:name] if fn[:name]
          slot[:args] << fn[:arguments] if fn[:arguments]
        end
      end
    end
  end
end
