# frozen_string_literal: true

begin
  require "terret"
rescue LoadError
  require_relative "../../../../terret-core/lib/terret" # monorepo path source
end

module Terret
  module Sandbox
    # There is no container to run anything in: the daemon is not there, the
    # image cannot be had, or `docker run` refused. Raised rather than
    # returned, because every other outcome on this seam describes a command
    # that actually ran somewhere.
    ContainerUnavailable = Class.new(Terret::Tools::Failure)

    # A cwd outside the granted workspace. The name deliberately echoes
    # ctx[:fs]'s Denied, and for the same reason: the workspace is the only
    # thing that exists inside the container, so a path outside it is refused
    # rather than quietly relocated to somewhere the caller did not ask for.
    Denied = Class.new(Terret::Tools::Failure)

    # ctx[:sandbox] — the container provider (plan §12). This is the row that
    # makes the M7 claim true: swap `SandboxNone` for this plugin in one patch
    # row and Bash, Read, Write, Grep and the PTY tools all start running
    # inside a container, with no change to any tool. Nothing here knows what
    # a tool is; it only turns an argv into a `docker exec` argv, and the
    # ctx[:subprocess] seam does the rest.
    #
    # ONE WORLD. Each granted workspace directory is bind-mounted at its own
    # absolute path, so `/ws/a.rb` on the host is `/ws/a.rb` in the container.
    # That is what lets the file tools stay on the host (ctx[:fs] writes
    # through the mount) while the process tools run inside, without either
    # side translating paths. The mounted path is the REALPATH, resolved
    # exactly the way ctx[:fs] resolves its own roots — on macOS a tmpdir is
    # handed out under /var and /var is a symlink to /private/var, so a
    # provider that mounted the un-resolved name would disagree with every
    # path fs produces.
    #
    # IT SHELLS OUT TO DOCKER DIRECTLY, with plain Process.spawn/IO.popen,
    # never through ctx[:subprocess]. That is not an oversight: this service
    # sits BENEATH the seam subprocess consults, so routing its own `docker
    # run` through subprocess would send it back through #wrap and try to
    # start the container inside the container it is starting.
    #
    # WHAT IT DOES NOT ISOLATE, stated rather than implied. The workspace is
    # shared read-write with the host by design, so a command in the container
    # can still rewrite anything ctx[:fs] could. The isolation this buys is the
    # rest of the host — the filesystem outside the workspace, the process
    # table, and (at `network: "none"`) the network.
    #
    # CANCELLATION DOES NOT CROSS THE BOUNDARY, and this one is a real loss
    # rather than a footnote. Every kill in the harness — #spawn's timeout
    # escalation, a terminal's close, ctx[:shell]'s sweep — signals a pid on
    # the HOST, and under this provider that pid is the `docker exec` CLI, not
    # the process it started. Killing the CLI detaches; the command inside the
    # container keeps running. So a timed-out command is reported as timed out
    # and truthfully was abandoned, but it goes on burning the container's CPU
    # until something stops the container itself, and ctx[:shell]'s `set +m`
    # guarantee — that one signal to the session's process group ends every
    # child it started — is void here, because that process group lives in
    # another pid namespace. Ending the container (#stop, or #restart!) is the
    # only cancellation that reaches inside it. Closing this properly means
    # `docker exec` growing a way to signal what it started, or the provider
    # tracking in-container pids itself; neither belongs in M7.
    #
    # ENV DOES NOT CROSS. `Subprocess#spawn(env:)` applies to the docker CLI
    # process on the host, not to the process inside the container: variables
    # set that way configure `docker`, and the command never sees them. In-
    # container environment comes from the image and from what the command
    # itself exports (ctx[:shell]'s session keeps `export`s across calls, which
    # is the ordinary way an agent sets one). Propagating selected variables
    # with `docker exec -e` is a plausible M8 knob and is deliberately not
    # built here — a sandbox that silently forwarded the host's environment
    # would be a hole, not a feature.
    class Docker < Hames::Service
      service_key :sandbox
      config_schema image:      { type: String, default: "ruby:slim", doc: "container image argv runs in" },
                    network:    { type: String, default: "none",
                                  doc: "docker --network mode (none, bridge, host, or a network name)" },
                    workspace:  { type: [String, Array],
                                  doc: "host directory root(s) mounted into the container" },
                    user:       { type: String,
                                  doc: "container user (default: the host uid:gid); nil runs as root" },
                    docker_bin: { type: String, doc: "path to the docker binary (default: resolved from PATH)" },
                    memory:     { type: String,
                                  doc: "docker --memory limit (e.g. 256m, 1g); unset means no limit" },
                    cpus:       { type: [String, Numeric],
                                  doc: "docker --cpus limit (e.g. 1.5); unset means no limit" },
                    pids:       { type: Integer,
                                  doc: "docker --pids-limit, the container's max process count; unset means no limit" }

      # Debian-based, and chosen for what it carries rather than for Ruby:
      # ctx[:shell] spawns `bash` (the sentinel protocol is a bash protocol),
      # so an image without bash breaks the Bash tool the moment this row is
      # mounted. It also carries getent, which is how the network-denial test
      # asks a question that fails fast instead of timing out.
      DEFAULT_IMAGE = "ruby:slim"

      # Denied by default. A profile that wants the agent on the network says
      # so in the row; it is not something an isolation provider grants
      # quietly.
      DEFAULT_NETWORK = "none"

      # Every container started here carries this label, so one that outlives
      # its process — a crashed harness, a killed test run — is identifiable
      # with `docker ps --filter label=terret-sandbox` rather than by guessing
      # which `sleep infinity` was ours.
      LABEL = "terret-sandbox"

      # nil until the container exists. Public because an operator (and the
      # suite) needs to be able to ask which container an agent is living in
      # without having to run a command to find out.
      attr_reader :container

      def start(_ctx)
        @workspace = resolve_workspace(config[:workspace])
        @container = nil
        @lock = Mutex.new
        @docker_bin = resolve_docker_bin(config[:docker_bin])
      end

      def isolated? = true

      # The absolute path every docker invocation here runs through. Public so
      # a test (and an operator) can see which binary the row resolved to.
      def docker_bin = @docker_bin

      # The wrapped argv. `workspace_ready!` is called from HERE, not by
      # ctx[:subprocess], because the seam's contract is only `wrap` — the
      # caller hands over an argv and gets back one that runs somewhere else,
      # and whether that somewhere had to be created first is this service's
      # business. It also means the container is started lazily: mounting the
      # row costs nothing until an agent actually runs something.
      #
      # `-i` is always present. Without it `docker exec` does not attach stdin
      # at all (measured: a wrapped `cat` fed a payload returns nothing, and a
      # wrapped bash gets EOF before it can answer its handshake), which would
      # break both ctx[:shell]'s protocol and every #spawn that writes stdin.
      #
      # `-t` is added only when the caller asks, and the asymmetry is forced by
      # docker rather than chosen: `docker exec -i -t` REFUSES to run when the
      # CLI's own stdin is a pipe ("cannot attach stdin to a TTY-enabled
      # container because stdin is not a terminal", exit 1), so a `-t` on
      # every call would fail every ctx[:subprocess]#spawn. The flag is a
      # per-call fact — this argv is going to a pty — and only the caller
      # knows it.
      #
      # It matters more than a cosmetic terminal. Over a pty WITHOUT `-t`, the
      # container gives bash a pipe: bash goes non-interactive and the
      # handshake's `stty -echo` has no terminal to quiet, while the host pty
      # PTY.spawn created is still echoing every byte written to it. The
      # request line comes back inside the command's output — and that line
      # contains the session sentinel, the one value ctx[:shell]'s forgery
      # resistance rests on. With `-t` the docker CLI puts the host pty in raw
      # mode and gives the container a real terminal, `stty -echo` lands, and
      # stdout is exactly the command's output as the seam promises.
      #
      # The limitation that leaves: a caller who reaches a pty through a path
      # that cannot pass `tty: true` gets a working but echoing session. Since
      # ctx[:subprocess]#pty_spawn is the only way to a pty in the harness,
      # that is the one call site that has to say so.
      def wrap(argv, cwd:, tty: false)
        workspace_ready!
        [docker_bin, "exec", "-i", *(tty ? ["-t"] : []), "-w", workdir(cwd), @container, *argv]
      end

      # Idempotent, and the lock is what makes that true rather than nearly
      # true. A bare `@container ||= run_container!` reads, PARKS (the `docker
      # run` capture is blocking IO, which under a fiber scheduler yields), and
      # only then assigns — so N agents reaching their first wrap together each
      # see nil, each start a container, and only the last to assign is
      # remembered. The others are orphans in the worst sense: never stopped,
      # `--rm` never fires because `sleep infinity` never exits, and nothing
      # left in the process knows their ids. That is the ordinary case, not a
      # pathological one, because ctx[:subprocess] parks the fiber rather than
      # the thread precisely so one reactor can serve many agents at once.
      #
      # Mutex is fiber-aware under a scheduler, so a waiter parks instead of
      # blocking the reactor, and it is stdlib — this gem still has no runtime
      # dependency. The `docker run` is held INSIDE the lock deliberately: the
      # window being closed is exactly the one that spans it.
      #
      # There is still deliberately NO liveness check here — it would cost a
      # docker round-trip on every single wrap, which is every spawn in the
      # harness. A container that died underneath us surfaces as the exec's own
      # failure; #restart! is how a caller recovers from it.
      def workspace_ready!
        @lock.synchronize { @container ||= run_container! }
      end

      # Recovery for a container that left without us: an operator's `docker
      # rm`, an OOM kill, a Docker daemon restart. Nothing in this gem can
      # notice that on its own — the provider only builds an argv, and the exec
      # that would have reported "No such container" is run by
      # ctx[:subprocess], which has no path back to the seam to say so. So
      # recovery is explicit: drop the id being held, remove the container if
      # it somehow is still there, and let the next #wrap build a fresh one.
      # Without it a dead container stays dead for the life of the process and
      # only a remount brings the agent back.
      #
      # What a restart costs is the same either way: everything the old
      # container held is gone with it — ctx[:shell]'s sessions, open
      # terminals, anything a command exported. A fresh one starts as fresh as
      # the first one did.
      def restart! = discard!

      # The loader's unload hook, and the only thing standing between a
      # crashed agent and a `sleep infinity` holding a bind mount forever. The
      # default argument is what lets a caller that is not the loader — a test,
      # an operator — end the container without inventing a context.
      def stop(_ctx = nil) = discard!

      # A live image, network or workspace swap is a remount, and saying so is
      # more honest than pretending. The container is already running on the
      # old image with the old mounts; applying a new row would mean replacing
      # it, which would drop every ctx[:shell] session and every open terminal
      # living inside it — a good deal more than a config change should do
      # without the mounting profile asking for it.
      def reconfigure(_config)
        warn "terret-sandbox-docker: the container is already running on the mounted image, " \
             "network and bind mounts; remount the row to apply a new one"
      end

      private

      # Under the same lock as #workspace_ready!, so a disposal that lands
      # while another fiber is mid-`docker run` cannot clear an id that is
      # about to be assigned and leave the new container orphaned — the mirror
      # image of the race the lock is there to close.
      #
      # Tolerant of a container that is already gone, which is the ordinary
      # case for #restart!: `--rm` means the daemon may have removed it first,
      # and a disposal path that raised on an already-clean state would turn
      # tidy-up into a second failure.
      def discard!
        @lock.synchronize do
          id = @container or next
          # Removal is attempted FIRST, and the id is cleared only once it is
          # gone: a genuine `docker rm -f` failure means `sleep infinity` may
          # still be up holding its bind mount, so dropping the id here would
          # strand a container nothing can name. A daemon that already removed
          # the container (the ordinary `--rm` case) answers "No such
          # container", which is success for our purposes, not a failure.
          status, out = remove_container(id)
          if status&.zero? || already_gone?(out)
            @container = nil
          else
            warn "terret-sandbox-docker: docker rm -f #{id} failed (status #{status.inspect}); " \
                 "the container may still be running: #{out.strip}"
          end
        end
        nil
      end

      # Split out so #discard! can distinguish a removal that FAILED from one
      # that found the container already gone, and so a test can drive the
      # failure path without a daemon. Both streams are merged the way #capture
      # does, because the message is what makes a failed removal visible.
      def remove_container(id)
        out = IO.popen([docker_bin, "rm", "-f", id], err: [:child, :out], &:read)
        [$?&.exitstatus, out.to_s]
      end

      def already_gone?(out) = out.to_s.match?(/no such container/i)

      # Resolved to an ABSOLUTE path once, at start, so the bare name never
      # reaches an exec that would resolve it against PATH — a workspace
      # directory sitting on PATH could otherwise shadow `docker` with an
      # argv[0] the agent controls. An explicit `docker_bin:` row wins
      # (expanded to absolute); otherwise the first executable `docker` on PATH
      # is taken, and if none is found the bare name is kept so a missing docker
      # fails loudly rather than resolving somewhere unexpected.
      def resolve_docker_bin(configured)
        return File.expand_path(configured.to_s) if configured && !configured.to_s.empty?

        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |dir|
          next if dir.empty?

          candidate = File.join(dir, "docker")
          candidate if File.file?(candidate) && File.executable?(candidate)
        end.first || "docker"
      end

      def image = config[:image] || DEFAULT_IMAGE
      def network = config[:network] || DEFAULT_NETWORK

      # Defaults to the HOST's uid:gid, and on Linux that default is
      # load-bearing rather than a nicety. The workspace is bind-mounted
      # read-write, so a container running as root writes root-owned files into
      # it — and ctx[:fs], which runs as the host user, then cannot Write or
      # Edit what the container just created. One world stops being one world.
      # macOS hides this (Docker Desktop remaps ownership on the mount), which
      # is exactly what makes it worth defaulting: silently fine on a
      # developer's laptop, silently broken in Linux CI, which is where the
      # acceptance run and the soak actually happen.
      #
      # The cost, measured rather than guessed: the host uid has no /etc/passwd
      # entry inside the image, so `whoami` fails with "cannot find name for
      # user ID 501", $HOME is `/`, and an interactive bash greets as "I have
      # no name!". Harmless under `--norc --noprofile`, and the sentinel
      # protocol is unaffected — the suite proves that rather than assuming it.
      # A profile that needs root inside the container — to apt-get, or to
      # install into the image — sets `user: nil` explicitly and takes the
      # ownership problem back with it.
      def user = config.fetch(:user) { "#{Process.uid}:#{Process.gid}" }

      # `sleep infinity` rather than the image's own entrypoint: this container
      # is a place to exec into, not a service, so it has to stay up and do
      # nothing. `--rm` so a container whose process ends is not left behind as
      # a stopped row for someone to sweep by hand.
      #
      # This blocks the calling thread, and the cost is worth stating: on the
      # first wrap of a machine that does not have the image yet, that is a
      # pull — minutes, during which the reactor is not running anyone else's
      # agent. Pre-pulling the image is the answer; making this seam async is
      # not, because everything downstream of it already assumes the container
      # exists before an argv is wrapped.
      def run_container!
        if @workspace.empty?
          raise ContainerUnavailable,
                "no workspace directories were granted, so the container would have nothing " \
                "mounted and every wrapped path would be missing inside it"
        end

        argv = [docker_bin, "run", "-d", "--rm", "--label", LABEL, "--network", network,
                *resource_limits, *(user ? ["--user", user] : []), *mounts, image, "sleep", "infinity"]
        status, out = capture(argv)
        raise ContainerUnavailable, "docker run failed (status #{status.inspect}): #{out}" unless status&.zero?

        container_id(out) or
          raise ContainerUnavailable, "docker run reported success but printed no container id: #{out}"
      end

      # A workspace path containing a colon would confuse `-v`'s own
      # source:target:options syntax. Left as a known limitation rather than
      # worked around, because the alternative (`--mount`) trades a colon
      # problem for a comma problem.
      def mounts = @workspace.flat_map { |dir| ["-v", "#{dir}:#{dir}"] }

      # Optional caps on what a container may consume, each mapping to the docker
      # run flag of the same intent and each absent by default — an unset key
      # adds no flag, so the container runs unconstrained unless a profile asks
      # otherwise. This bounds the blast radius a `sandbox: none` profile has
      # none of (docs/security.md): a wedged or hostile process in the container
      # is held to the memory, CPU and pid budget the row granted it.
      def resource_limits
        flags = []
        flags.push("--memory", config[:memory].to_s) if config[:memory]
        flags.push("--cpus", config[:cpus].to_s) if config[:cpus]
        flags.push("--pids-limit", config[:pids].to_s) if config[:pids]
        flags
      end

      # `docker run -d` prints the id on stdout, but a run that had to pull
      # first prints progress too, and this capture merges the streams. Picking
      # the last full-length id out of the output is what survives that
      # interleaving; matching the shape is what keeps a progress line from
      # being mistaken for an id.
      def container_id(out) = out.lines.map(&:strip).reverse.find { |line| line.match?(/\A\h{64}\z/) }

      # Where the wrapped command runs. A nil cwd means the caller had no
      # opinion (ctx[:subprocess] defaults it to the host's Dir.pwd, which is
      # an opinion nobody formed) and gets the workspace root.
      #
      # Anything outside the workspace is refused, because it does not exist in
      # the container: `docker exec -w` on an unmounted path fails with the OCI
      # runtime's "chdir to cwd ... no such file or directory" as exit 127,
      # which tells the reader nothing about workspaces. Failing here names the
      # actual problem, and a profile that mounted this row without pointing
      # ctx[:shell] at the workspace learns it from the first command instead
      # of from a stack of 127s.
      def workdir(cwd)
        return @workspace.first if cwd.nil?

        resolved = File.exist?(cwd) ? File.realpath(cwd) : File.expand_path(cwd)
        unless contained?(resolved)
          raise Denied, "#{cwd} is outside the granted workspace, so it does not exist in the container"
        end

        resolved
      end

      # The same trailing-separator guard ctx[:fs] uses: a workspace granted at
      # `/ws` admits `/ws` and anything under `/ws/`, never `/ws-evil`.
      def contained?(path)
        @workspace.any? { |root| path == root || path.start_with?("#{root}/") }
      end

      # Resolved the way ctx[:fs] resolves its roots, and for the same reason:
      # the two services are handed the SAME `workspace:` list by the profile,
      # and if they disagreed about what those directories are named, every
      # path fs produced would be a path the container does not have.
      def resolve_workspace(dirs)
        Array(dirs).map { |d| File.realpath(File.expand_path(d)) }
      end

      # Both streams, one process, no reader threads. Open3 would spawn a
      # thread per stream for what is a short, blocking, once-per-container
      # call, and its output would still have to be merged to be useful in an
      # exception message.
      def capture(argv)
        out = IO.popen(argv, err: [:child, :out], &:read)
        [$?&.exitstatus, out.to_s]
      end
    end
  end
end
