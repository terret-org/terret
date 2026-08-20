# frozen_string_literal: true

module Terret
  module ACPTest
    # A boot-time stand-in for a real adapter: registers the FakeAdapter that
    # every other suite registers by hand after boot, so a profile composed
    # through Terret.boot can drive a scripted turn with no network. Named at
    # the top level because a plugin: is a constant resolved out of YAML.
    class ScriptedLLM < Hames::Service
      service_key :scripted_llm
      inject :llm

      SCRIPT = [{ text: "Hello from the editor." }].freeze

      def start(ctx)
        ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(SCRIPT.map(&:dup)))
      end
    end
  end
end
