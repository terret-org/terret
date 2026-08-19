# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "pty"
require "securerandom"
require_relative "../lib/terret/sandbox/docker"

# The concurrency test needs a fiber scheduler, because the race it pins is a
# fiber race: the harness runs one reactor and no user-facing threads.
ASYNC_AVAILABLE = begin
  require "async"
  true
rescue LoadError
  false
end unless defined?(ASYNC_AVAILABLE)

# Every test here drives a REAL container. The seam's entire claim is that a
# tool's argv stops running here and starts running somewhere else, and a
# mocked docker would only prove this file can build an array of strings — the
# interesting failures (a bind mount that lands on a different path than the
# one ctx[:fs] hands out, a `-w` docker refuses, stdin that was never
# attached) are all on the far side of the CLI.
#
# The gate on every test is what keeps that affordable: a machine without
# docker skips the suite clean rather than failing it, so `rake test` stays
# runnable everywhere.
class SandboxDockerTest < Minitest::Test
  # Overridable so a machine that would rather not pull ruby:slim can point
  # the suite at an image it already has — any Debian-ish image with bash and
  # getent satisfies these tests.
  IMAGE = ENV.fetch("TERRET_DOCKER_TEST_IMAGE", "ruby:slim")

  # Asked once per process rather than per test: `docker info` is a round-trip
  # to the daemon, and the answer cannot change mid-suite.
  DOCKER = system("docker", "info", out: File::NULL, err: File::NULL)

  def docker? = DOCKER

  def setup
    @plugins = []
    # What was already on this machine before the test. Everything the suite
    # is allowed to remove is measured against this, so a developer running
    # `rake test` beside a real terret container keeps it.
    @preexisting = docker? ? containers_labelled : []
  end

  # Cleanup runs on every path, including a test that failed or raised
  # mid-container: a leaked `sleep infinity` holds a bind mount on the
  # developer's machine until they notice it by hand.
  #
  # The sweep is by LABEL rather than by the ids the provider recorded, and
  # that is the whole point of it — a provider that lost track of a container
  # it started (the fiber race) leaves one nothing can name. Asserting BEFORE
  # the sweep is what keeps the assertion meaningful: the provider's own #stop
  # has to be what cleaned up, and the sweep is only the net that catches what
  # it missed.
  def teardown
    return unless docker?

    @plugins.each do |plugin|
      plugin.stop(nil)
    rescue StandardError
      nil
    end
    leaked = containers_labelled - @preexisting
    leaked.each { |id| system("docker", "rm", "-f", id, out: File::NULL, err: File::NULL) }
    assert_empty leaked, "the provider's own stop left containers behind"
  end

  # `user:` is passed only when the caller names it, so the default path under
  # test is the provider's own default rather than one the harness supplied.
  def boot(workspace:, network: "none", **overrides)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    config = { image: IMAGE, network: network, workspace: Array(workspace) }.merge(overrides)
    loader.layer([{ id: "sandbox", plugin: Terret::Sandbox::Docker, config: config }])
    ctx = loader.boot!
    @plugins << ctx[:sandbox]
    ctx
  end

  # A workspace directory in the shape ctx[:fs] would have resolved it: the
  # realpath, because on macOS Dir.mktmpdir hands back a path under /var and
  # /var is a symlink to /private/var.
  def workspace
    Dir.mktmpdir("terret-docker") { |dir| return yield File.realpath(dir) }
  end

  # `docker ps -a`, so a stopped-but-present container counts as surviving.
  def container_listed?(id)
    out = IO.popen(["docker", "ps", "-aq", "--no-trunc"], err: [:child, :out], &:read)
    out.to_s.lines.any? { |line| line.strip == id }
  end

  # A real spawn of a wrapped argv — the point being that these bytes came
  # back through the docker CLI from another kernel, not from this process.
  def spawn!(argv, stdin: nil)
    out = IO.popen(argv, "r+", err: [:child, :out]) do |io|
      io.write(stdin) if stdin
      io.close_write
      io.read
    end
    [$?&.exitstatus, out.to_s]
  end

  # -- the seam's verdict -----------------------------------------------------

  def test_isolated_is_true
    skip "docker unavailable" unless docker?

    workspace do |ws|
      assert ctx_sandbox(ws).isolated?
    end
  end

  def ctx_sandbox(ws) = boot(workspace: ws)[:sandbox]

  # -- wrap's argv ------------------------------------------------------------

  def test_wrap_builds_a_docker_exec_argv_carrying_the_cwd_and_the_container
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)
      argv = sandbox.wrap(%w[uname -a], cwd: ws)

      assert_equal [sandbox.docker_bin, "exec", "-i", "-w", ws, sandbox.container, "uname", "-a"], argv
    end
  end

  def test_wrap_defaults_the_cwd_to_the_first_workspace_directory
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)
      argv = sandbox.wrap(["pwd"], cwd: nil)

      assert_equal [sandbox.docker_bin, "exec", "-i", "-w", ws, sandbox.container, "pwd"], argv
    end
  end

  # The parallel to ctx[:fs]'s Denied is deliberate: a path outside the granted
  # workspace is refused rather than quietly relocated. Without this the caller
  # gets docker's own "chdir to cwd ... no such file or directory" as exit 127,
  # which says nothing about workspaces.
  def test_wrap_refuses_a_cwd_outside_the_workspace
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)
      e = assert_raises(Terret::Sandbox::Denied) { sandbox.wrap(["pwd"], cwd: "/etc") }

      assert_match(/outside the granted workspace/, e.message)
    end
  end

  def test_wrap_asks_for_a_tty_only_when_the_caller_wants_one
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)

      refute_includes sandbox.wrap(["pwd"], cwd: ws), "-t"
      assert_equal [sandbox.docker_bin, "exec", "-i", "-t", "-w", ws, sandbox.container, "pwd"],
                   sandbox.wrap(["pwd"], cwd: ws, tty: true)
    end
  end

  # -- the container's lifecycle ----------------------------------------------

  def test_the_container_starts_lazily_on_the_first_wrap
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)

      assert_nil sandbox.container, "booting the row must not cost a container"

      sandbox.wrap(["true"], cwd: ws)

      refute_nil sandbox.container
      assert container_listed?(sandbox.container)
    end
  end

  def test_a_second_workspace_ready_reuses_the_running_container
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)
      sandbox.workspace_ready!
      first = sandbox.container
      sandbox.workspace_ready!

      assert_equal first, sandbox.container
      assert_equal [first], containers_labelled - @preexisting,
                   "a second ready! started a second container"
    end
  end

  # The fiber race. `@container ||= run_container!` reads, then parks (the
  # `docker run` capture is blocking IO, which under a scheduler yields the
  # fiber), then assigns — so N fibers reaching their first wrap together each
  # see nil, each start a container, and only the last one to assign is
  # remembered. The rest are orphans: never stopped, `--rm` never fires because
  # `sleep infinity` never exits, and unfindable except by label.
  #
  # This is not a theoretical interleaving. ctx[:subprocess] is built to park
  # the fiber rather than the thread precisely so one reactor can serve many
  # agents, so "several agents' first tool call at once" is the ordinary case,
  # not the pathological one.
  def test_concurrent_first_wraps_start_exactly_one_container
    skip "docker unavailable" unless docker?
    skip "async unavailable" unless ASYNC_AVAILABLE

    workspace do |ws|
      sandbox = ctx_sandbox(ws)
      Sync do
        4.times.map { Async { sandbox.wrap(["true"], cwd: ws) } }.each(&:wait)
      end

      assert_equal [sandbox.container], containers_labelled - @preexisting,
                   "concurrent first wraps started more than one container, and the ones " \
                   "the provider did not record are orphans"
    end
  end

  def containers_labelled
    out = IO.popen(["docker", "ps", "-aq", "--no-trunc", "--filter", "label=terret-sandbox"],
                   err: [:child, :out], &:read)
    out.to_s.lines.map(&:strip).reject(&:empty?)
  end

  def test_stop_removes_the_container
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)
      sandbox.workspace_ready!
      id = sandbox.container

      assert container_listed?(id)

      sandbox.stop(nil)

      refute container_listed?(id), "docker still lists the container after stop"
      assert_nil sandbox.container
    end
  end

  # The dead-container recovery. Without #restart! an operator's `docker rm`
  # (or an OOM, or a daemon restart) leaves the provider holding an id that
  # every later exec answers "No such container" for, with no way back short of
  # remounting the row.
  def test_restart_recovers_from_a_container_removed_underneath_us
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)
      sandbox.workspace_ready!
      dead = sandbox.container
      system("docker", "rm", "-f", dead, out: File::NULL, err: File::NULL)

      # The seam cannot notice on its own; a wrapped exec is how the caller
      # finds out, and it fails against the id the provider is still holding.
      status, out = spawn!(sandbox.wrap(["true"], cwd: ws))

      refute_equal 0, status
      assert_match(/[Nn]o such container/, out)

      sandbox.restart!

      assert_nil sandbox.container

      status, out = spawn!(sandbox.wrap(%w[echo recovered], cwd: ws))

      assert_equal 0, status, out
      assert_equal "recovered\n", out
      refute_equal dead, sandbox.container, "restart! reused the dead container id"
    end
  end

  def test_stop_tolerates_a_container_that_is_already_gone
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)
      sandbox.workspace_ready!
      system("docker", "rm", "-f", sandbox.container, out: File::NULL, err: File::NULL)

      sandbox.stop(nil) # the container left underneath us
      sandbox.stop(nil) # and stop is called twice

      assert_nil sandbox.container
    end
  end

  # -- one world --------------------------------------------------------------

  # The load-bearing claim of the whole gem: ctx[:fs] writes on the host and
  # the container reads the same bytes at the same absolute path, which is what
  # lets the Read/Write/Edit tools stay untouched when the sandbox row swaps.
  def test_a_file_written_on_the_host_is_readable_in_the_container
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)
      File.write(File.join(ws, "host.txt"), "written by the host\n")
      status, out = spawn!(sandbox.wrap(["cat", File.join(ws, "host.txt")], cwd: ws))

      assert_equal 0, status, out
      assert_equal "written by the host\n", out
    end
  end

  def test_a_file_written_in_the_container_is_readable_on_the_host
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)
      status, out = spawn!(sandbox.wrap(["sh", "-c", "echo written by the container > guest.txt"],
                                        cwd: ws))

      assert_equal 0, status, out
      assert_equal "written by the container\n", File.read(File.join(ws, "guest.txt"))
    end
  end

  # -- who the container runs as -----------------------------------------------

  # The reason the default is the host's uid rather than root: on Linux a
  # root-owned file in a read-write bind mount is one ctx[:fs] cannot edit, so
  # the container could create work the host tools then cannot touch. macOS
  # remaps mount ownership and hides it, which is why this asserts the uid
  # directly instead of trusting a write to prove it.
  def test_the_container_runs_as_the_host_user_by_default
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)
      status, out = spawn!(sandbox.wrap(["id", "-u"], cwd: ws))

      assert_equal 0, status, out
      assert_equal Process.uid.to_s, out.strip

      _, gid = spawn!(sandbox.wrap(["id", "-g"], cwd: ws))

      assert_equal Process.gid.to_s, gid.strip
    end
  end

  # The round-trip Task 15 and the soak depend on: the container creates a
  # file and the HOST edits it afterwards, the way ctx[:fs] would.
  def test_a_file_the_container_created_can_be_edited_by_the_host
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)
      status, out = spawn!(sandbox.wrap(["sh", "-c", "echo from-the-container > shared.txt"], cwd: ws))

      assert_equal 0, status, out

      path = File.join(ws, "shared.txt")
      File.write(path, "edited by the host\n") # this is the call that raises EACCES under root

      assert_equal "edited by the host\n", File.read(path)
    end
  end

  # Escape hatch for a profile that needs root inside — apt-get, or installing
  # into the image — stated explicitly rather than reached by accident.
  def test_user_nil_runs_as_root
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = boot(workspace: ws, user: nil)[:sandbox]
      status, out = spawn!(sandbox.wrap(["id", "-u"], cwd: ws))

      assert_equal 0, status, out
      assert_equal "0", out.strip
    end
  end

  # A workspace granted through a symlink must mount and address its realpath,
  # because that is the form ctx[:fs] hands to every tool. Mounting the link's
  # own name instead would make every fs-produced path a path the container
  # does not have.
  def test_a_workspace_reached_through_a_symlink_mounts_its_realpath
    skip "docker unavailable" unless docker?

    workspace do |real|
      Dir.mktmpdir("terret-link") do |parent|
        link = File.join(parent, "link")
        File.symlink(real, link)
        sandbox = ctx_sandbox(link)

        assert_includes sandbox.wrap(["pwd"], cwd: nil), real

        File.write(File.join(real, "through.txt"), "same file\n")
        status, out = spawn!(sandbox.wrap(["cat", "through.txt"], cwd: nil))

        assert_equal 0, status, out
        assert_equal "same file\n", out
      end
    end
  end

  # -- the network ------------------------------------------------------------

  # `getent hosts` is the probe rather than curl or ping: it is in libc-bin so
  # every Debian-ish image has it, it needs no network stack to answer, and
  # under `--network none` it FAILS FAST (exit 2, measured at 35ms) because
  # there is no interface to try rather than a route that has to time out. A
  # probe that hangs for a DNS timeout would make this test's failure mode
  # indistinguishable from a slow machine.
  def test_the_container_cannot_resolve_a_name_when_the_network_is_none
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)
      status, out = spawn!(sandbox.wrap(["getent", "hosts", "example.com"], cwd: ws))

      refute_equal 0, status, "name resolution succeeded under --network none: #{out}"
    end
  end

  def test_the_container_has_only_a_loopback_interface
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)
      status, out = spawn!(sandbox.wrap(["ls", "/sys/class/net"], cwd: ws))

      assert_equal 0, status, out
      assert_equal ["lo"], out.split
    end
  end

  # -- the tty flag, and what it buys -----------------------------------------

  # This is the evidence behind `-t`. ctx[:shell] drives bash over a PTY and
  # promises its Result#stdout is exactly the command's output: no echo of the
  # request line, and in particular no sighting of the session sentinel, which
  # is the value the protocol's forgery resistance rests on.
  #
  # Without `-t` the container gives bash a pipe, so bash is non-interactive
  # and the handshake's `stty -echo` has no terminal to quiet — while the HOST
  # pty that PTY.spawn made is still echoing every byte written to it. The
  # request line (sentinel and all) comes back inside stdout. With `-t` the
  # docker CLI puts the host pty in raw mode and gives the container a real
  # terminal, so `stty -echo` lands and stdout is exact.
  #
  # The protocol is reproduced here rather than driven through ctx[:shell] on
  # purpose: this gem provides the seam and does not depend on terret-exec, and
  # a sandbox that needed the consumer's code to test itself would be the wrong
  # shape.
  def test_a_tty_wrapped_pty_session_keeps_stdout_exact
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)
      argv = sandbox.wrap(%w[bash --norc --noprofile --noediting -s], cwd: ws, tty: true)
      sentinel = "TERRET#{SecureRandom.hex(16)}"
      marker = Regexp.new("#{sentinel}(\\d+)\\r?\\n")
      reader, writer, pid = PTY.spawn(*argv)
      writer.sync = true

      begin
        ask = lambda do |cmd|
          writer.write("#{cmd}\nprintf '%s%s\\n' '#{sentinel}' \"$?\"\n")
          read_to(reader, marker)
        end
        ask.call("stty -echo -onlcr -icanon -ixon min 1 time 0 2>/dev/null; set +m; PS1=; PS2=")
        status, out = ask.call("echo one-world; uname")

        assert_equal 0, status
        assert_equal "one-world\nLinux\n", out
        refute_includes out, sentinel, "the session sentinel leaked into stdout"
      ensure
        [writer, reader].each { |io| io.close unless io.closed? }
        Process.kill("KILL", pid)
        Process.wait(pid)
      end
    end
  end

  # Reads until the marker or a deadline. Returns [status, output-before-it].
  def read_to(reader, marker, timeout: 20)
    buf = String.new(encoding: Encoding::BINARY)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      if (m = marker.match(buf))
        return [Integer(m[1]), buf.byteslice(0, m.begin(0)).force_encoding(Encoding::UTF_8)]
      end
      raise "the shell never answered: #{buf.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      chunk = reader.read_nonblock(4096, exception: false)
      raise "the shell ended: #{buf.inspect}" if chunk.nil?

      chunk == :wait_readable ? sleep(0.01) : buf << chunk.b
    end
  rescue Errno::EIO
    raise "the shell ended: #{buf.inspect}"
  end

  # -- config -----------------------------------------------------------------

  # A live image or network swap is a remount: the container is already
  # running on the old image with the old mounts, and nothing short of
  # replacing it would apply the new row.
  def test_reconfigure_says_the_row_needs_a_remount
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)
      out, err = capture_io { sandbox.reconfigure({ image: "other:latest" }) }

      assert_empty out
      assert_match(/remount/, err)
    end
  end

  # -- the control plane, without a daemon ------------------------------------
  #
  # These drive the argv-building and disposal logic directly, so they run
  # everywhere rather than gating on `docker?`. A stand-in for the daemon:
  # run_container! hands back a fake id instead of starting anything, and
  # remove_container is a stub the discard! tests fail on demand.
  class FakelessDocker < Terret::Sandbox::Docker
    attr_accessor :rm_result

    def run_container! = "0" * 64
    def remove_container(_id) = rm_result || [0, ""]
  end

  def boot_fake(workspace:, **overrides)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    config = { image: IMAGE, network: "none", workspace: Array(workspace) }.merge(overrides)
    loader.layer([{ id: "sandbox", plugin: FakelessDocker, config: config }])
    loader.boot![:sandbox]
  end

  # A bare `docker` in argv[0] is resolved by the exec against PATH, so a
  # workspace directory that happens to sit on PATH could shadow it with a
  # binary the agent controls. Resolving to an absolute path at start closes
  # that.
  def test_wrap_resolves_docker_to_an_absolute_path
    workspace do |ws|
      sandbox = boot_fake(workspace: ws)
      argv = sandbox.wrap(["true"], cwd: ws)

      assert_equal sandbox.docker_bin, argv.first
      assert File.absolute_path?(argv.first), "wrap's argv[0] must be absolute, not a bare name"
    end
  end

  def test_a_docker_bin_config_override_is_honored
    workspace do |ws|
      sandbox = boot_fake(workspace: ws, docker_bin: "/opt/custom/docker")
      argv = sandbox.wrap(["true"], cwd: ws)

      assert_equal "/opt/custom/docker", argv.first
    end
  end

  # A genuine `docker rm -f` failure means `sleep infinity` may still be up
  # holding its bind mount, so discard! must surface it and keep the id rather
  # than clearing it and returning a quiet success.
  def test_discard_surfaces_a_failed_removal_instead_of_swallowing_it
    workspace do |ws|
      sandbox = boot_fake(workspace: ws)
      sandbox.workspace_ready!
      id = sandbox.container
      sandbox.rm_result = [1, "Error response from daemon: could not remove #{id}"]

      _out, err = capture_io { sandbox.stop(nil) }

      assert_match(/failed/, err, "a failed removal must be surfaced")
      assert_includes err, id, "the surfaced failure must name the container id"
      assert_equal id, sandbox.container, "a failed removal must not silently drop the id"
    end
  end

  # The mirror: a container the daemon already dropped (the ordinary `--rm`
  # case) answers "No such container", which is success — the id is cleared
  # and nothing is warned.
  def test_discard_treats_an_already_gone_container_as_removed
    workspace do |ws|
      sandbox = boot_fake(workspace: ws)
      sandbox.workspace_ready!
      sandbox.rm_result = [1, "Error: No such container: #{sandbox.container}"]

      _out, err = capture_io { sandbox.stop(nil) }

      assert_empty err, "an already-gone container is not a failure to surface"
      assert_nil sandbox.container
    end
  end
end
