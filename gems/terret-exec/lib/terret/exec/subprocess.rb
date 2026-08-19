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
      # here — the next wait collects it.
      def signal(pid, name)
        Process.kill(name, pid)
      rescue Errno::ESRCH
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
    end
  end
end
