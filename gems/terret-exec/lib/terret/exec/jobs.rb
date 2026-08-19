# frozen_string_literal: true

require "securerandom"

module Terret
  module Exec
    # No job by that id belongs to this session — either it was never started,
    # it has already been collected for the last time, or it belongs to
    # somebody else. All three are the same answer on purpose: which of them is
    # true is not information one session should be able to learn about
    # another's jobs.
    NoSuchJob = Class.new(Terret::Tools::Failure)

    # This session already holds `max_jobs`. Refused rather than quietly
    # reaping the oldest: a job is a live process an agent asked to keep
    # running, and deciding on its behalf which one it has finished with is not
    # ours to make. Stopping one, or collecting one that has finished, is the
    # caller's move.
    JobLimit = Class.new(Terret::Tools::Failure)

    # ctx[:jobs] — a subprocess that outlives the tool call that started it
    # (docs/subagents.md §6). The seam lives here rather than in terret-core
    # because it needs ctx[:subprocess] and therefore ctx[:sandbox]: a job's
    # argv goes through the wrap like every other spawn in the harness, so a
    # job in a sandboxed profile runs inside the container with everything
    # else.
    #
    # The seam a job deliberately does NOT use is ctx[:shell]: a job parked in
    # the agent's persistent bash would hold that one process for its whole
    # lifetime, and every later Bash call in the session would block behind it.
    # A command becomes a fresh `bash -lc` argv handed to ctx[:subprocess]
    # instead.
    #
    # Nothing in the log says a job exists. It survives its turn and it does
    # not survive a restart: the process that held the pid is gone, and the log
    # — the only thing that crosses a restart — was never told. Restart-
    # surviving jobs are a recorded non-goal for 0.1.
    class Jobs < Hames::Service
      service_key :jobs
      inject :subprocess
      config_schema max_jobs:   { type: Integer, default: 8, doc: "cap on concurrent background jobs" },
                    max_output: { type: Integer, default: 1 << 20,
                                  doc: "bytes of a job's output retained before truncation" },
                    cwd:        { type: String, doc: "working directory for spawned jobs (default: Dir.pwd)" },
                    env:        { type: Hash, default: {}, doc: "environment overlay for spawned jobs" }

      # The ledger row. `handle` is the live process, `buffer` is what it has
      # said that nobody has collected yet; both are mutable things this value
      # points at rather than values themselves, which is the whole difference
      # between a job and a result.
      Job = Data.define(:id, :owner, :command, :handle, :buffer)

      DEFAULT_MAX_JOBS = 8

      # What one job may hold between two collects. The same number and the
      # same reasoning as Shell::DEFAULT_MAX_OUTPUT: a command that writes
      # without pause fills this process's memory at whatever rate the pipe
      # will carry, and a job may go uncollected for minutes. It is a memory
      # bound, not a display decision, which is why the tool layer applies its
      # own smaller one on top.
      DEFAULT_MAX_OUTPUT = 1 << 20

      CHUNK = 64 * 1024

      # How often the drain fiber looks at an idle job. Slower than
      # Subprocess::POLL because nobody is waiting on this one: a capture's
      # poll bounds a caller's latency, while this bounds only how long a
      # job's own writes can sit in a pipe it is not filling.
      POLL = 0.05

      # Hames::Service#apply mounts a plugin by calling #start(ctx), and #start
      # on this seam is how a JOB is started (docs/subagents.md §6). Two fixed
      # names meet here — one the kernel's lifecycle, one a published seam
      # every job tool is written against — so mounting does exactly what the
      # base class would have done and skips the hook, rather than the seam
      # bending the signature every caller reads in the docs.
      def apply(ctx)
        ctx.register_service(self.class.service_key, self)
        @ctx = ctx
        @jobs = {} # id => Job, every session's; the owner check is what separates them
        # When the agent that owns a job is disposed, the job goes with it:
        # this is root-mounted state keyed by session, so fork disposal never
        # reaches it. Registered via ctx.on, so it reverses when the row
        # unloads.
        ctx.on("agent/disposed") { |session_id| stop_all_for(session_id) }
        self
      end

      # Every knob is read where it is used, so a hot config swap needs nothing
      # re-derived here. A running job keeps the cap its buffer was built with
      # — it is a live buffer, not a value — and the new settings govern the
      # next job.
      def reconfigure(_config); end

      # Spawns `command` and returns an opaque id for it. The command is a
      # string rather than an argv because that is what `job_start` takes, and
      # a shell line is what a model writes; the `bash -lc` below is the one
      # place that decision turns into a process.
      def start(command, session:, cwd: nil)
        owner = session.to_s
        if (count = count_for(owner)) >= max_jobs
          raise JobLimit, "#{count} jobs are already running in this session; stop one, or " \
                          "collect one that has finished, first (max_jobs: #{max_jobs})"
        end

        handle = @ctx[:subprocess].pipe_spawn(["bash", "-lc", command.to_s],
                                              cwd: cwd || default_cwd, env: env)
        job = Job.new(id: mint_id, owner: owner, command: command.to_s,
                      handle: handle, buffer: Buffer.new(max_output))
        @jobs[job.id] = job
        pump(job)
        job.id
      end

      # What the job has said since the last collect, and where it stands.
      # `status` is the PROCESS's — a job whose bash has exited while a child
      # of its own still holds the pipe reads `:exited` with output still
      # arriving, which is the honest description of that situation.
      #
      # The row is forgotten once the process is gone AND its stream has ended:
      # everything it will ever say has been handed over at that point, so
      # keeping the row would only hold a slot against the cap. A later collect
      # of the same id therefore fails closed, which is the same answer an id
      # from another session gets.
      def collect(id, session:)
        job = fetch(id, session)
        pull(job)
        output, dropped = job.buffer.drain!
        result = { status: job.handle.exited? ? :exited : :running,
                   exit_status: job.handle.exit_status,
                   output: output,
                   truncated: dropped.positive? }
        forget(job) if job.handle.exited? && job.handle.eof?
        result
      end

      # Ends the job: SIGTERM, escalating to SIGKILL after the grace, through
      # subprocess's own escalation. Whatever the job managed to say on its way
      # out is still collectible afterwards — the handle drains the last of the
      # pipe before it drops it — and the next collect reports `:exited`.
      #
      # The lifecycle hook and the seam's kill share this name. Hames calls
      # #stop(ctx) when the row unloads and docs/subagents.md §6 names this
      # method #stop(id, session:); a Context is never a job id, so the two
      # shapes cannot be confused, and the `session:` default exists for the
      # lifecycle call rather than for callers — a stop without one names no
      # session's job and fails closed like any other stranger's id.
      def stop(id, session: nil)
        return stop_all if id.is_a?(Hames::Context)

        job = fetch(id, session)
        job.handle.close
        job.id
      end

      # The agent-disposal hook: everything this session started, ended and
      # forgotten. Another session's jobs are untouched.
      def stop_all_for(session)
        owner = session.to_s
        end_each(@jobs.values.select { |job| job.owner == owner })
      end

      # Everything, every session's: the row is going away, so no job it holds
      # has an owner left to collect it.
      def stop_all = end_each(@jobs.values)

      private

      def max_jobs = config[:max_jobs] || DEFAULT_MAX_JOBS
      def max_output = config[:max_output] || DEFAULT_MAX_OUTPUT
      def default_cwd = config[:cwd] || Dir.pwd
      def env = config[:env] || {}

      def count_for(owner) = @jobs.each_value.count { |job| job.owner == owner }

      # Opaque, and unguessable with it. A job id is a handle rather than a
      # fact: a pid would tell a model something it can act on outside this
      # seam, and a counter would tell one session how many jobs another has
      # run.
      def mint_id = "job-#{SecureRandom.hex(8)}"

      def fetch(id, session)
        job = @jobs[id.to_s]
        return job if job && job.owner == session.to_s

        raise NoSuchJob, "no job #{id} is running in this session"
      end

      def forget(job)
        @jobs.delete(job.id)
        job.handle.close
      end

      # Ends a whole list of jobs, and every one of them gets its turn: a job
      # whose close cannot be completed is one job's problem, and a raise that
      # escaped here would leave every job behind it in the ledger running with
      # the agent that owned it already gone. The failures are reported once,
      # after the ledger is clear, because the caller is a disposal listener
      # rather than somebody who can act on them.
      def end_each(jobs)
        failed = []
        jobs.each do |job|
          forget(job)
        rescue StandardError => e
          failed << "#{job.id} (#{e.class}: #{e.message})"
        end
        unless failed.empty?
          warn "terret: #{failed.size} job(s) would not close: #{failed.join(', ')}"
        end
        jobs.map(&:id)
      end

      # Moves whatever the pipe holds into the buffer. Never blocks: the handle
      # reads non-blocking, so this costs one syscall against a job with
      # nothing to say.
      def pull(job)
        loop do
          chunk = job.handle.read(CHUNK)
          break if chunk.nil? || chunk.empty?

          job.buffer << chunk.b
        end
      end

      # Under a reactor, one fiber per job drains its pipe as it fills. A pipe
      # holds about 64KB before the writer blocks on it, so without this a job
      # that outruns its collector simply stops running until somebody collects
      # — which is exactly the case a job exists for.
      #
      # TRANSIENT is the whole of it, and it is about the REACTOR's lifetime
      # rather than about who waits for whom: a transient task never keeps the
      # reactor alive past the work that started it, and on shutdown it unwinds
      # with an Async::Cancel at its `sleep`. Which task it hangs off is not a
      # choice worth making — `async` re-parents to the calling task whichever
      # task it is called on (measured) — and it would not matter if it were,
      # because a parent does not wait for a transient child either. The turn
      # that called `job_start` ends while the job runs on.
      #
      # Nothing depends on it having run. #collect drains the pipe itself
      # before answering, so a deployment with no reactor sees the same output
      # in the same order from the same calls. Two things it does not see are
      # worth naming, because both look like the seam misbehaving: a job with
      # more than a pipe buffer to write between two collects is parked in
      # `write` until the next one — its side effects stop with it, because a
      # parked job is not running — and a job that finishes while nobody is
      # collecting stays an unreaped zombie until a collect, a stop, or its
      # agent's disposal notices that it went.
      def pump(job)
        task = defined?(Async::Task) ? Async::Task.current? : nil
        return unless task

        task.async(transient: true) do
          loop do
            pull(job)
            break if job.handle.exited? && job.handle.eof?

            sleep POLL
          end
        end
      end

      # Byte-capped accumulation between two collects. Past the cap the bytes
      # are counted and dropped rather than the reading stopping: a job whose
      # pipe nobody drains blocks on its next write, and a job that stopped
      # running is a worse answer than one whose output was truncated — which
      # is why `truncated:` says so instead of the loss being silent.
      #
      # The bytes stay BINARY until they are handed over. What a job wrote is
      # not guaranteed to be text, this seam preserves it either way, and
      # making it storable is the tool layer's job — the same split Shell and
      # Bash already keep.
      class Buffer
        def initialize(cap)
          @cap = [cap, 0].max
          @kept = String.new(encoding: Encoding::BINARY)
          @dropped = 0
        end

        def <<(bytes)
          room = @cap - @kept.bytesize
          if room <= 0
            @dropped += bytes.bytesize
          elsif bytes.bytesize <= room
            @kept << bytes
          else
            @kept << bytes.byteslice(0, room)
            @dropped += bytes.bytesize - room
          end
          self
        end

        # Hands over everything held and starts again, so the next collect owes
        # only what arrived after this one.
        def drain!
          kept = @kept
          dropped = @dropped
          @kept = String.new(encoding: Encoding::BINARY)
          @dropped = 0
          [kept.force_encoding(Encoding::UTF_8), dropped]
        end
      end
    end
  end
end
