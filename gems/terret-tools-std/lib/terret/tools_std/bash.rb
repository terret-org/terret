# frozen_string_literal: true

module Terret
  module ToolsStd
    # `Bash` (docs/exec.md §5) — Claude Code's name over ctx[:shell]'s
    # persistent per-session bash.
    #
    # Two things here are more than delegation. The first is approval. §13:
    # outside a sandbox an agent that can run arbitrary shell commands needs
    # a human every time; inside one the container is already the backstop
    # and Bash is governed like any other mutating tool. That verdict is
    # derived when the tool is REGISTERED and lives in a Definition nobody
    # re-reads, so a hot sandbox swap would otherwise leave a stale value in
    # front of a shell whose isolation had changed underneath it — which is
    # what the config/updated listener below exists for.
    #
    # The second is what the seam hands back. Shell::Result carries facts the
    # caller never asked for — the session restarted, output was dropped — in
    # a `notice` field of its own, precisely so stdout stays exactly what the
    # terminal carried. A tool rendering stdout alone would silently swallow
    # both, so the notice is reported below a separator, where a model can
    # tell it from something the command itself printed.
    class Bash < Hames::Service
      service_key :tools_std_bash
      inject :tools, :shell, :sandbox

      # What one result may show. The seam has its own cap
      # (Shell::DEFAULT_MAX_OUTPUT, a mebibyte) and it is a memory bound;
      # this one is a display decision, the tool's own honest cap rather than
      # policy's — a truncator listening on tools/post_execute is free to cut
      # further, and this is what the model sees when none does.
      DEFAULT_MAX_OUTPUT = 30_000

      # The line between the command's bytes and this file's remarks.
      # Everything below it is Terret talking, not the command, and it has to
      # be impossible to mistake for output at a glance.
      LEDGER = "--- terret ---"

      DESCRIPTION = "Run a command in this session's persistent bash. The same shell process " \
                    "serves every call in a session, so state persists: a `cd` or an `export` " \
                    "from one call is still in effect on the next. A command that hits its " \
                    "timeout is interrupted and its shell replaced, which resets the working " \
                    "directory and every variable — the result says so when that happens."

      def start(ctx)
        @ctx = ctx
        # One effect frame, owned by this row (start runs under the loader's
        # with_owner), disposing whichever registration is current. The
        # indirection is load-bearing: the loader emits config/updated
        # OUTSIDE with_owner, so a registration made from the listener below
        # belongs to no row at all — and an ownerless Bash would outlive the
        # row that mounted it, leaving a tool holding shell authority that
        # unloading the plugin could no longer take away.
        @ctx.effect do
          register_bash
          -> { @registration&.call }
        end

        # Which row carries the sandbox knob is not this service's business —
        # it may be the sandbox row's own config, or a provider reading
        # someone else's — so the verdict is re-derived on any row's swap
        # rather than an id being guessed, and the tool is rebuilt only when
        # the answer actually moved.
        @ctx.on("config/updated") { |_id, _config| refresh! }
      end

      # max_output is read at call time, so a swapped row governs the very
      # next call with nothing to re-derive here. The approval IS a
      # registration-time capture — the listener above, not a remount, is
      # what keeps it current.
      def reconfigure(_config); end

      private

      # `ctx:` is passed explicitly: the registry would otherwise record the
      # frame on the context it was started in (the root), so a roster
      # mounted into a forked agent scope would leave registrations behind
      # that outlive the fork — a disposed agent with a tool of its own that
      # still holds shell authority.
      def tool(name, description, params, mutating:, approval:, concurrency:, &handler)
        @ctx[:tools].register(name: name, description: description, params: params,
                              mutating: mutating, approval: approval,
                              concurrency: concurrency, ctx: @ctx, &handler)
      end

      def register_bash
        @approval = derive_approval
        params = {
          type: "object",
          properties: {
            command: { type: "string", description: "The command to run in this session's bash" },
            timeout: { type: "integer",
                       description: "Optional timeout in milliseconds; the shell session is " \
                                    "replaced if it fires" }
          },
          required: ["command"]
        }
        @registration = tool("Bash", DESCRIPTION, params, mutating: true, approval: @approval,
                             concurrency: :serial) do |command:, session_id:, timeout: nil|
          # session_id is the executing call's, handed to handlers that ask
          # for it (Tools::Registry#handler_args). It is what keeps one
          # agent's cwd and exported variables out of another's shell.
          render(@ctx[:shell].run(command, session: session_id, timeout: seconds(timeout)))
        end
      end

      # §13. The sandbox's own verdict, never a config knob of this row's:
      # an isolation claim belongs to the thing doing the isolating.
      def derive_approval = @ctx[:sandbox].isolated? ? :policy : :always

      def refresh!
        return if derive_approval == @approval

        @registration&.call
        register_bash
      end

      # Claude Code's Bash takes its timeout in milliseconds and this seam
      # takes seconds. Keeping CC's units in the argument (a model that has
      # written this call before writes milliseconds) puts the conversion
      # here, in one line, instead of leaving a units mismatch in the wild.
      def seconds(ms) = ms.nil? ? nil : ms / 1000.0

      def max_output = config[:max_output] || DEFAULT_MAX_OUTPUT

      def render(result)
        body, dropped = cap(scrub(result.stdout))
        remarks = remarks_for(result, body, dropped)
        return body.empty? ? "(no output)" : body if remarks.empty?

        # The command's own bytes are never rewritten: the newline below only
        # puts the separator on a line of its own, and output that already
        # ended in one simply gets a blank line before the ledger.
        "#{body.empty? ? '' : "#{body}\n"}#{LEDGER}\n#{remarks.join("\n")}"
      end

      def remarks_for(result, body, dropped)
        remarks = []
        # A zero status is the silent case — announcing success on every call
        # would be noise in every result a model reads. A nil status is not
        # silent by luck: the only two paths that produce one (an interrupted
        # command, a shell that ended) always carry a notice explaining it.
        remarks << "exit status #{result.status}" if result.status && !result.status.zero?
        if dropped.positive?
          remarks << "output truncated at max_output: kept the first #{body.bytesize} bytes " \
                     "and dropped #{dropped} more"
        end
        remarks << "notice: #{result.notice}" if result.notice
        remarks
      end

      # Child bytes are not guaranteed to be text. The seam preserves
      # whatever the command wrote (that is its job) and the session log
      # refuses invalid UTF-8 at the durable append boundary, so this is the
      # layer where they have to become storable — replacing what was never
      # valid rather than dropping the whole result on the floor.
      def scrub(stdout) = stdout.to_s.scrub

      def cap(text)
        limit = max_output
        return [text, 0] if text.bytesize <= limit

        kept = whole_characters(text.byteslice(0, limit))
        [kept, text.bytesize - kept.bytesize]
      end

      # Cutting at a byte offset can split a character in half, and those
      # halves are bytes this file manufactured — the child never wrote them,
      # and a durable append JSON-encodes the payload, so a manufactured half
      # raises a layer away from the code that broke it. At most three bytes
      # come back off, the longest tail a split UTF-8 character can leave.
      # Belt and braces after #scrub, and kept anyway: the same rule the seam
      # holds itself to (Shell#whole_characters), for the same reason.
      def whole_characters(text)
        text = text.byteslice(0, text.bytesize - 1) until text.valid_encoding?
        text
      end
    end
  end
end
