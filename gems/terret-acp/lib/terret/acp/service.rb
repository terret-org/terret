# frozen_string_literal: true

require_relative "server"

module Terret
  module ACP
    # ctx[:acp] — the ACP interface plugin (docs/acp.md). Like terret-ws it is
    # an interface with no session vocabulary of its own: it mounts through the
    # loader, injects the two seams it drives, and disposes clean. The second
    # interface on a completely different transport, built out of the same
    # seams with no change to core, is what turns "the interface is not
    # privileged" (plan §9.1) from a claim into evidence.
    class Service < Hames::Service
      service_key :acp
      inject :sessions, :loop
      # ACP over stdio has no config surface — the transport is the client's
      # own stdin/stdout, auth is the process boundary (authMethods is empty),
      # and everything a turn may do is the profile's floor, not this row's.
      # An empty schema is a declaration, so doctor calls it ok rather than
      # unschema'd (docs/composition.md §9).
      config_schema({})

      def start(ctx)
        @ctx = ctx
      end

      # Serve ACP over a duplex IO pair until the input closes. stdout carries
      # ONLY ACP frames; logs go to stderr (docs/acp.md), which is where Ruby's
      # warn already writes — so a stray `puts` in a mounted plugin is the one
      # thing that corrupts this stream. The IO pair is injectable exactly like
      # the openrouter adapter's transport: tests drive it over an in-memory
      # pipe, `trt acp` passes $stdin/$stdout.
      #
      # One reactor: the read loop parks the fiber, and turn tasks root on the
      # top-level task so a disconnect never cancels a turn in flight. Blocks
      # until the input reaches EOF.
      def serve(input: $stdin, output: $stdout)
        require "async"
        Async do |task|
          Server.new(ctx: @ctx, input: input, output: output, runner_task: task).run
        end
      end
    end
  end
end
