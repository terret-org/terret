# frozen_string_literal: true

module Terret
  module ToolsStd
    # `terminal_open` / `terminal_input` / `terminal_read` / `terminal_close`
    # (docs/exec.md §5) — the four std tools with no Claude Code equivalent,
    # over ctx[:terminals]'s named long-lived PTYs. A REPL or a dev server
    # stays addressable across a whole turn, which is the difference between
    # this seam and the one-shot spawn behind `Bash`.
    #
    # Every call passes its own session as the owner. Names are scoped per
    # owner on the seam, so that argument is the whole reason one agent
    # cannot read — or close — a live process belonging to another; a
    # constant here would quietly merge every agent's terminals into the one
    # namespace the seam was built to keep apart.
    #
    # Neither `cwd` nor `env` is a tool argument, deliberately. A terminal is
    # spawned directly rather than through ctx[:fs], so nothing would contain
    # a cwd the model chose, and an env the model writes is a place for a
    # credential to be laundered into a child process. Both stay the row's
    # decision, where a deployment can see them.
    class Terminals < Hames::Service
      service_key :tools_std_terminals
      inject :tools, :terminals

      def start(ctx)
        @ctx = ctx
        register_open
        register_input
        register_read
        register_close
      end

      # Nothing is captured from config here: every knob these tools reach
      # (the cap, the read timeout, the cwd) belongs to the terminals row and
      # is read there, at call time. Saying so beats letting the base class
      # warn that this row needs a remount when it does not.
      def reconfigure(_config); end

      private

      # `ctx:` is passed explicitly: the registry would otherwise record the
      # frame on the context it was started in (the root), so a roster
      # mounted into a forked agent scope would leave registrations behind
      # that outlive the fork — a disposed agent with a tool of its own that
      # can still spawn processes.
      def tool(name, description, params, &handler)
        @ctx[:tools].register(name: name, description: description, params: params,
                              mutating: true, approval: :policy, concurrency: :serial,
                              ctx: @ctx, &handler)
      end

      def object_schema(properties, required)
        { type: "object", properties: properties, required: required }
      end

      def name_property = { type: "string", description: "The terminal's name within this session" }

      def register_open
        params = object_schema(
          { name: name_property,
            argv: { type: "array", items: { type: "string" },
                    description: "The command and its arguments, e.g. [\"python3\", \"-i\"]" } },
          %w[name argv]
        )
        description = "Start a long-lived terminal (a PTY) that stays open across calls. No shell " \
                      "interprets the argv, so use [\"bash\", \"-lc\", \"...\"] for pipelines or " \
                      "redirection. The terminal keeps running until terminal_close."
        tool("terminal_open", description, params) do |name:, argv:, session_id:|
          open_terminal(name, Array(argv).map(&:to_s), session_id)
        end
      end

      def register_input
        params = object_schema(
          { name: name_property,
            text: { type: "string",
                    description: "Text to type; include a trailing newline to submit a line" } },
          %w[name text]
        )
        tool("terminal_input", "Type text into an open terminal. Nothing is submitted until a " \
                               "newline is sent, exactly as at a keyboard.", params) do |name:, text:, session_id:|
          @ctx[:terminals].input(name, text, session: session_id)
          "Typed #{text.to_s.bytesize} bytes into terminal #{name}"
        end
      end

      def register_read
        params = object_schema(
          { name: name_property,
            timeout: { type: "integer",
                       description: "Optional milliseconds to wait for output before giving up" } },
          %w[name]
        )
        tool("terminal_read", "Read whatever an open terminal has said since the last read. " \
                              "Returns empty-handed rather than waiting for a terminal that has " \
                              "nothing to say.", params) do |name:, session_id:, timeout: nil|
          read_terminal(name, session_id, timeout)
        end
      end

      def register_close
        tool("terminal_close", "Close a terminal and reap its process, freeing the name.",
             object_schema({ name: name_property }, %w[name])) do |name:, session_id:|
          # The seam makes closing a name that is not open a no-op, because
          # disposal runs over sets that may already be partly closed. The
          # tool says which of the two happened rather than inventing a
          # failure the seam deliberately does not raise.
          if @ctx[:terminals].close(name, session: session_id).nil?
            "No terminal named #{name} was open"
          else
            "Closed terminal #{name}"
          end
        end
      end

      # Named away from `open` and `read`: Kernel's own methods carry those
      # names, and Kernel#open runs a command when handed a string starting
      # with a pipe. A private helper that shadows it is one rename away from
      # falling through to it, in the one class where that would hand a model
      # a spawn nobody gated.
      def open_terminal(name, argv, session_id)
        terminal = @ctx[:terminals].open(name, argv, session: session_id)
        "Opened terminal #{terminal.name} (pid #{terminal.pid})"
      rescue Errno::ENOENT
        # The direct spawn path raises this for a command that is not there.
        # Left alone the pipeline would render "Errno::ENOENT: No such file
        # or directory - ..." — a sentence about Ruby's exception hierarchy
        # when what the caller got wrong is its own argv. A Failure renders
        # message-only, and the seam registered nothing, so there is no
        # half-open terminal to mention.
        raise Terret::Tools::Failure,
              "could not start #{argv.first.inspect}: no such command, or the terminal's " \
              "working directory is gone; nothing was opened"
      end

      def read_terminal(name, session_id, timeout)
        chunk = @ctx[:terminals].read(name, session: session_id,
                                            timeout: timeout.nil? ? nil : timeout / 1000.0)
        # nil is the terminal's process being gone, "" is it being alive with
        # nothing to say — two different answers, and a model that cannot
        # tell them apart will either keep polling a dead terminal or close a
        # live one. The name stays open in both cases; reading is not
        # disposal.
        return "(the terminal's process has ended; terminal_close frees the name)" if chunk.nil?
        return "(nothing to read)" if chunk.empty?

        # Same stance as Bash's: the seam preserves whatever the child wrote,
        # the session log refuses invalid UTF-8 at the durable append
        # boundary, so this is the layer that has to make it storable.
        chunk.scrub
      end
    end
  end
end
