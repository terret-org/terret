# frozen_string_literal: true
# M8 end to end: a subagent, a background job, a todo list, and the tool
# barrier — narrated in acts like lifecycle_demo and exec_demo, offline.
#
#   act 1  a parent delegates to a subagent via Task. The child runs its own
#          two-step turn (a tool call, then a final reply) drawn from the
#          SAME FakeAdapter script queue as the parent's, on a fresh session.
#          The parent's log gains no new durable event type — only the
#          ordinary tool/call and tool/result every tool call already writes
#          — and the ledger line naming the child's session id is the only
#          thread from one transcript to the other (docs/subagents.md §§2-4).
#   act 2  a real background process: job_start, then two job_collects
#          showing output accumulate across the calls and the exit status
#          land in the ledger (docs/subagents.md §6).
#   act 3  TodoWrite renders the checklist back as its own tool result — the
#          rendered list is the whole of its storage (docs/subagents.md §7).
#   act 4  two job_collect calls in ONE assistant message, proving the tool
#          barrier (docs/subagents.md §5): the log shows both tool/calls
#          appended before EITHER tool/result, a shape two ordinary serial
#          calls could never produce (they interleave call, result, call,
#          result). That is dispatched as one run whether or not a reactor is
#          mounted to run it (Loop#execute_together falls back to one call at
#          a time without one) — so this demo stays reactor-free and proves
#          the ORDERING/BATCHING guarantee the log makes, not measured
#          wall-clock overlap. Requiring `async` just to watch two instant
#          `printf`s finish concurrently would buy nothing this act needs.
#
# FakeAdapter + an in-memory session store. No network, no docker.
#
#   ruby examples/subagent_demo.rb

require "securerandom"
require_relative "../gems/terret-core/lib/terret"
require_relative "../gems/terret-exec/lib/terret/exec"           # sandbox-none, subprocess, jobs
require_relative "../gems/terret-tools-std/lib/terret/tools_std" # Task, job_*, TodoWrite

Terret.declare_events!

CHECKS = []

def section(title) = puts "\n== #{title}"
def note(msg)       = puts "   #{msg}"
def now             = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def trim(str, limit = 160)
  s = str.to_s
  s.length > limit ? "#{s[0, limit]}…(+#{s.length - limit} more)" : s
end

# Recorded rather than raised inline, so one act's surprise doesn't hide
# whatever the later acts would have said too.
def check(desc, cond) = CHECKS << [desc, !!cond]

def call_tool(ctx, name, session_id:, **args)
  ctx[:tools].execute(
    Terret::Tools::Call.new(id: "c-#{SecureRandom.hex(3)}", name: name, args: args, session_id: session_id),
    ctx: ctx
  )
end

# Collects until the accumulated body satisfies the block, folding each
# window's output into a running total the way jobs_tools_test's own helper
# does — a collect DRAINS, so the exit status and the last bytes a job wrote
# can land in different windows, and checking only the latest one is how a
# passing demo becomes a flaky one.
def collect_until(ctx, session_id, job_id, timeout: 5)
  deadline = now + timeout
  body = +""
  loop do
    content = call_tool(ctx, "job_collect", session_id: session_id, id: job_id).content.to_s
    chunk, _, remarks = content.rpartition("\n#{Terret::ToolsStd::Jobs::LEDGER}\n")
    body << chunk unless chunk.empty? || chunk == "(no new output)"
    whole = "#{body.empty? ? '(no new output)' : body}\n#{Terret::ToolsStd::Jobs::LEDGER}\n#{remarks}"
    return whole if yield(whole)

    raise "job #{job_id} never said what this demo needed (last: #{whole.inspect})" if now > deadline

    sleep 0.02
  end
end

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
  { id: "std_todo",   plugin: Terret::ToolsStd::Todo },
  { id: "llm",  plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
  { id: "loop", plugin: Terret::Loop },
  { id: "subagents", plugin: Terret::Subagents },
  { id: "std_task",  plugin: Terret::ToolsStd::Task }
])
ctx = loader.boot!

ctx.with_owner("demo-tools") do
  ctx[:tools].register(name: "check_status", description: "Check a service's health",
                       params: { service: "string" }) do |service:|
    "#{service}: healthy (uptime 14d, p99 82ms)"
  end
end

# A live render of every session's event stream, tagged by a short label so a
# child's turn is visibly nested inside the parent's tool/call — chunks are
# UI/replay fidelity (docs/lifecycle.md), not part of the story, so they're
# skipped here the way subagents_test's own assertions skip them too.
PARENT_ID = "parent"
labels = { PARENT_ID => "parent" }
ctx.on("session/event") do |ev|
  next if ev.type == "assistant/chunk"

  tag = labels[ev.session_id] ||= "child-#{labels.size}"
  summary = ev.payload.map { |k, v| "#{k}=#{trim(v.inspect, 90)}" }.join(" ")
  puts format("   [%-8s] %-13s %s", tag, ev.type, summary)
end

parent_session = ctx[:sessions].create(id: PARENT_ID)
parent = ctx[:loop].spawn_agent(session_id: parent_session.id, id: PARENT_ID)

# == act 1: a parent delegates to a subagent via Task =======================
section "act 1: a parent delegates to a subagent (Task)"

# The parent's script and the CHILD's script are the SAME FakeAdapter queue,
# consumed strictly in the order each turn actually asks for its next step —
# subagents_test.rb's boot harness scripts parent+child turns this same way.
# Order here: parent proposes Task -> the child's own two steps run to
# completion inside that ONE tool call -> the parent replies to the result.
ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new([
  { text: "Let me hand this off to a subagent to check on payments-api.",
    tool_calls: [Terret::LLM::ToolCall.new(
      id: "p1", name: "Task",
      args: { description: "check payments status",
              prompt: "Check whether payments-api is healthy and report back in one sentence." }
    )] },
  { text: "Checking payments-api now.",
    tool_calls: [Terret::LLM::ToolCall.new(id: "c1", name: "check_status", args: { service: "payments-api" })] },
  { text: "payments-api is healthy (uptime 14d, p99 82ms)." },
  { text: "Subagent confirms payments-api is healthy." }
]))

puts "   you>     check on payments-api"
ctx[:loop].run_turn(parent, "check on payments-api")

task_result = parent_session.events.find { |e| e.type == "tool/result" }
child_id = task_result&.payload&.fetch(:content, "").to_s[/child session (\S+)/, 1]
note "ledger line names the child: #{child_id.inspect} — the only thread from this " \
     "transcript to that one"

parent_types = parent_session.events.map(&:type).reject { |t| t == "assistant/chunk" }
note "parent event types this turn (uniq): #{parent_types.uniq.join(', ')}"
check("the parent's log gains no new durable event type beyond tool/call and tool/result",
      (parent_types.uniq - %w[session/created turn/start step/start user/message
                              assistant/message tool/call tool/result step/end turn/end]).empty?)
check("the Task tool result carries the child's session id", !child_id.nil?)

if child_id
  child_session = ctx[:sessions].fetch(child_id)
  child_types = child_session.events.map(&:type).reject { |t| t == "assistant/chunk" }
  check("the child completed its own two-step turn (a tool call, then a final reply)",
        child_types == %w[session/created turn/start step/start user/message assistant/message
                          tool/call tool/result step/end step/start assistant/message step/end turn/end])
  check("the child's session is fresh, not forked — it holds no parent lineage",
        child_session.parent_id.nil?)
  check("the parent's own session is untouched by the fork (no lineage either)",
        parent_session.parent_id.nil?)
end

# == act 2: a real background job ============================================
section "act 2: a real background job — job_start, then two collects"
JOBS_SESSION = "jobs-demo"

started = call_tool(ctx, "job_start", session_id: JOBS_SESSION,
                    command: "printf first-half; sleep 0.2; printf second-half")
job_id = started.content[/job (\S+)$/, 1]
note "job_start> #{trim(started.content.tr("\n", ' | '))}"
check("job_start hands back an id and no error", started.error.nil? && !job_id.nil?)

first = collect_until(ctx, JOBS_SESSION, job_id) { |c| c.start_with?("first-half") }
note "collect #1: #{trim(first.tr("\n", ' | '))}"
check("the first collect shows the job's first output", first.start_with?("first-half"))
check("the first collect still finds the job running", first.include?("still running"))

second = collect_until(ctx, JOBS_SESSION, job_id) { |c| c.include?("exited") }
note "collect #2: #{trim(second.tr("\n", ' | '))}"
check("the second collect shows only what arrived since the first (drained, not repeated)",
      second.start_with?("second-half"))
check("the second collect reports the exit status", second.include?("exited with status 0"))

# == act 3: TodoWrite ========================================================
section "act 3: TodoWrite renders the checklist"

todos = [
  { content: "Check payments-api", status: "completed", activeForm: "Checking payments-api" },
  { content: "Watch the background job", status: "in_progress", activeForm: "Watching the background job" },
  { content: "Report back", status: "pending", activeForm: "Reporting back" }
]
todo_result = call_tool(ctx, "TodoWrite", session_id: JOBS_SESSION, todos: todos)
puts todo_result.content.each_line.map { |l| "   #{l.chomp}" }.join("\n")
check("TodoWrite renders one checkbox line per item, in order",
      todo_result.content.lines.size == todos.size)
check("the in-progress item is shown in its active form, not its content",
      todo_result.content.include?("Watching the background job") &&
        !todo_result.content.include?("[~] Watch the background job"))
check("a completed item is checked off", todo_result.content.include?("[x] Check payments-api"))

# == act 4: two job_collect calls in ONE assistant message ==================
section "act 4: two job_collect calls in one message — the tool barrier"

job_a = call_tool(ctx, "job_start", session_id: parent_session.id, command: "printf hello-from-A")
job_b = call_tool(ctx, "job_start", session_id: parent_session.id, command: "printf hello-from-B")
job_a_id = job_a.content[/job (\S+)$/, 1]
job_b_id = job_b.content[/job (\S+)$/, 1]
note "started two jobs under the parent's own session: #{job_a_id}, #{job_b_id}"

# `job_start` wraps every command as a LOGIN shell (`bash -lc`, docs/
# subagents.md §6) — measured at a few hundred ms here just to source the
# host's shell profile before `printf` ever runs, which a fixed short sleep
# cannot outrun portably. `#exited?` is a non-blocking waitpid; it never
# touches the pipe, so polling it (the same ivar jobs_test.rb's own suite
# reads) waits for both jobs to actually finish without draining the buffer
# the model's own job_collect calls are about to read for the first time.
ledger = ctx[:jobs].instance_variable_get(:@jobs)
[job_a_id, job_b_id].each do |id|
  deadline = now + 5
  sleep 0.02 while !ledger[id].handle.exited? && now < deadline
end

ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new([
  { text: "Checking both background jobs at once.",
    tool_calls: [
      Terret::LLM::ToolCall.new(id: "p2", name: "job_collect", args: { id: job_a_id }),
      Terret::LLM::ToolCall.new(id: "p3", name: "job_collect", args: { id: job_b_id })
    ] },
  { text: "Both jobs reported in." }
]))

mark = parent_session.events.length
puts "   you>     check both jobs"
ctx[:loop].run_turn(parent, "check both jobs")
turn2 = parent_session.events[mark..].reject { |e| e.type == "assistant/chunk" }

expected_shape = %w[turn/start step/start user/message assistant/message tool/call tool/call
                    tool/result tool/result step/end step/start assistant/message step/end turn/end]
note "turn 2 event shape: #{turn2.map(&:type).join(', ')}"
check("both tool/calls are logged before EITHER tool/result — the shape a barrier run " \
      "produces and two ordinary serial calls (call, result, call, result) never could",
      turn2.map(&:type) == expected_shape)

calls   = turn2.select { |e| e.type == "tool/call" }
results = turn2.select { |e| e.type == "tool/result" }
note "call order:   #{calls.map { |e| e.payload[:id] }.join(', ')}"
note "result order: #{results.map { |e| e.payload[:id] }.join(', ')}"
check("results append in call order regardless of completion order",
      calls.map { |e| e.payload[:id] } == results.map { |e| e.payload[:id] })
check("each job's own output came back under its own call",
      results[0].payload[:content].to_s.include?("hello-from-A") &&
        results[1].payload[:content].to_s.include?("hello-from-B"))

# == assertions ===============================================================
section "assertions"
CHECKS.each { |desc, ok| puts "   #{ok ? 'ok  ' : 'FAIL'}  #{desc}" }
failed = CHECKS.reject { |_, ok| ok }

ctx[:jobs].stop_all # belt and braces: every job here was fire-and-forget short-lived

if failed.any?
  warn "\n#{failed.length} of #{CHECKS.length} check(s) failed"
  exit 1
end

puts "\ndone: a subagent, a background job, a todo list, and the tool barrier — offline"
