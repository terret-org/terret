# frozen_string_literal: true

require "securerandom"

module Terret
  module Exec
    # There is no shell to run anything in: bash could not be spawned, or it
    # started and never answered its startup handshake. Raised rather than
    # returned, because every other outcome on this seam describes a command
    # that actually ran, and this one is the absence of the thing that runs
    # them.
    ShellUnavailable = Class.new(Terret::Tools::Failure)

    # A second command arrived for a session that is still running one.
    # Refused rather than queued: one bash per key can only run one thing at a
    # time, and a queue would either make the waiting caller's `timeout:` a lie
    # (its clock would start before its command did) or need a scheduler this
    # seam has no business owning. The guarantee worth keeping is narrow and
    # absolute — the result a caller gets back is that caller's command's
    # result — and a refusal keeps it without inventing machinery.
    ShellBusy = Class.new(Terret::Tools::Failure)

    # ctx[:shell] — one persistent bash per session key (plan §6.6;
    # docs/exec.md §2). The whole reason this seam exists next to
    # ctx[:subprocess]'s one-shot #spawn is that the same process serves every
    # call for a key, so `cd` and `export` from one run are visible to the
    # next, exactly as a human's terminal session behaves.
    #
    # The protocol: write the command on its own line, then a `printf` line
    # that emits a per-session random sentinel followed by `$?`, and read
    # until that marker. The sentinel is generated here and never exported, so
    # a command cannot forge one; the marker regexp additionally demands
    # digits and a newline immediately after it, which is what makes the parse
    # exact rather than lucky — the only other place the sentinel can appear
    # in the stream is a terminal echo of the request line, where `%s` follows
    # it instead of a status.
    #
    # There is deliberately no cap on the number of sessions, where
    # ctx[:terminals] caps names hard. The difference is who supplies the key:
    # a session key is an agent id the harness hands in, so the count is
    # bounded by the agents the harness chose to run, while a terminal name
    # comes from a tool call the model wrote and is therefore something a model
    # can mint without limit. Capping the harness against itself would only
    # move the failure somewhere less honest.
    class Shell < Hames::Service
      service_key :shell
      inject :subprocess

      # `status` is nil when the command did not report one — it was
      # interrupted, or the shell ended underneath it. An exit code we do not
      # have is not invented. `stdout` is the terminal's stream: a pty has one,
      # so a command's stderr arrives interleaved here rather than separately.
      # `notice` is nil unless something happened that the caller did not ask
      # for (a restart, a truncation); it is a field rather than text appended
      # to stdout so that stdout stays exactly what the terminal carried.
      #
      # "Exactly" is worth pinning down: no echo of the request, no prompt, no
      # separator this file injected. It does not mean only the command's own
      # bytes — the shell's own lines (`[1] 1234` when a job is backgrounded, a
      # syntax error it complains about) are written to the same terminal at
      # the same time, and reporting them is more honest than guessing which
      # lines a caller did not mean to ask for.
      Result = Data.define(:status, :stdout, :notice)

      Session = Data.define(:handle, :sentinel, :marker)

      DEFAULT_SESSION = :default
      DEFAULT_TIMEOUT = 120
      HANDSHAKE_TIMEOUT = 10
      CHUNK = 64 * 1024

      # What one run may buffer. A command that writes without pause fills this
      # process's memory at whatever rate the terminal will carry — measured
      # here at 11.4MB in three seconds, so the default 120s timeout puts
      # roughly 450MB within reach of a single `yes`. One mebibyte is far more
      # than a model can read (the Bash tool caps what it shows at a fraction
      # of it) and far less than a runaway command needs to hurt the host; the
      # limit is a memory bound, not a display decision, which is why the tool
      # layer still applies its own smaller one.
      DEFAULT_MAX_OUTPUT = 1 << 20

      # Once the cap is reached the tail of the stream is still scanned for the
      # marker, in a window this size. It only has to be longer than a marker
      # (a 38-byte sentinel, a status, a newline) for a marker split across two
      # reads to survive the trim.
      MARKER_WINDOW = 256

      # UTF-8 lead bytes and the character length each one declares: [mask,
      # value, bytes]. Read as "if (byte & mask) == value, the character is
      # `bytes` long".
      CHARACTER_LENGTHS = [
        [0x80, 0x00, 1],
        [0xE0, 0xC0, 2],
        [0xF0, 0xE0, 3],
        [0xF8, 0xF0, 4]
      ].freeze

      # A session that is not reused is never left half-drained, so the budget
      # only bounds the pathological case: a background job spewing without
      # pause between two runs. When it does lose that race the remainder is
      # not lost, it simply arrives inside the next run's output — the same
      # thing a human sees when a background job prints over their next
      # command, and a better answer than reading a spewing terminal forever.
      DRAIN_BUDGET = 0.1

      # How long a session gets to leave on its own before the handle's reaper
      # takes over. Bounded, because a shell still busy with a command will not
      # read the request at all — and in exactly that case disposal costs this
      # budget plus the reaper's own grace before the SIGKILL lands (measured:
      # a close that would take 3s takes 6.01s when a child is still writing),
      # because bash never gets to the `exit`.
      FAREWELL_BUDGET = 1.0

      # ETX — what a human's ^C is on the wire. The line discipline turns it
      # into SIGINT for the terminal's foreground process group; with job
      # control off (see HANDSHAKE) that group is the session's own, so the
      # signal reaches the command's children as well as bash. It is the
      # gentler half of ending a run: #sweep is what guarantees the rest.
      INTERRUPT = "\u0003"

      # `--noediting` is load-bearing, not tidiness: on a pty bash is
      # interactive, and readline echoes the line it is reading no matter what
      # the terminal's own echo flag says. Disabling line editing puts the
      # echo back under the terminal's control, where the handshake's `stty
      # -echo` can turn it off. `--norc --noprofile` keep a developer's dotfiles
      # from deciding what an agent's shell prints.
      BASH_ARGV = ["bash", "--norc", "--noprofile", "--noediting", "-s"].freeze

      # Run once per session before any command. `-echo` so the request lines
      # do not come back as output; `-onlcr` so the terminal stops rewriting
      # the child's newlines as CR-LF; `-icanon min 1 time 0` because a
      # canonical-mode terminal caps one input line at MAX_CANON (1024 bytes on
      # macOS) and would silently lose the tail of a longer command; `-ixon` so
      # a stray ^S in a command cannot wedge the stream. Failure is tolerated
      # (`2>/dev/null`): under a sandbox whose exec has no tty there is nothing
      # to configure, and bash is then non-interactive, which needs none of it.
      #
      # `set +m` turns job control off, and that is a disposal decision rather
      # than a cosmetic one. With job control on, bash puts every job in a
      # process group of its own, so a `&` job's group id is one nothing here
      # ever learns — and a background job that outlives its session is a
      # process holding the agent's authority that no part of the harness can
      # still name. Without job control every child stays in the session's own
      # process group, which #sweep can end as a unit. The trade-off, stated
      # rather than discovered: the session has no `fg`, `bg`, or `%1`. What it
      # does NOT buy is a quieter terminal — bash still prints its "[1] 1234"
      # notice when a job is backgrounded (measured, not assumed), and that
      # line lands in the run's output like anything else the shell says.
      HANDSHAKE = "stty -echo -onlcr -icanon -ixon min 1 time 0 2>/dev/null; set +m; PS1=; PS2="

      def start(ctx)
        @ctx = ctx
        @sessions = {} # key (String) => Session
        @running = {}  # key (String) => true while a command is in flight
        # When the agent that owns a session key is disposed, its bash (and the
        # background jobs in its process group) must go with it — fork disposal
        # never reaches this root-mounted process. Registered via ctx.on, so it
        # reverses when this service unloads.
        ctx.on("agent/disposed") { |session_id| close(session: session_id) }
      end

      # The loader calls this on unload. A persistent shell is a process the
      # harness owns, so dropping the reference without reaping it would leak a
      # bash per agent for the life of the host process.
      def stop(_ctx) = close_all

      # Every knob is read where it is used, so a hot config swap needs nothing
      # re-derived here. A live bash keeps the cwd and environment it was
      # spawned with — it is a running process, not a value — and the new
      # settings govern the next session.
      def reconfigure(_config); end

      # Runs one command in this key's session, spawning the session on first
      # use. Never raises for a command's own failure: a non-zero status is a
      # Result like any other, because a command that failed still ran.
      def run(cmd, session: DEFAULT_SESSION, timeout: nil)
        key = session.to_s
        raise ShellBusy, "the #{key} shell session is already running a command" if @running[key]

        @running[key] = true
        begin
          run!(key, cmd, timeout || default_timeout)
        ensure
          # released even when the run raised, so a session is never left
          # permanently unusable by a failure it already reported
          @running.delete(key)
        end
      end

      # The pid of this key's live bash, or nil if it has never run anything.
      # An owner (and a test) can see whether a session is real without asking
      # it to run something.
      def pid(session: DEFAULT_SESSION) = @sessions[session.to_s]&.handle&.pid

      # Reaps one session's bash. Closing a key that has none is not an error:
      # disposal must be safe to call over a set of keys that may or may not
      # have run anything.
      def close(session: DEFAULT_SESSION) = discard(session.to_s)

      def close_all = @sessions.keys.each { |key| discard(key) }

      private

      def run!(key, cmd, timeout)
        notices = []
        if stale?(key)
          discard(key)
          notices << "the shell session had exited; a fresh one was started, " \
                     "so the cwd and variables from earlier runs are gone"
        end
        s = (@sessions[key] ||= open_session)

        return ended(key, "", notices) unless write(s, request(s, cmd))

        outcome, out, dropped = collect(s, monotonic + timeout)
        if dropped.positive?
          notices << "output truncated at max_output: kept the first #{out.bytesize} bytes " \
                     "and dropped #{dropped} more"
        end

        case outcome
        when :timeout then timed_out(key, s, out, notices, timeout)
        when :eof then ended(key, out, notices)
        else Result.new(status: outcome, stdout: out, notice: join(notices))
        end
      end

      def default_timeout = config[:timeout] || DEFAULT_TIMEOUT
      def max_output = config[:max_output] || DEFAULT_MAX_OUTPUT
      def cwd = config[:cwd] || Dir.pwd
      def env = config[:env] || {}

      # The command goes on its own line rather than joined to the marker line
      # with `;`, so a multi-line command runs as written. printf emits no
      # separator of its own before the sentinel, which is what makes stdout
      # exact: there is no injected newline to strip back off, and a command
      # whose output ends without one (or ends with a bare CR) is reported as
      # it was written.
      #
      # The cost of this shape is honest and worth stating: a command that
      # leaves bash waiting for more input (an unclosed quote, a trailing `\`)
      # swallows the marker line, and the run ends at its timeout with the
      # session restarted.
      def request(s, cmd) = "#{cmd}\nprintf '%s%s\\n' '#{s.sentinel}' \"$?\"\n"

      def open_session
        sentinel = "TERRET#{SecureRandom.hex(16)}"
        handle = @ctx[:subprocess].pty_spawn(BASH_ARGV, cwd: cwd, env: env)
        s = Session.new(handle: handle, sentinel: sentinel,
                        marker: Regexp.new("#{sentinel}(\\d+)\\r?\\n"))
        handshake!(s)
        s
      end

      # Reading to the first marker also synchronises the session: everything
      # bash said before it — the login banner some systems print, the default
      # prompt, the echo of the handshake line itself before `stty -echo` took
      # effect — is discarded, so the first command's output starts clean.
      def handshake!(s)
        outcome = if write(s, request(s, HANDSHAKE))
                    collect(s, monotonic + HANDSHAKE_TIMEOUT).first
                  else
                    :closed
                  end
        return if outcome.is_a?(Integer)

        # nothing else holds this handle yet, so a shell that never became
        # usable is reaped here rather than left for the caller to dispose
        s.handle.close
        raise ShellUnavailable, "the shell did not answer its startup handshake (#{outcome})"
      end

      # Reads until the marker, the deadline, or the end of the shell. Returns
      # [status, stdout, dropped] for a command that reported one, or
      # [:timeout, partial, dropped] / [:eof, partial, dropped] for the two
      # ways it may not have.
      #
      # Past `max_output` the kept buffer stops growing, but reading does not:
      # the marker arrives at the very end of a command's output, so a run that
      # simply stopped reading would lose the status of every command that ever
      # exceeded the cap, and would leave the unread bytes to be charged to the
      # next run. Instead the overflow is counted and discarded, with a window
      # of it kept so the marker is still found when it comes.
      #
      # The buffers stay BINARY until they are sliced: terminal bytes are not
      # guaranteed to be valid UTF-8, and matching against a BINARY string is
      # the one form that cannot raise on a child emitting whatever it likes.
      def collect(s, deadline)
        kept = String.new(encoding: Encoding::BINARY)
        tail = nil # the rolling window, once the cap is reached
        seen = 0   # every output byte the command produced, kept or not
        cap = max_output

        loop do
          scan = tail || kept
          if (m = s.marker.match(scan))
            # Where the marker starts in the STREAM, not in whichever buffer
            # found it: the window always ends at the stream's end, so its own
            # offsets are relative. Everything before that point is the
            # command's output and everything from it on is protocol — which
            # is why the cut is taken here rather than at the cap. A command
            # whose output stops within a marker's length of the cap leaves the
            # marker BEGINNING inside the kept bytes, and returning those
            # verbatim would hand the caller the session's sentinel, the one
            # value the protocol's forgery resistance rests on.
            marker_at = seen - scan.bytesize + m.begin(0)
            out = kept.byteslice(0, marker_at) # byteslice clamps, so this is
                                               # all of `kept` in the ordinary
                                               # over-the-cap case
            return [Integer(m[1]), text(out), dropped!(marker_at - out.bytesize)]
          end

          remaining = deadline - monotonic
          return [:timeout, *partial(kept, seen)] if remaining <= 0

          chunk = s.handle.read(CHUNK, timeout: remaining)
          return [:eof, *partial(kept, seen)] if chunk.nil?

          seen += chunk.bytesize
          if tail
            window!(tail << chunk.b)
          else
            kept << chunk.b
            next if kept.bytesize <= cap

            # keep the first `cap` bytes; carry a window across the cut so a
            # marker straddling it is still whole in the tail
            tail = window!(kept.byteslice([cap - MARKER_WINDOW, 0].max..))
            kept = whole_characters(kept.byteslice(0, cap))
          end
        end
      end

      # A run that ended without its marker: everything read is the command's
      # output, and the cut is wherever the deadline or the shell's end landed
      # — a place this file chose, so it gets the same character-boundary
      # treatment the cap does.
      def partial(kept, seen)
        out = whole_characters(kept)
        [text(out), dropped!(seen - out.bytesize)]
      end

      def window!(buf)
        buf.slice!(0, buf.bytesize - MARKER_WINDOW) if buf.bytesize > MARKER_WINDOW
        buf
      end

      # Back a byte-offset cut off to the last whole UTF-8 character. Cutting
      # at a byte offset can split a character in half, and the halves are not
      # the child's bytes — this seam made them. That matters beyond tidiness:
      # a durable append JSON-encodes the payload, so a manufactured half
      # character raises at the append boundary, one layer away from the code
      # that broke it.
      #
      # Only an INCOMPLETE trailing character moves, and never more than three
      # bytes, because that is the longest tail a split UTF-8 character can
      # leave. Bytes a child emitted that were never valid UTF-8 are left
      # exactly as they arrived — a stray continuation byte with no lead, an
      # 0xFF — since preserving what the child actually wrote is the whole
      # reason nothing here re-encodes. The rule is narrow on purpose: never
      # manufacture invalid bytes out of valid ones.
      def whole_characters(bytes)
        seen = 0
        index = bytes.bytesize - 1
        while index >= 0 && seen < 4
          byte = bytes.getbyte(index)
          if (byte & 0xC0) == 0x80 # a continuation byte; keep walking back
            index -= 1
            seen += 1
            next
          end

          need = CHARACTER_LENGTHS.find { |mask, value, _| (byte & mask) == value }&.last
          return bytes if need.nil? || seen + 1 >= need # complete, or not ours to fix

          return bytes.byteslice(0, index) # an incomplete tail: drop it
        end
        bytes
      end

      # Every byte dropped is a byte the command produced that the caller will
      # not see, so the count is non-negative by construction — `out` is always
      # a prefix of the output that preceded the marker. A negative count would
      # mean protocol bytes were being counted as output, which is exactly the
      # arithmetic that leaks a sentinel, so it fails loudly here rather than
      # being rounded away by a `.positive?` check downstream.
      def dropped!(count)
        raise "shell: dropped byte count went negative (#{count}); the cap arithmetic is wrong" if count.negative?

        count
      end

      # Bytes sitting on the terminal between two runs belong to whatever wrote
      # them — a backgrounded job, a job-control notice — and never to the
      # command about to run, so they are drained rather than charged to the
      # next result. The same pass is the liveness check: a session whose bash
      # is gone reads as EOF, and an idle live one answers "" on the first
      # non-blocking read, so this costs a syscall in the ordinary case.
      def stale?(key)
        s = @sessions[key] or return false

        deadline = monotonic + DRAIN_BUDGET
        loop do
          chunk = s.handle.read(CHUNK, timeout: 0)
          return true if chunk.nil?
          return false if chunk.empty? || monotonic >= deadline
        end
      end

      # The decided semantics (docs/exec.md §2): kill and respawn rather than
      # try to recover. The interrupt is what ends the command's own children;
      # the session goes with it because after an interrupt its input queue and
      # the output still in flight are in a state we cannot account for — the
      # next run gets a shell we can, and the caller is told so rather than
      # left to discover it through a lost `cd`.
      def timed_out(key, s, out, notices, timeout)
        interrupt(s)
        discard(key)
        notices << "timed out after #{timeout}s; the command was interrupted and the shell " \
                   "session killed, so the next run starts a fresh session"
        Result.new(status: nil, stdout: out, notice: join(notices))
      end

      def ended(key, out, notices)
        discard(key)
        notices << "the shell session ended while this command ran; the next run starts a " \
                   "fresh session, so the cwd and variables from earlier runs are gone"
        Result.new(status: nil, stdout: out, notice: join(notices))
      end

      def interrupt(s) = write(s, INTERRUPT)

      # A write to a terminal whose child is gone is not an exception here: it
      # is how we learn the session ended, and the caller asked to run a
      # command, not to be told about a file descriptor.
      def write(s, str)
        s.handle.write(str)
        true
      rescue Errno::EIO, Errno::EPIPE, IOError
        false
      end

      def discard(key)
        s = @sessions.delete(key) or return nil
        farewell(s)
        sweep(s.handle.pid)
        s.handle.close
      end

      # End everything still running in the session's process group. Reaping
      # bash is not enough on its own: a `&` job is not bash's business once
      # started, and it survives the shell's exit to be reparented to init —
      # a process with the agent's authority, outside the sandbox's lifecycle,
      # that nothing in the harness can name any more. `set +m` (see HANDSHAKE)
      # is what makes one signal reach all of them: without job control every
      # child stays in the group bash leads, and PTY.spawn made bash a session
      # leader, so its pid IS that group's id.
      #
      # Deliberately before the handle is closed: at this point bash is either
      # alive or an unreaped zombie, so the pid is still ours and cannot have
      # been recycled into somebody else's process group by the time the signal
      # lands. KILL rather than TERM because this runs after the session has
      # already been asked to leave politely.
      #
      # Both refusals mean the same thing here — there was nothing left to end.
      # ESRCH is an empty group; EPERM is what Darwin answers when every member
      # left is a zombie (measured: a group holding one live child signals
      # fine, the same group once only the exited leader remains raises EPERM).
      # The one case EPERM could hide is a live child running under another
      # uid, which a setuid command could produce and which no signal of ours
      # could have ended anyway.
      def sweep(pgid)
        Process.kill("KILL", -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      # Ask the shell to leave, and read it to EOF before the handle is closed.
      # Both halves are load-bearing, and neither is politeness:
      #
      # An interactive bash ignores SIGTERM — that is what keeps a stray kill
      # from taking down a human's terminal — so a close that went straight to
      # the reaper would always spend the full grace period before the SIGKILL
      # landed. `exit` is the only cheap way out.
      #
      # And a bash SIGKILLed while its terminal still holds bytes nobody read
      # gets stuck in exit: measured on macOS, with as little as a startup
      # banner pending, the process sits in `E` state indefinitely and the
      # reaper's blocking wait never returns — a wedge that would take the
      # whole reactor with it. Reading to EOF (which is also what draining
      # does) is what keeps that from being reachable.
      def farewell(s)
        write(s, "exit\n")
        deadline = monotonic + FAREWELL_BUDGET
        loop do
          return if s.handle.read(CHUNK, timeout: 0.01).nil? # EOF: the shell is gone
          return if monotonic >= deadline
        end
      end

      def join(notices) = notices.empty? ? nil : notices.join(" ")

      # Terminal bytes arrive as BINARY; everything downstream of this seam is
      # text. Forced rather than encoded, so a command emitting invalid UTF-8
      # still round-trips its bytes instead of raising here.
      def text(buf) = buf.force_encoding(Encoding::UTF_8)

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
