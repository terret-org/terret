# frozen_string_literal: true

module Terret
  module Exec
    # This owner already holds `max_terminals` open. Refused rather than
    # quietly reaping the oldest, or the dead ones: a terminal is a live
    # process an agent asked to keep, and deciding on its behalf which one it
    # has finished with is not ours to make. Closing one is the caller's move.
    TerminalLimit = Class.new(Terret::Tools::Failure)

    # No terminal by that name belongs to this owner — either it was never
    # opened, it was closed, or it belongs to somebody else. All three are the
    # same answer on purpose: which of them is true is not information one
    # owner should be able to learn about another's terminals.
    NoSuchTerminal = Class.new(Terret::Tools::Failure)

    # A name this owner is already using. Opening over it would drop the
    # handle to a running process — unreapable, since nothing would hold its
    # pid any more — so the refusal is what keeps disposal honest.
    TerminalExists = Class.new(Terret::Tools::Failure)

    # ctx[:terminals] — named, long-lived PTYs (plan §6.6; docs/exec.md §2).
    # They outlive a single tool call by design: a REPL or a dev server stays
    # addressable across a turn, which is the whole difference between this
    # seam and ctx[:subprocess]'s one-shot spawn.
    #
    # Names are scoped per owner, not global. `open(name, argv, session: key)`
    # keys the registry on [owner, name], so two agents may each keep a
    # terminal called "repl" without collision, and neither can address (or
    # accidentally close) the other's by guessing its name — a terminal is a
    # live process with the agent's authority, so a shared namespace would be a
    # capability leak between agents, not merely a naming inconvenience.
    # `close_all_for(key)` is then exactly "drop this owner's rows", which is
    # what agent disposal needs. The cap counts per owner for the same reason:
    # it is the limit an agent can see and act on, and its error message can
    # say something true to the caller that hit it.
    class Terminals < Hames::Service
      service_key :terminals
      inject :subprocess

      # What `open` hands back. The handle itself stays in the registry: every
      # other method is name-addressed, so nothing outside this service can
      # drive a terminal around the cap or the ownership check.
      Terminal = Data.define(:name, :owner, :pid)

      DEFAULT_SESSION = :default
      DEFAULT_MAX = 8
      CHUNK = 4096

      # Bounded, so reading a terminal that has nothing to say returns
      # empty-handed instead of holding the turn open until it does.
      DEFAULT_READ_TIMEOUT = 0.1

      # Bounds the pre-close drain against a child writing without pause.
      DRAIN_BUDGET = 0.1

      def start(ctx)
        @ctx = ctx
        @open = {} # [owner, name] => PTYHandle
      end

      # The loader calls this on unload. Terminals are processes the harness
      # owns; dropping the registry without reaping them would leak one per
      # name for the life of the host process.
      def stop(_ctx) = close_all

      # Every knob is read where it is used, so a hot config swap needs nothing
      # re-derived here — including a lowered `max_terminals`, which then bites
      # on the next open rather than closing something already running.
      def reconfigure(_config); end

      def open(name, argv, session: DEFAULT_SESSION, cwd: nil, env: {})
        name = name.to_s
        owner = session.to_s
        raise TerminalExists, "a terminal named #{name} is already open" if @open.key?([owner, name])

        if (count = count_for(owner)) >= max
          raise TerminalLimit, "#{count} terminals are already open; close one first (max_terminals: #{max})"
        end

        handle = @ctx[:subprocess].pty_spawn(argv, cwd: cwd || default_cwd, env: env)
        @open[[owner, name]] = handle
        Terminal.new(name: name, owner: owner, pid: handle.pid)
      end

      def input(name, text, session: DEFAULT_SESSION) = fetch(name, session).write(text)

      # "" means the terminal is alive with nothing to say; nil means its child
      # is gone. The entry survives that EOF — reading is not disposal, and the
      # owner still has to close it, which is also what frees its slot.
      def read(name, session: DEFAULT_SESSION, max: CHUNK, timeout: nil)
        fetch(name, session).read(max, timeout: timeout || read_timeout)
      end

      # Reaps the child and forgets the name. Closing a name that is not open
      # is a no-op rather than an error: disposal runs over sets that may
      # already have been partly closed, and PTYHandle#close is itself
      # idempotent.
      def close(name, session: DEFAULT_SESSION)
        handle = @open.delete([session.to_s, name.to_s]) or return nil
        drain(handle)
        handle.close
      end

      # The agent-disposal hook: everything this owner opened, closed and
      # forgotten, by the names it used. Another owner's terminals are
      # untouched.
      def close_all_for(session)
        owner = session.to_s
        @open.keys.select { |(o, _n)| o == owner }.map do |(_o, name)|
          close(name, session: owner)
          name
        end
      end

      def close_all = @open.keys.each { |(owner, name)| close(name, session: owner) }

      private

      def max = config[:max_terminals] || DEFAULT_MAX
      def read_timeout = config[:read_timeout] || DEFAULT_READ_TIMEOUT
      def default_cwd = config[:cwd] || Dir.pwd

      def count_for(owner) = @open.keys.count { |(o, _n)| o == owner }

      # Empty the terminal before the handle reaps its child. A process killed
      # while its terminal still holds bytes nobody read can get stuck in exit
      # — measured on macOS with a bash in the terminal, reliably, with as
      # little as a startup banner pending — and the reaper's blocking wait
      # would then never return. In the ordinary case this costs one
      # non-blocking read; the budget bounds a child writing without pause.
      def drain(handle)
        deadline = monotonic + DRAIN_BUDGET
        loop do
          chunk = handle.read(CHUNK, timeout: 0)
          return if chunk.nil? || chunk.empty? || monotonic >= deadline
        end
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def fetch(name, session)
        @open[[session.to_s, name.to_s]] or
          raise NoSuchTerminal, "no terminal named #{name} is open"
      end
    end
  end
end
