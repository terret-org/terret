# frozen_string_literal: true

require "pty"

module Terret
  module Exec
    # ctx[:subprocess] — the only place in Terret where an argv becomes a real
    # process (plan §6.6; docs/exec.md §2). Two shapes: #spawn captures a
    # one-shot command, #pty_spawn hands back a live terminal for
    # ctx[:shell]/ctx[:terminals] to keep.
    #
    # Everything here is built to park the FIBER rather than the thread. One
    # reactor, no user-facing threads (plan §8) means a call that blocked the
    # thread would stall every other agent in the process on the first slow
    # child, so the capture loop polls with non-blocking IO plus
    # `Process.wait(WNOHANG)` and a `sleep` — all of which cooperate with the
    # scheduler, verified on this Ruby. `Open3.capture3` was the obvious
    # alternative and is rejected for two reasons: it spawns reader threads
    # per call (measured: three extra threads while one capture runs), and it
    # has no notion of a deadline, so cancellation would have to be bolted on
    # from outside the call it is meant to bound.
    class Subprocess < Hames::Service
      service_key :subprocess
      inject :sandbox

      # A capture that never exited on its own carries `status: nil` — an
      # exit code we do not have is not reported as one — with what it managed
      # to say before it was cancelled, and why, on stderr.
      Result = Data.define(:status, :stdout, :stderr)

      POLL = 0.01
      CHUNK = 64 * 1024

      def start(ctx)
        @ctx = ctx
      end

      # Runs argv to completion (or to `timeout:`) and captures both streams.
      # `env` merges into the inherited environment, `stdin` is written to the
      # child and then closed, and a non-zero exit is a Result like any other
      # rather than an exception — the caller asked to run a command, and a
      # command that failed still ran.
      def spawn(argv, cwd: Dir.pwd, env: {}, stdin: nil, timeout: nil)
        # The §6.6 contract: every argv passes ctx[:sandbox].wrap before it
        # becomes a process. This call site, and its twin in #pty_spawn, are
        # the reason one config row swapping the sandbox provider moves every
        # spawn in the harness inside a container without touching a tool.
        argv = @ctx[:sandbox].wrap(argv, cwd: cwd)

        in_r, in_w = IO.pipe
        out_r, out_w = IO.pipe
        err_r, err_w = IO.pipe
        begin
          pid = Process.spawn(stringify(env), *exec_form(argv),
                              chdir: cwd, in: in_r, out: out_w, err: err_w)
          [in_r, out_w, err_w].each { |io| close!(io) }
          capture(pid, in_w, out_r, err_r, stdin, timeout)
        ensure
          [in_r, in_w, out_r, out_w, err_r, err_w].each { |io| close!(io) }
        end
      end

      # A live terminal. The handle is deliberately small — read, write, pid,
      # close — because ctx[:terminals] holds these across turns and every
      # method on it is something a tool call can end up driving.
      def pty_spawn(argv, cwd: Dir.pwd, env: {})
        # The §6.6 contract; see #spawn. `tty: true` is this path declaring
        # what it is: a caller reaching for a pty wants terminal semantics on
        # the far side of the sandbox as well, and a provider that can arrange
        # one (docker, via `-t`) has to be told. Without it a container hands
        # bash a pipe while the host pty carries on echoing, and the echoed
        # request line — session sentinel and all — lands in what ctx[:shell]
        # reads back as the command's own output. The bit rides this path
        # only: `docker exec -i -t` against pipe stdin fails outright, so
        # #spawn must never ask for it.
        argv = @ctx[:sandbox].wrap(argv, cwd: cwd, tty: true)
        reader, writer, pid = PTY.spawn(stringify(env), *exec_form(argv), chdir: cwd)
        writer.sync = true
        PTYHandle.new(reader: reader, writer: writer, pid: pid,
                      reaper: method(:reap!), grace: term_grace)
      end

      # A process the caller does not wait for. #spawn captures to completion
      # and #pty_spawn hands back a terminal; this hands back a plain pipe and
      # a pid, which is what ctx[:jobs] needs and neither of the others can be
      # (docs/subagents.md §6). A job's whole point is output read while it is
      # still running, so a capture loop is the wrong shape — and a pty is the
      # wrong shape too, because a terminal rewrites the newlines of anything
      # written through it (the CR-LF ctx[:shell] spends a `stty -onlcr` on)
      # and there is nobody to run an stty in a buffer.
      def pipe_spawn(argv, cwd: Dir.pwd, env: {})
        # The §6.6 contract; see #spawn. No `tty:` — a job is not a terminal.
        argv = @ctx[:sandbox].wrap(argv, cwd: cwd)

        out_r, out_w = IO.pipe
        begin
          # One pipe for both streams, the way a terminal has one: a job's
          # diagnostics are part of what it said, and a second pipe would need
          # a second drain to stay deadlock-free for output that renders as a
          # single stream anyway. stdin is /dev/null rather than inherited, so
          # a background job that reads it sees EOF instead of racing the
          # harness for the console. `pgroup: true` makes the child a process
          # group leader, which is what lets the handle's close reach whatever
          # the job spawned rather than only the job (the same reasoning as
          # Shell#sweep: a surviving background child holds the agent's
          # authority with nothing left in the harness able to name it).
          pid = Process.spawn(stringify(env), *exec_form(argv), chdir: cwd,
                              in: File::NULL, out: out_w, err: out_w, pgroup: true)
        rescue StandardError
          close!(out_r)
          raise
        ensure
          close!(out_w)
        end
        PipeHandle.new(reader: out_r, pid: pid, reaper: method(:reap!), grace: term_grace)
      end

      private

      def term_grace = config[:term_grace] || 2

      def capture(pid, in_w, out_r, err_r, stdin, timeout)
        out = String.new(encoding: Encoding::BINARY)
        err = String.new(encoding: Encoding::BINARY)
        pending = stdin.nil? ? nil : String.new(stdin.to_s, encoding: Encoding::BINARY)
        close!(in_w) if pending.nil?

        deadline = timeout && monotonic + timeout
        status = nil
        ended = nil

        loop do
          pending = feed(in_w, pending)
          drain(out_r, out)
          drain(err_r, err)

          if (reaped = Process.wait2(pid, Process::WNOHANG))
            status = reaped.last.exitstatus
            break
          end

          if deadline && monotonic >= deadline
            ended = reap!(pid, term_grace)
            break
          end

          sleep POLL
        end

        # The child's ends of the pipes are closed now it is reaped, so one
        # more non-blocking pass collects whatever is still buffered. Reading
        # to EOF instead would hang on a grandchild that inherited the pipe
        # and outlived its parent.
        drain(out_r, out)
        drain(err_r, err)
        note!(err, timeout, ended) if ended

        Result.new(status: status, stdout: text(out), stderr: text(err))
      end

      # TERM, then KILL if the child is still there after the grace, then reap
      # it. One escalation policy, shared by the spawn timeout and terminal
      # close so the two cannot drift apart. Which signal actually ended the
      # child is returned rather than swallowed: a caller reading a timed-out
      # result deserves to know the process ignored the polite request.
      def reap!(pid, grace)
        signal(pid, "TERM")
        deadline = monotonic + grace
        loop do
          return :terminated if Process.wait2(pid, Process::WNOHANG)
          break if monotonic >= deadline

          sleep POLL
        end
        signal(pid, "KILL")
        Process.wait2(pid)
        :killed
      rescue Errno::ECHILD
        # already reaped elsewhere; nothing left to end
        :terminated
      end

      def note!(err, timeout, ended)
        err << "\n" unless err.empty? || err.end_with?("\n")
        err << if ended == :killed
                 "terret: timed out after #{timeout}s; sent SIGTERM, then SIGKILL after a #{term_grace}s grace\n"
               else
                 "terret: timed out after #{timeout}s; sent SIGTERM\n"
               end
      end

      # A child that has already exited but is not yet reaped is not an error
      # here — the next wait collects it. Neither is EPERM, and that one is not
      # a permission problem: this seam signals process GROUPS as well as pids
      # (PipeHandle hands the reaper a `-pgid`), and Darwin answers EPERM
      # rather than ESRCH for a group whose every remaining member is a zombie
      # — which is exactly the state of a job that finished on its own and was
      # never collected. Both errnos mean the same thing at this call site:
      # nobody signalable of ours is left. The one case EPERM could hide is a
      # live process under another uid, which no signal of ours could have
      # ended anyway. Shell#sweep rescues the pair for the same reason.
      def signal(pid, name)
        Process.kill(name, pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      # Non-blocking, so a stdin payload larger than the pipe buffer cannot
      # wedge the caller before the deadline loop starts checking it: whatever
      # does not fit this pass is carried to the next. Returns the bytes still
      # owed, or nil once the child's stdin is closed.
      def feed(io, pending)
        return nil if pending.nil?

        if pending.empty?
          close!(io)
          return nil
        end

        written = io.write_nonblock(pending, exception: false)
        return pending if written == :wait_writable

        pending.byteslice(written..)
      rescue Errno::EPIPE, IOError
        close!(io)
        nil
      end

      # Both streams every pass, never one to EOF: reading stdout to the end
      # while stderr fills its pipe buffer is the classic capture deadlock.
      def drain(io, buf)
        return if io.closed?

        loop do
          chunk = io.read_nonblock(CHUNK, exception: false)
          return close!(io) if chunk.nil? # EOF
          return if chunk == :wait_readable

          buf << chunk
        end
      rescue IOError
        nil
      end

      # [cmd, argv0] forces the exec form even for a one-element argv, so a
      # bare ["ls -la"] is a command named "ls -la" that fails to exec rather
      # than a shell line. Nothing on this seam acquires a shell by accident;
      # ctx[:shell] asks for one explicitly.
      def exec_form(argv) = [[argv[0], argv[0]], *argv[1..]]

      # Process.spawn's env hash merges into the inherited environment (only
      # `unsetenv_others:` replaces it), which is what a caller passing one or
      # two variables means.
      def stringify(env) = (env || {}).to_h { |k, v| [k.to_s, v&.to_s] }

      # Pipe bytes arrive as BINARY; everything downstream of this seam — tool
      # results, the session log — is text. Forced rather than encoded so a
      # child emitting invalid UTF-8 still round-trips its bytes instead of
      # raising here.
      def text(buf) = buf.force_encoding(Encoding::UTF_8)

      def close!(io)
        io.close unless io.nil? || io.closed?
      rescue IOError
        nil
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # What a caller holds for a live terminal: the pty master on one side,
      # the child on the other. These outlive a single tool call by design, so
      # #close both drops the fds and ends the child rather than leaving it to
      # the process's own exit.
      class PTYHandle
        attr_reader :pid

        def initialize(reader:, writer:, pid:, reaper:, grace:)
          @reader = reader
          @writer = writer
          @pid = pid
          @reaper = reaper
          @grace = grace
          @closed = false
        end

        # Without a timeout this blocks until the child says something,
        # parking the fiber. With one it polls to the deadline and returns ""
        # empty-handed, which is what a tool call reading a terminal that has
        # nothing to say needs — the blocking form would hold the turn open
        # forever on an idle terminal. nil means end of stream: on a pty
        # master a dead child surfaces as EIO rather than a clean EOF.
        def read(max = 4096, timeout: nil)
          return nil if @reader.closed?
          return decode(@reader.readpartial(max)) if timeout.nil?

          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          loop do
            chunk = @reader.read_nonblock(max, exception: false)
            return nil if chunk.nil?
            return decode(chunk) unless chunk == :wait_readable
            return "" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep POLL
          end
        rescue Errno::EIO, EOFError, IOError
          nil
        end

        def write(str) = @writer.write(str)

        # Whether the child is still running, probed with a non-blocking wait.
        # Write failure cannot be the only tell: macOS raises EIO writing to a
        # master whose child died, but Linux queues the bytes into a pty no
        # one will ever read and reports nothing — so a caller refusing input
        # to a dead terminal has to ask the process table, not the fd. The
        # probe reaps the child when it finds one exited; the status is kept
        # so #close skips its own wait instead of hunting a pid that is gone
        # (reap! tolerates that too, but not re-signaling a reaped pid is
        # better than tolerating it).
        def alive?
          return false if @closed || @exited

          if Process.wait2(@pid, Process::WNOHANG)
            @exited = true
            false
          else
            true
          end
        rescue Errno::ECHILD
          @exited = true
          false
        end

        # Idempotent: a terminal explicitly closed and then closed again by
        # its owner's disposal must not raise, and must not wait on a child
        # that is already reaped.
        #
        # The fds are dropped BEFORE the child is reaped, and that order is
        # load-bearing rather than tidy. A child SIGKILLed while its terminal
        # still holds bytes nobody read can stick in exit — measured on macOS
        # with a shell and as little as a startup banner pending, the process
        # sits in `E` state and the blocking wait that reaps it never returns.
        # There is no rescuing that from inside the reactor either: the fiber
        # parks in the scheduler's own process_wait hook, where its timers
        # never get to preempt it, so one terminal closed in the wrong order
        # takes every agent in the process with it. Closing the master first
        # discards the pending output and hangs the child up, which also
        # spares an interactive shell — one that ignores SIGTERM by design —
        # the whole grace period it would otherwise sit out before the SIGKILL.
        def close
          return @ended if @closed

          @closed = true
          [@writer, @reader].each do |io|
            io.close unless io.closed?
          rescue IOError
            nil
          end
          @ended = @exited ? :terminated : @reaper.call(@pid, @grace)
        end

        private

        def decode(bytes) = bytes.force_encoding(Encoding::UTF_8)
      end

      # What a caller holds for a process it started and did not wait for. The
      # surface is deliberately as small as PTYHandle's — read, status, close —
      # because ctx[:jobs] keeps these across turns and every method on one is
      # something a tool call can end up driving.
      class PipeHandle
        attr_reader :pid

        # What one close may hold. The grace #end_group spends is a window the
        # job goes on writing into, and a job that ignores TERM writes into all
        # of it: draining that with nothing bounding it held 952MB at the
        # default two-second grace, measured, to hand back output the owner's
        # own buffer caps at a mebibyte. The bound being protected is the HOST
        # PROCESS's — a handle cannot see ctx[:jobs]' cap, every agent on the
        # box shares the memory an OOM would take, and this sits comfortably
        # above that mebibyte so the cap that shapes a result stays the owner's.
        #
        # Past it the bytes are read and DISCARDED rather than the reading
        # stopping, which is the trade Jobs::Buffer makes for the same reason:
        # a reader that stops blocks the writer on its next write, and a job
        # frozen inside its own grace period is a worse answer than a job whose
        # last words were cut short.
        MAX_PENDING = 2 << 20

        def initialize(reader:, pid:, reaper:, grace:)
          @reader = reader
          @pid = pid
          @reaper = reaper
          @grace = grace
          @eof = false
          @exited = false
          @status = nil
          @closed = false
        end

        # Everything the process has written since the last read: "" while it
        # is alive with nothing to say, nil once the stream has ended. Never
        # blocks and never waits — the fiber reading this one has other jobs
        # to drain — so a caller polls it rather than being pushed to.
        #
        # Bytes read in the same pass that hits EOF are returned; the nil
        # comes on the pass after, so the end of a stream never swallows the
        # last thing the process said.
        def read(max = CHUNK)
          buf = @pending || String.new(encoding: Encoding::BINARY)
          @pending = nil
          drain(buf, max) unless @eof
          buf.empty? && @eof ? nil : decode(buf)
        end

        # Whether the stream has ended — the process is gone and the pipe has
        # been read to its end. An owner asks this rather than #exited? when
        # the question is "can anything else still arrive", because a job's
        # own children can outlive it holding the write end.
        def eof? = @eof

        # Whether the process is gone, probed with a non-blocking wait that
        # reaps it when it finds one exited. Asked rather than #exit_status
        # because a signalled process HAS no exit status: `nil` there means
        # "still running" and "killed" both, and only this tells them apart.
        def exited?
          return true if @exited

          if (reaped = Process.wait2(@pid, Process::WNOHANG))
            @exited = true
            @status = reaped.last.exitstatus
          end
          @exited
        rescue Errno::ECHILD
          @exited = true
        end

        # nil until the process has exited, and nil afterwards too when a
        # signal ended it rather than an `exit`.
        def exit_status
          exited?
          @status
        end

        # Idempotent: a job explicitly stopped and then closed again by its
        # owner's disposal must not raise, and must not wait on a child that
        # is already reaped.
        #
        # The whole process GROUP goes, not just the pid. #pipe_spawn's child
        # leads its own group, so a signal reaches whatever the job spawned as
        # well as the job itself — a surviving background child would otherwise
        # hold the agent's authority with nothing left in the harness able to
        # name it — and the reaper, handed `-pgid`, collects the one member of
        # that group that is our child. #end_group is the ordering; it is
        # Shell#discard's, step for step, and for its reasons.
        #
        # The branch where the leader has ALREADY been reaped — by the drain
        # fiber's probe, or by a collect that found it exited — signals
        # nothing at all. Survivors of a reaped leader keep its pgid reserved
        # only for as long as they live, so nothing here can tell "our group,
        # now empty" from "a stranger's recycled pgid", and leaking a
        # grandchild is the honest answer over killing somebody else's
        # process. docs/subagents.md §6 says so out loud; plan §14 is where
        # the fix would live.
        #
        # Unlike PTYHandle the fd is dropped last, because a pipe has no
        # equivalent of the pty wedge: bytes nobody read are discarded by the
        # kernel when the writer dies, so nothing here can stick in exit. What
        # the process managed to say before it went is drained into the handle
        # on the way past, so closing a job never swallows its last words —
        # #read hands them over afterwards exactly as if it were still open.
        def close
          return @ended if @closed

          @closed = true
          begin
            @ended = @exited ? :terminated : end_group
          ensure
            # A handle this call touched is a handle this call finishes. The
            # reaper is somebody else's method and the fd is the only thing
            # holding this pipe open, so a raise on the way through must not
            # be able to leave the row half-closed: an fd still open, a child
            # still in the process table, and an owner that thinks the job is
            # over.
            #
            # The value is an ASSUMPTION recorded so a second close is
            # idempotent, not an observation of the process table: if the
            # reaper raised, what became of the child is exactly what we do not
            # know. Nothing reads it today, and anything that starts to should
            # be told that first.
            @ended ||= :terminated
            @exited = true
            @pending ||= String.new(encoding: Encoding::BINARY)
            drain(@pending, CHUNK, cap: MAX_PENDING) unless @eof
            begin
              @reader.close unless @reader.closed?
            rescue IOError
              nil
            end
          end
          @ended
        end

        private

        # Shell#discard's three steps, applied to a process group: ask it to
        # leave, read it to EOF within the grace, then KILL what is still there
        # — all before anything is reaped. Same escalation the reaper applies
        # to a single pid (TERM, then SIGKILL after the grace), which is what
        # the seam promises a `stop` does.
        #
        # The ask is a TERM to the whole group, because a job has no protocol
        # to say `exit` down the way ctx[:shell] does, and the read is what
        # tells us it worked. Waiting on the leader would be the obvious way to
        # bound the wait, and it is the one thing that cannot happen here: a
        # wait that collected it would free the pgid, and the KILL below would
        # then be aimed at a pid the kernel is free to have handed to a
        # stranger — the invariant Shell#sweep spells out. EOF answers the same
        # question without reaping anything, and answers it better: it means
        # the leader AND every child that inherited its output are gone. What
        # the job said on its way out lands in @pending while we wait, where
        # the next #read hands it over — under MAX_PENDING, because the same
        # grace that lets a job leave politely lets a chatty one write for the
        # whole of it.
        def end_group
          signal("TERM")
          deadline = now + @grace
          @pending ||= String.new(encoding: Encoding::BINARY)
          loop do
            drain(@pending, CHUNK, cap: MAX_PENDING)
            break if @eof || now >= deadline

            sleep POLL
          end
          # `:killed` here says the STREAM outlived the grace, which is not
          # what the reaper means by it: the leader may well have gone on the
          # TERM while a child of its own held the pipe open. It is the honest
          # answer for a close whose sweep did the ending, and #reap!'s own
          # contract stays about the single pid its other callers hand it.
          ended = @eof ? :terminated : :killed
          sweep
          @reaper.call(-@pid, @grace) # collects the leader; its own TERM is a no-op by now
          ended
        end

        def drain(buf, max, cap: nil)
          loop do
            chunk = @reader.read_nonblock(max, exception: false)
            if chunk.nil?
              @eof = true
              break
            end
            break if chunk == :wait_readable

            keep(buf, chunk, cap)
          end
        rescue IOError
          @eof = true
        end

        # Appends what fits and drops the rest on the floor, having read it:
        # past the cap the bytes still come off the pipe, so the writer stays
        # unblocked while this process stops growing. An uncapped drain (#read,
        # where the caller is asking for what is there) keeps everything.
        def keep(buf, chunk, cap)
          return buf << chunk if cap.nil?

          room = cap - buf.bytesize
          buf << chunk.byteslice(0, room) if room.positive?
        end

        def sweep = signal("KILL")

        # Both refusals mean there was nothing of ours left to signal;
        # Subprocess#signal says which is which and why neither is an error.
        def signal(name)
          Process.kill(name, -@pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        def decode(bytes) = bytes.force_encoding(Encoding::UTF_8)
      end
    end
  end
end
