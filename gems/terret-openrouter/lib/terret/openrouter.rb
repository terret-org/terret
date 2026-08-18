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

      def start(ctx)
        adapter = Adapter.new(**config)
        ctx.effect { ctx[:llm].register_adapter("openrouter", adapter) }
      end
    end
  end
end
