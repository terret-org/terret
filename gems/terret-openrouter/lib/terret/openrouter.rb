# frozen_string_literal: true

begin
  require "terret"
rescue LoadError
  require_relative "../../../terret-core/lib/terret" # monorepo path source
end

module Terret
  # The one v1 adapter (plan §6.5): OpenRouter is OpenAI-compatible, so a
  # single implementation reaches the whole model space behind ctx.llm.
  module OpenRouter
  end
end

require_relative "openrouter/sse"
require_relative "openrouter/translate"
require_relative "openrouter/accumulator"
require_relative "openrouter/adapter"

module Terret
  module OpenRouter
    # Config-row form: mounts the adapter into ctx.llm under the "openrouter"
    # provider name. Roles then point at it: { main: "openrouter/<model>" }.
    class Plugin < Hames::Service
      inject :llm
      # transport: and sleeper: are injectable seams (tests pass callables), not
      # YAML config, so they are deliberately absent from the schema.
      config_schema api_key:      { type: String,
                                    doc: "OpenRouter key; falls back to ENV OPENROUTER_API_KEY when unset" },
                    base_url:     { type: String, default: "https://openrouter.ai/api/v1",
                                    doc: "OpenAI-compatible API base URL" },
                    referer:      { type: String, doc: "HTTP-Referer header sent with each request" },
                    title:        { type: String, doc: "X-Title header sent with each request" },
                    max_attempts: { type: Integer, default: 4, doc: "retry attempts on a retryable error" },
                    base_delay:   { type: Numeric, default: 0.5, doc: "seconds of the first retry backoff" }

      def start(ctx)
        adapter = Adapter.new(**config)
        ctx.effect { ctx[:llm].register_adapter("openrouter", adapter) }
      end
    end
  end
end
