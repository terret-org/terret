# frozen_string_literal: true

require "minitest/autorun"
require "rbconfig"
require "tmpdir"
require_relative "../lib/terret/tools_std"
require_relative "../../terret-exec/lib/terret/exec" # the seam these tools stand on

class JobToolsTest < Minitest::Test
  RUBY = RbConfig.ruby
  ROSTER = %w[job_start job_collect job_stop].freeze

  def boot(config: {}, jobs_config: {}, extra_rows: [])
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "sandbox", plugin: Terret::Exec::SandboxNone },
      { id: "subprocess", plugin: Terret::Exec::Subprocess },
      { id: "jobs", plugin: Terret::Exec::Jobs, config: jobs_config },
      { id: "tools", plugin: Terret::Tools::Registry },
      { id: "std_jobs", plugin: Terret::ToolsStd::Jobs, config: config },
      *extra_rows
    ])
    ctx = loader.boot!
    @booted << ctx
    [ctx, loader]
  end

  def setup = @booted = []

  # A job is a live process held across turns, so a test that fails part-way
  # through must still not leak one into the rest of the suite.
  def teardown
    @booted.each { |ctx| ctx[:jobs].stop_all if ctx.service?(:jobs) }
  end

  def call(ctx, name, session_id: "s1", **args)
    ctx[:tools].execute(
      Terret::Tools::Call.new(id: "c1", name: name, args: args, session_id: session_id), ctx: ctx
    )
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # A job the harness spawned and never waited on is an unreaped zombie from
  # the moment it exits. `ps` is the only portable way to see that: a zombie
  # answers kill(0) exactly as a running process does.
  def zombie?(pid) = `ps -o stat= -p #{pid} 2>/dev/null`.strip.start_with?("Z")

  def start_job(ctx, command, session_id: "s1")
    result = call(ctx, "job_start", session_id: session_id, command: command)
    assert_nil result.error
    id = result.content[/job (\S+)$/, 1]
    refute_nil id, "job_start must name the job it started: #{result.content.inspect}"
    [id, result]
  end

  # Bounded, like the seam's own tests: a job that never says the expected
  # thing fails the assertion instead of hanging the suite.
  #
  # The body accumulates across windows and the remarks are the newest ones,
  # which together are what the model would have read had the whole thing
  # arrived in one collect. A collect DRAINS, so a job whose output and whose
  # exit land in different windows can never satisfy a predicate over a single
  # one — and which side of that boundary they fall on is a matter of timing,
  # which makes it a flake rather than a test.
  def collect_until(ctx, id, session_id: "s1", timeout: 5)
    deadline = now + timeout
    body = +""
    loop do
      content = call(ctx, "job_collect", session_id: session_id, id: id).content.to_s
      # The last ledger line is the genuine one — a job can print the literal
      # itself, and the remarks are always after it.
      chunk, _, remarks = content.rpartition("\n#{Terret::ToolsStd::Jobs::LEDGER}\n")
      body << chunk unless chunk.empty? || chunk == "(no new output)"
      whole = "#{body.empty? ? '(no new output)' : body}\n" \
              "#{Terret::ToolsStd::Jobs::LEDGER}\n#{remarks}"
      return whole if yield whole
      flunk "the job never said what this test is about: #{whole.inspect}" if now > deadline

      sleep 0.02
    end
  end

  # -- what the definitions claim ---------------------------------------------

  def test_the_roster_is_the_three_job_tools
    ctx, = boot
    assert_equal ROSTER.sort, ctx[:tools].schemas.map { |s| s[:name] }.sort
  end

  # The two that spawn or signal a process are mutating and governed by
  # policy; reading a buffer asks nobody, which is what lets a subagent watch
  # a job it could not have started.
  def test_the_three_tools_declare_the_metadata_the_contract_names
    ctx, = boot
    start = ctx[:tools].fetch("job_start")
    assert start.mutating
    assert_equal :policy, start.approval
    assert_equal :serial, start.concurrency

    collect = ctx[:tools].fetch("job_collect")
    refute collect.mutating
    assert_equal :never, collect.approval
    assert_equal :parallel, collect.concurrency

    stop = ctx[:tools].fetch("job_stop")
    assert stop.mutating
    assert_equal :policy, stop.approval
    assert_equal :serial, stop.concurrency
  end

  def test_job_start_takes_a_command_string_like_bash_does
    ctx, = boot
    params = ctx[:tools].fetch("job_start").params
    assert_equal %w[command], Array(params[:required]).map(&:to_s)
    assert_equal "string", params.dig(:properties, :command, :type)
  end

  def test_collect_and_stop_take_the_job_id
    ctx, = boot
    %w[job_collect job_stop].each do |name|
      params = ctx[:tools].fetch(name).params
      assert_equal %w[id], Array(params[:required]).map(&:to_s), name
      assert_equal "string", params.dig(:properties, :id, :type), name
    end
  end

  # Crash recovery is at-least-once, and for job_start that means resume
  # starts a SECOND job. The harness does not detect it and does not claim to,
  # so the model has to be told where to look.
  def test_job_starts_description_says_a_resumed_call_starts_a_second_job
    ctx, = boot
    description = ctx[:tools].fetch("job_start").description
    assert_match(/second job/i, description)
    assert_match(/job_collect/, description)
  end

  def test_the_registrations_die_with_the_row_that_made_them
    ctx, loader = boot
    refute_empty ctx[:tools].schemas

    loader.unload!("std_jobs")
    assert_empty ctx[:tools].schemas, "a tool registered by a plugin row must not outlive the row"
  end

  # -- end to end -------------------------------------------------------------

  def test_start_collect_and_stop_drive_a_real_background_job
    ctx, = boot
    id, started = start_job(ctx, "printf working; sleep 30")
    assert_match(/--- terret ---\njob #{Regexp.escape(id)}\z/, started.content)

    assert_match(/\Aworking\n--- terret ---/, collect_until(ctx, id) { |c| c.start_with?("working") })

    stopped = call(ctx, "job_stop", id: id)
    assert_nil stopped.error
    assert_match(/#{Regexp.escape(id)}/, stopped.content)

    after = call(ctx, "job_collect", id: id)
    assert_match(/stopped/i, after.content)
  end

  # The seam's zombie case, seen from the tool. A job that finished on its own
  # and was never collected sits unreaped in a process group whose only member
  # is itself, and the EPERM Darwin answers a signal to that group with used to
  # come back to the model as the result of job_stop. There is no blanket
  # rescue in this layer — an errno arriving here would mean the seam let one
  # out — so this is the test that says it does not.
  def test_stopping_a_job_that_already_finished_is_not_an_errno_the_model_has_to_read
    Dir.mktmpdir do |dir|
      ctx, = boot
      path = File.join(dir, "pid")
      id, = start_job(ctx, "echo $$ > #{path}")
      deadline = now + 5
      sleep 0.02 while !File.exist?(path) && now < deadline
      pid = Integer(File.read(path))
      # never collected, so nothing has waited on it: it stays a zombie
      sleep 0.02 while !zombie?(pid) && now < deadline
      assert zombie?(pid), "the job never became an unreaped zombie; this is not the case"

      result = call(ctx, "job_stop", id: id)

      assert_nil result.error
      assert_match(/#{Regexp.escape(id)}/, result.content)
      refute_match(/Errno|EPERM|Operation not permitted/, result.content)
      refute zombie?(pid), "and the stop collected the child it ended"
    end
  end

  def test_a_job_with_nothing_new_to_say_says_so_and_reports_that_it_is_running
    ctx, = boot
    id, = start_job(ctx, "sleep 30")

    content = call(ctx, "job_collect", id: id).content
    assert_match(/\(no new output\)/, content)
    assert_match(/still running/, content)
  end

  # The output and the exit are deliberately far enough apart that a collect
  # lands between them: the body arrives in a window that still says "running",
  # and the window that reports the exit has nothing new to say. Both halves
  # are the result, so the assertion is over both.
  def test_a_finished_job_reports_its_exit_status_in_the_ledger
    ctx, = boot
    id, = start_job(ctx, "printf done; sleep 0.4; exit 7")

    content = collect_until(ctx, id) { |c| c.include?("exited") }
    assert_match(/\Adone\n--- terret ---\n/, content)
    assert_match(/exited with status 7/, content)
  end

  def test_a_second_collect_returns_only_what_arrived_after_the_first
    ctx, = boot
    id, = start_job(ctx, "printf one; sleep 0.3; printf two; sleep 30")

    collect_until(ctx, id) { |c| c.start_with?("one") }
    assert_match(/\Atwo\n/, collect_until(ctx, id) { |c| c.start_with?("two") })
  end

  # The seam's cap is a memory bound; this one is a display decision, the
  # tool's own honest cap, exactly as Bash's is.
  def test_output_past_the_tools_cap_is_truncated_and_the_result_says_so
    ctx, = boot(config: { max_output: 20 })
    id, = start_job(ctx, "#{RUBY} -e 'print \"z\" * 100'; sleep 30")

    content = collect_until(ctx, id) { |c| c.start_with?("z") }
    assert_match(/\Az{20}\n--- terret ---/, content)
    assert_match(/kept the first 20 bytes/, content)
    assert_match(/dropped 80 more/, content)
    assert_match(/gone rather than waiting/, content,
                 "this collect drained the buffer, so the dropped bytes are not coming later")
  end

  # The other cap, and a different loss: these bytes never reached the tool at
  # all, because the seam's buffer dropped them on the way in. Reported as its
  # own remark for that reason — a model told only "truncated" would not know
  # which end of the pipe it lost them at.
  def test_output_the_seam_dropped_before_it_could_be_collected_is_its_own_remark
    ctx, = boot(jobs_config: { max_output: 32 })
    id, = start_job(ctx, "#{RUBY} -e 'print \"q\" * 500'; sleep 30")

    content = collect_until(ctx, id) { |c| c.start_with?("q") }
    assert_match(/\Aq{32}\n--- terret ---/, content, "the seam's cap is kept exactly")
    assert_match(/dropped before it could be collected/, content)
    refute_match(/output truncated at max_output/, content,
                 "the display cap was never reached; only the buffer's was")
  end

  # -- failing closed ---------------------------------------------------------

  def test_collecting_an_unknown_job_is_a_refusal_a_model_can_read
    ctx, = boot
    result = call(ctx, "job_collect", id: "job-nope")

    assert_nil result.content
    assert_match(/job-nope/, result.error)
    refute_match(/Terret|Failure|Errno/, result.error, "a Failure renders message-only")
  end

  def test_one_session_cannot_collect_or_stop_anothers_job
    ctx, = boot
    id, = start_job(ctx, "sleep 30", session_id: "agent-a")

    %w[job_collect job_stop].each do |name|
      result = call(ctx, name, session_id: "agent-b", id: id)
      assert_nil result.content, name
      assert_match(/no job/, result.error, name)
    end
    assert_match(/still running/, call(ctx, "job_collect", session_id: "agent-a", id: id).content)
  end

  def test_starting_past_the_cap_is_refused_with_the_limit_that_bit
    ctx, = boot(jobs_config: { max_jobs: 1 })
    start_job(ctx, "sleep 30")

    result = call(ctx, "job_start", command: "sleep 30")
    assert_nil result.content
    assert_match(/max_jobs: 1/, result.error)
  end

  # A model that writes the wrong shape gets a sentence it can act on rather
  # than a keyword error that costs it the whole turn.
  def test_a_command_that_is_not_a_string_is_refused_before_anything_is_spawned
    ctx, = boot
    result = call(ctx, "job_start", command: ["sleep", "30"])

    assert_nil result.content
    assert_match(/command/, result.error)
    refute_match(/TypeError|NoMethodError/, result.error)
  end

  def test_an_omitted_command_is_a_readable_result_rather_than_an_argument_error
    ctx, = boot
    result = call(ctx, "job_start")

    assert_nil result.content
    assert_match(/command/, result.error)
    refute_match(/ArgumentError/, result.error)
  end

  # The refusal names the tool that needed the id, the way the command refusal
  # names job_start: "this tool" is not something a model can act on when it
  # has four calls in flight.
  def test_a_missing_id_is_refused_by_the_tool_that_needed_it
    ctx, = boot
    %w[job_collect job_stop].each do |name|
      result = call(ctx, name)
      assert_nil result.content, name
      assert_match(/\A#{name} needs the job id/, result.error, name)
    end
  end

  # -- bytes a job wrote that are not text ------------------------------------

  # The session log refuses invalid UTF-8 at the durable append boundary, and
  # the seam deliberately preserves whatever the job wrote. Scrubbing is this
  # layer's job, and the proof is the append itself.
  def test_collecting_invalid_utf8_still_produces_a_storable_result
    rows = [{ id: "session_store", plugin: Terret::Store::Memory },
            { id: "sessions", plugin: Terret::Sessions }]
    ctx, = boot(extra_rows: rows)
    id, = start_job(ctx, "printf '\\xff\\xfe'; sleep 30")

    content = collect_until(ctx, id) { |c| !c.start_with?("(no new output)") }
    assert content.valid_encoding?, "the tool's result must be storable text"
    session = ctx[:sessions].create
    ctx[:sessions].append(session.id, "tool/result", { id: "c1", content: content, error: nil })
    assert_equal content, ctx[:sessions].fetch(session.id).events.last.payload[:content]
  end
end

# What a delegated agent can and cannot do with a job. docs/subagents.md §6
# decides both halves: job_start and job_stop are :policy, so a child — which
# no human can be asked about — is denied rather than parked; job_collect asks
# nobody and runs.
class JobToolsFromASubagentTest < Minitest::Test
  def boot(script:, extra_rows: [])
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
      { id: "jobs",       plugin: Terret::Exec::Jobs },
      { id: "std_jobs",   plugin: Terret::ToolsStd::Jobs },
      { id: "llm",  plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop", plugin: Terret::Loop },
      { id: "subagents", plugin: Terret::Subagents },
      { id: "std_task",  plugin: Terret::ToolsStd::Task },
      *extra_rows
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))
    @booted << ctx
    [ctx, loader]
  end

  def setup = @booted = []

  def teardown
    @booted.each { |ctx| ctx[:jobs].stop_all if ctx.service?(:jobs) }
  end

  def delegate(ctx, prompt: "watch it")
    session = ctx[:sessions].create
    parent = ctx[:loop].spawn_agent(session_id: session.id, id: "parent")
    result = ctx[:tools].execute(
      Terret::Tools::Call.new(id: "t1", name: "Task", session_id: session.id,
                              args: { description: "watch", prompt: prompt }),
      ctx: parent.ctx
    )
    [result, session, result.content[/child session (\S+)$/, 1]]
  end

  def child_result(ctx, child_id)
    ctx[:sessions].fetch(child_id).events.find { |e| e.type == "tool/result" }.payload
  end

  # §6 says a subagent cannot start a job where approvals are mounted: the
  # gate denies rather than parking on a verdict nobody can give.
  def test_a_child_cannot_start_a_job
    start = Terret::LLM::ToolCall.new(id: "c1", name: "job_start", args: { command: "sleep 30" })
    ctx, = boot(script: [{ text: "Starting it.", tool_calls: [start] },
                         { text: "I was not allowed to start it." }],
                extra_rows: [{ id: "approvals", plugin: Terret::Tools::Approvals }])

    result, _session, child_id = delegate(ctx)

    assert_nil result.error
    assert_equal "job_start denied: no approver can reach a subagent session",
                 child_result(ctx, child_id)[:error]
  end

  # A job's ledger is keyed by the session that started it, and a child's
  # session is fresh (§2) — so the id its parent hands it names nothing it can
  # reach. The isolation is the half of §6 the code keeps: without a lineage
  # link the runtime does not have, "another session" and "my parent" are the
  # same shape, and one of them is another agent's live process.
  def test_a_child_collecting_its_parents_job_is_refused_by_the_session_check
    ctx, = boot(script: [])
    session = ctx[:sessions].create
    parent = ctx[:loop].spawn_agent(session_id: session.id, id: "parent")
    id = ctx[:jobs].start("printf parent-job; sleep 30", session: session.id)

    collect = Terret::LLM::ToolCall.new(id: "c1", name: "job_collect", args: { id: id })
    ctx[:llm].register_adapter(
      "fake", Terret::LLM::FakeAdapter.new([{ text: "Collecting.", tool_calls: [collect] },
                                            { text: "I could not read that job." }])
    )
    result = ctx[:tools].execute(
      Terret::Tools::Call.new(id: "t1", name: "Task", session_id: session.id,
                              args: { description: "watch", prompt: "watch it" }),
      ctx: parent.ctx
    )

    child_id = result.content[/child session (\S+)$/, 1]
    assert_match(/no job/, child_result(ctx, child_id)[:error])
    assert_equal :running, ctx[:jobs].collect(id, session: session.id)[:status],
                 "and the parent's own job is untouched"
  end

  # The two halves side by side, without the delegation machinery in the way:
  # `unattended` is what makes an agent a child, and it is what the gate reads.
  # The start is denied because no human can be asked; the collect runs because
  # nothing about it asks one.
  def test_an_unattended_agent_is_denied_job_start_and_allowed_job_collect
    ctx, = boot(script: [], extra_rows: [{ id: "approvals", plugin: Terret::Tools::Approvals }])
    session = ctx[:sessions].create
    child = ctx[:loop].spawn_agent(session_id: session.id, id: "child")
    child.unattended = true
    id = ctx[:jobs].start("printf child-job; sleep 30", session: session.id)

    started = ctx[:tools].execute(
      Terret::Tools::Call.new(id: "c1", name: "job_start", args: { command: "sleep 30" },
                              session_id: session.id), ctx: child.ctx
    )
    assert_equal "job_start denied: no approver can reach a subagent session", started.error

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    content = nil
    loop do
      collected = ctx[:tools].execute(
        Terret::Tools::Call.new(id: "c2", name: "job_collect", args: { id: id },
                                session_id: session.id), ctx: child.ctx
      )
      assert_nil collected.error, "job_collect asks nobody, so an unattended agent reads fine"
      content = collected.content
      break if content.include?("child-job") ||
               Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
    assert_match(/child-job/, content)
  end
end
