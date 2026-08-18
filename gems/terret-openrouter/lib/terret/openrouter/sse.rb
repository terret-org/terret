# frozen_string_literal: true

module Terret
  module OpenRouter
    module SSE
      # Incremental server-sent-events parser. Fed raw transport chunks with
      # boundaries wherever the network put them; yields one data payload per
      # event (multi-line data joined per the SSE spec). Comment lines and
      # non-data fields are ignored — OpenRouter uses comments as keep-alives.
      class Parser
        def initialize
          @buffer = +""
          @data = []
        end

        def feed(chunk)
          @buffer << chunk
          while (line, rest = @buffer.split("\n", 2)) && rest
            @buffer = rest
            line.chomp!("\r")
            if line.empty?
              yield @data.join("\n") unless @data.empty?
              @data.clear
            elsif line.start_with?("data:")
              @data << line.delete_prefix("data:").sub(/\A /, "")
            end
          end
          nil
        end
      end
    end
  end
end
