# frozen_string_literal: true

module Terret
  # The `trt` command line interface.
  #
  # Not implemented yet. The CLI is M4 work in docs/terret-implementation-plan.md
  # and it needs a real model adapter to drive, which is M2 work still outstanding.
  # This gem exists so that the `terret` name belongs to the project that will
  # fill it. Everything that currently works lives in terret-core and hames.
  module CLI
    VERSION = "0.0.1"

    def self.start(_argv = ARGV)
      abort <<~MSG
        terret: the trt CLI does not exist yet.

        What works today is the library. See https://terret.org
      MSG
    end
  end
end
