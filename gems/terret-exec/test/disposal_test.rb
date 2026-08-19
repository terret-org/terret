# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/terret/exec"

# A disposed agent's forked context reaps its own registrations, but the
# runtime process state its tool calls created — ctx[:shell]'s bash,
# ctx[:terminals]' PTYs, ctx[:jobs]' background processes — is root-mounted and
# keyed by the agent's session, so nothing in fork disposal reaps it. Without
# the agent/disposed reaping wired up, every disposed agent leaks a bash
# (backgrounded jobs and all) plus a PTY per terminal plus every job it
# started, unboundedly. This exercises the whole loop -> exec path.
class DisposalTest < Minitest::Test
  def boot(workspace:)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions",   plugin: Terret::Sessions },
      { id: "prompt",     plugin: Terret::Prompt },
      { id: "tools",      plugin: Terret::Tools::Registry },
      { id: "sandbox",    plugin: Terret::Exec::SandboxNone },
      { id: "subprocess", plugin: Terret::Exec::Subprocess },
      { id: "shell",      plugin: Terret::Exec::Shell },
      { id: "terminals",  plugin: Terret::Exec::Terminals },
      { id: "jobs",       plugin: Terret::Exec::Jobs },
      { id: "llm",  plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop", plugin: Terret::Loop }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new([]))
    [ctx, loader]
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # A reaped bash is waited on synchronously; a swept background grandchild is
  # reparented and reaped by the OS, so it dies within a beat rather than at
  # this instant.
  def refute_alive_within(pid, timeout: 3.0)
    deadline = now + timeout
    sleep 0.02 while alive?(pid) && now < deadline
    refute alive?(pid), "pid #{pid} should have been reaped on disposal"
  end

  # A zombie still answers kill(0), so #alive? cannot see the state a finished
  # job is left in: the harness never waited on it, so it sits in the process
  # table until something collects it.
  def zombie?(pid) = `ps -o stat= -p #{pid} 2>/dev/null`.strip.start_with?("Z")

  def await(path, timeout: 5)
    deadline = now + timeout
    sleep 0.02 while !File.exist?(path) && now < deadline
    assert File.exist?(path), "the job never reached #{path}"
    Integer(File.read(path))
  end

  def test_disposing_an_agent_reaps_its_shell_and_terminals
    Dir.mktmpdir do |ws|
      ctx, = boot(workspace: [ws])
      session = ctx[:sessions].create
      agent = ctx[:loop].spawn_agent(session_id: session.id)
      sid = agent.session_id

      # a persistent bash with a backgrounded child, plus two long-lived PTYs
      res = ctx[:shell].run("sleep 300 & echo BG=$!", session: sid)
      bg_pid = Integer(res.stdout[/BG=(\d+)/, 1])
      bash_pid = ctx[:shell].pid(session: sid)
      t1 = ctx[:terminals].open("repl", ["sleep", "300"], session: sid)
      t2 = ctx[:terminals].open("srv", ["sleep", "300"], session: sid)

      assert alive?(bash_pid)
      assert alive?(bg_pid)
      assert alive?(t1.pid)
      assert alive?(t2.pid)

      ctx[:loop].dispose_agent(agent.id)

      refute_alive_within(bash_pid)
      refute_alive_within(bg_pid) # the whole session process group goes down
      refute_alive_within(t1.pid)
      refute_alive_within(t2.pid)
      assert_nil ctx[:shell].pid(session: sid), "the shell session is no longer registered"
    end
  end

  # Jobs are the third piece of per-agent process state, and the only one that
  # can already be a corpse when disposal arrives: a job that finished on its
  # own was never waited on, so it is an unreaped zombie alone in its process
  # group, and Darwin answers a signal aimed at that group with EPERM. One
  # raise there is isolated by emit — which means the agent is disposed while
  # every job behind it in the ledger keeps running, holding the agent's
  # authority with nothing left in the harness able to name it.
  def test_disposing_an_agent_reaps_its_jobs_including_one_that_already_finished
    Dir.mktmpdir do |ws|
      ctx, = boot(workspace: [ws])
      session = ctx[:sessions].create
      agent = ctx[:loop].spawn_agent(session_id: session.id)
      sid = agent.session_id

      ctx[:jobs].start("echo $$ > #{ws}/done", session: sid) # finishes, and nobody collects it
      finished = await("#{ws}/done")
      deadline = now + 5
      sleep 0.02 while !zombie?(finished) && now < deadline
      ctx[:jobs].start("echo $$ > #{ws}/live; sleep 300", session: sid)
      live = await("#{ws}/live")

      assert zombie?(finished), "the finished job was never left unreaped; this is not the case"
      assert alive?(live)

      ctx[:loop].dispose_agent(agent.id)

      refute_alive_within(live)
      refute zombie?(finished), "the finished job's child must be reaped, not left in the table"
    end
  end

  # Disposal must complete even when a reaping listener raises: emit isolates it.
  def test_disposal_completes_when_an_agent_disposed_listener_raises
    Dir.mktmpdir do |ws|
      ctx, = boot(workspace: [ws])
      session = ctx[:sessions].create
      agent = ctx[:loop].spawn_agent(session_id: session.id)
      sid = agent.session_id
      ctx[:shell].run("true", session: sid)
      bash_pid = ctx[:shell].pid(session: sid)

      ctx.on("agent/disposed") { |_sid| raise "boom" }

      ctx[:loop].dispose_agent(agent.id) # must not raise
      refute_alive_within(bash_pid) # and the real reaper still ran
      assert_nil ctx[:loop].agent(agent.id)
    end
  end
end
