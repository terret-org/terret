# frozen_string_literal: true

module Terret
  module ToolsStd
    # `job_start` / `job_collect` / `job_stop` (docs/subagents.md §6) — work
    # that outlives the tool call that started it, over ctx[:jobs]. snake_case
    # because these three have no Claude Code equivalent to be verbatim with,
    # the same rule that produced `terminal_*` in M7.
    #
    # The split in the metadata is the whole design in one table. Starting and
    # stopping put a process into the world or take one out of it, so both are
    # mutating and both are governed by policy; collecting reads a buffer and
    # asks nobody. That is what lets a delegated agent watch a job it could
    # never have started: a subagent's approval can never be answered
    # (docs/subagents.md §2), so a `:policy` call from one is denied, while
    # `job_collect` runs for anybody.
    #
    # Neither `cwd` nor `env` is a tool argument, for the reason the terminal
    # tools give: a cwd the model chose is contained by nothing, and an env it
    # writes is a place for a credential to be laundered into a child process.
    # Both stay the row's decision, where a deployment can see them.
    class Jobs < Hames::Service
      service_key :tools_std_jobs
      inject :tools, :jobs

      # The same literal Bash, WebFetch and Task separate their output with,
      # and it carries the same caveats: a readability device rather than a
      # security boundary — a job can print the line itself — whose actual
      # delivery is that the genuine remarks are always last and always
      # advisory data that nothing downstream acts on.
      LEDGER = "--- terret ---"

      # What one collect may show. The seam has its own cap
      # (Jobs::DEFAULT_MAX_OUTPUT, a mebibyte) and that one is a memory bound;
      # this is a display decision, the tool's own honest cap, exactly as
      # Bash's is.
      DEFAULT_MAX_OUTPUT = 30_000

      START_DESCRIPTION =
        "Start a shell command in the background and get back a job id. The command keeps " \
        "running after this call returns and after the turn that started it ends; read what " \
        "it has written with job_collect, and end it with job_stop. Each job is a fresh " \
        "shell, not this session's persistent bash, so a `cd` or an `export` from a Bash " \
        "call is not in effect here. A job does not survive a restart of the harness. If " \
        "this call is interrupted before its result is recorded, a resume of the turn runs " \
        "it again and starts a SECOND job — the first may still be running, with output " \
        "nobody will collect — so after a resume, use job_collect to check for two ids " \
        "where you expected one."

      COLLECT_DESCRIPTION =
        "Read whatever a job has written since the last time it was collected, and find out " \
        "whether it is still running. The output is drained: the same bytes are never " \
        "handed back twice, so keep what you are given."

      STOP_DESCRIPTION =
        "End a job: it is sent SIGTERM, then SIGKILL if it does not leave. Collect the job " \
        "once more afterwards for anything it wrote on its way out."

      def start(ctx)
        @ctx = ctx
        register_start
        register_collect
        register_stop
      end

      # max_output is read at call time, so a swapped row governs the very next
      # call; every other knob these tools reach (the job cap, the cwd) belongs
      # to the jobs row and is read there.
      def reconfigure(_config); end

      private

      # `ctx:` is passed explicitly: the registry would otherwise record the
      # frame on the context it was started in (the root), so a roster mounted
      # into a forked agent scope would leave registrations behind that outlive
      # the fork — a disposed agent with a tool of its own that can still spawn
      # processes.
      def tool(name, description, params, mutating:, approval:, concurrency:, &handler)
        @ctx[:tools].register(name: name, description: description, params: params,
                              mutating: mutating, approval: approval,
                              concurrency: concurrency, ctx: @ctx, &handler)
      end

      def object_schema(properties, required)
        { type: "object", properties: properties, required: required }
      end

      def id_property
        { type: "string", description: "The job id job_start handed back" }
      end

      def register_start
        params = object_schema(
          { command: { type: "string",
                       description: "The shell command line to run in the background" } },
          %w[command]
        )
        # `command` is required in the schema and defaulted here: a model that
        # omits it has made a mistake, and an omitted keyword would cost a
        # whole turn to an ArgumentError where a defaulted one costs a result
        # the model can read and correct.
        tool("job_start", START_DESCRIPTION, params, mutating: true, approval: :policy,
             concurrency: :serial) do |session_id:, command: nil|
          started(@ctx[:jobs].start(command!(command), session: session_id))
        end
      end

      def register_collect
        # :parallel because a collect is a read of a buffer with no ordering
        # against its siblings — watching four jobs in one message is the case
        # the barrier was declared for.
        tool("job_collect", COLLECT_DESCRIPTION, object_schema({ id: id_property }, %w[id]),
             mutating: false, approval: :never, concurrency: :parallel) do |session_id:, id: nil|
          render(@ctx[:jobs].collect(id!(id, "job_collect"), session: session_id))
        end
      end

      def register_stop
        tool("job_stop", STOP_DESCRIPTION, object_schema({ id: id_property }, %w[id]),
             mutating: true, approval: :policy, concurrency: :serial) do |session_id:, id: nil|
          stopped(@ctx[:jobs].stop(id!(id, "job_stop"), session: session_id))
        end
      end

      # Both refusals name the argument rather than the Ruby that would
      # otherwise report it. An array here is a model reaching for the
      # terminal_open convention, and stringifying it would start a job around
      # a command nobody wrote.
      def command!(command)
        return command if command.is_a?(String) && !command.strip.empty?

        raise Terret::Tools::Failure,
              "job_start needs a command: one shell command line, as a string. Nothing " \
              "was started."
      end

      def id!(id, tool)
        return id if id.is_a?(String) && !id.strip.empty?

        raise Terret::Tools::Failure,
              "#{tool} needs the job id job_start handed back, as a string"
      end

      # The ledger line is what the model will address the job by for the rest
      # of its life, so it is never omitted.
      def started(id) = "The job is running in the background.\n#{LEDGER}\njob #{id}"

      def stopped(id)
        "Stopped job #{id}.\n#{LEDGER}\ncollect it once more for anything it wrote on its way out"
      end

      def render(result)
        body, dropped = cap(scrub(result[:output]))
        remarks = remarks_for(result, body, dropped)
        "#{body.empty? ? '(no new output)' : body}\n#{LEDGER}\n#{remarks.join("\n")}"
      end

      # Unlike Bash's, the status remark is never silent. "Still running" and
      # "finished" are the two facts a collect exists to establish, and a model
      # left to infer them from an empty result will either poll a job that has
      # been over for minutes or walk away from one that has not started
      # writing yet.
      def remarks_for(result, body, dropped)
        remarks = [status_remark(result)]
        # The dropped bytes are gone, not held back: this collect drained the
        # buffer, so what did not fit the cap is not waiting for the next one.
        # Saying "truncated" without saying that invites a model to collect
        # again for the rest of a result nothing can hand it.
        if dropped.positive?
          remarks << "output truncated at max_output: kept the first #{body.bytesize} bytes " \
                     "of rendered output and dropped #{dropped} more, which are gone rather " \
                     "than waiting for the next collect"
        end
        # The seam's own cap, hit before this tool ever saw the bytes. Reported
        # separately because it is a different loss: those bytes are gone from
        # the buffer, not merely from this result.
        if result[:truncated]
          remarks << "some of the job's output was dropped before it could be collected; it " \
                     "was writing faster than the buffer's cap allows"
        end
        remarks
      end

      def status_remark(result)
        return "the job is still running" unless result[:status] == :exited
        return "the job has exited with status #{result[:exit_status]}" if result[:exit_status]

        "the job was stopped before it could report an exit status"
      end

      # Clamped rather than trusted: a row carrying a negative cap would
      # otherwise byteslice its way to nil and raise on every call, turning one
      # bad config value into a tool that never works.
      def max_output = [config[:max_output] || DEFAULT_MAX_OUTPUT, 0].max

      # A job's bytes are not guaranteed to be text. The seam preserves
      # whatever the job wrote (that is its job) and the session log refuses
      # invalid UTF-8 at the durable append boundary, so this is the layer
      # where they have to become storable.
      def scrub(output) = output.to_s.scrub

      def cap(text)
        limit = max_output
        return [text, 0] if text.bytesize <= limit

        kept = whole_characters(text.byteslice(0, limit))
        [kept, text.bytesize - kept.bytesize]
      end

      # Cutting at a byte offset can split a character in half, and those
      # halves are bytes this file manufactured — a durable append JSON-encodes
      # the payload, so a manufactured half raises a layer away from the code
      # that broke it. Belt and braces after #scrub, and kept anyway, for the
      # same reason Bash keeps its copy.
      def whole_characters(text)
        text = text.byteslice(0, text.bytesize - 1) until text.valid_encoding?
        text
      end
    end
  end
end
