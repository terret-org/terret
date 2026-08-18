# frozen_string_literal: true

require "json"

module Terret
  module OpenRouter
    # Pure translation between the provider-neutral vocabulary and
    # OpenRouter's OpenAI-compatible wire format. No I/O.
    module Translate
      module_function

      def request_body(request)
        body = { model: request.model, messages: wire_messages(request), stream: true }
        tools = Array(request.tools)
        body[:tools] = tools.map { |s| { type: "function", function: s } } unless tools.empty?
        body
      end

      def wire_messages(request)
        out = []
        system = request.system.to_s
        out << { role: "system", content: system } unless system.empty?
        request.messages.each { |m| out.concat(wire_message(m)) }
        out
      end

      def wire_message(message)
        case message.role
        when :user
          [{ role: "user", content: message.text }]
        when :assistant
          msg = { role: "assistant", content: message.text.empty? ? nil : message.text }
          calls = message.tool_calls
          unless calls.empty?
            msg[:tool_calls] = calls.map do |tc|
              { id: tc.id, type: "function",
                function: { name: tc.name, arguments: JSON.generate(tc.args) } }
            end
          end
          [msg]
        when :tool
          message.parts.grep(LLM::ToolResult).map do |tr|
            content = tr.error ? "Error: #{tr.error}" : tr.content.to_s
            { role: "tool", tool_call_id: tr.id, content: content }
          end
        else
          raise ArgumentError, "cannot translate message role #{message.role.inspect}"
        end
      end
    end
  end
end
