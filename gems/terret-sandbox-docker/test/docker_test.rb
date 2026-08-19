# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "pty"
require "securerandom"
require_relative "../lib/terret/sandbox/docker"

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

  def docker? = system("docker", "info", out: File::NULL, err: File::NULL)

  def setup
    @plugins = []
  end

  # Cleanup runs on every path, including a test that failed or raised
  # mid-container: a leaked `sleep infinity` holds a bind mount on the
  # developer's machine until they notice it by hand. The teardown asserts the
  # sweep worked rather than assuming it, so a provider whose #stop silently
  # does nothing fails the suite instead of littering.
  def teardown
    ids = @plugins.filter_map(&:container)
    @plugins.each do |plugin|
      plugin.stop(nil)
    rescue StandardError
      nil
    end
    ids.each { |id| system("docker", "rm", "-f", id, out: File::NULL, err: File::NULL) }
    survivors = ids.select { |id| container_listed?(id) }
    assert_empty survivors, "containers survived the test and are still on this machine"
  end

  def boot(workspace:, network: "none")
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([{ id: "sandbox", plugin: Terret::Sandbox::Docker,
                    config: { image: IMAGE, network: network, workspace: Array(workspace) } }])
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

      assert_equal ["docker", "exec", "-i", "-w", ws, sandbox.container, "uname", "-a"], argv
    end
  end

  def test_wrap_defaults_the_cwd_to_the_first_workspace_directory
    skip "docker unavailable" unless docker?

    workspace do |ws|
      sandbox = ctx_sandbox(ws)
      argv = sandbox.wrap(["pwd"], cwd: nil)

      assert_equal ["docker", "exec", "-i", "-w", ws, sandbox.container, "pwd"], argv
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
      assert_equal ["docker", "exec", "-i", "-t", "-w", ws, sandbox.container, "pwd"],
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
      assert_equal 1, containers_labelled.count { |id| id == first }
      assert_equal 1, containers_labelled.length, "a second ready! started a second container"
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
end
