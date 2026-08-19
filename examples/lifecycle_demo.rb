# frozen_string_literal: true
# The rescoped M6 surface end to end: a policy-denied tool call, a hot
# allow-list update that turns it on, an overweight turn compacting through
# the summarizer seam, a title and a bill, and — the point of the whole
# milestone — a clean "redeploy" that resumes the session from disk with a
# byte-identical derived history. FakeAdapter + JSONL under tmp/, no network.
#
#   ruby examples/lifecycle_demo.rb

require "fileutils"
require "digest"
require_relative "../gems/terret-core/lib/terret"
# require_relative "../gems/terret-morph/lib/terret/morph" # only for the Morph swap in boot() below

STORE_DIR = File.expand_path("../tmp/lifecycle_demo", __dir__)
FileUtils.rm_rf(STORE_DIR)

Terret.declare_events!

# A full boot against the given directory — called twice: once for the live
# run, once again in act 4 to stand in for a fresh process after a deploy.
def boot(store_dir)
  loader = Hames::Loader.new
  loader.layer([
    { id: "session_store", plugin: Terret::Store::JSONL, config: { dir: store_dir } },
    { id: "sessions", plugin: Terret::Sessions },
    { id: "prompt",   plugin: Terret::Prompt },
    { id: "tools",    plugin: Terret::Tools::Registry },
    { id: "llm",      plugin: Terret::LLM::Service,
      config: { roles: { main: "fake/scripted", compactor: "fake/scripted" } } },
    { id: "loop",       plugin: Terret::Loop },
    { id: "summarizer", plugin: Terret::RoleSummarizer },
    # Swap for extractive compaction via Morph's Compact API (needs
    # MORPH_API_KEY; this demo stays offline, so it's commented out):
    # { id: "summarizer", plugin: Terret::Morph::Summarizer,
    #   config: { api_key: ENV["MORPH_API_KEY"] } },
    { id: "compactor", plugin: Terret::Compactor, config: { budget: 500 } },
    { id: "titler",    plugin: Terret::Titler }
  ])
  loader.boot!
end

ctx = boot(STORE_DIR)

# Script bookkeeping — six entries, none left over:
#   1. turn 1, step 1 — proposes deploy (the allow list denies it)
#   2. turn 1, step 2 — reply after the veto
#   3. turn 2, step 1 — proposes deploy again (now allowed)
#   4. turn 2, step 2 — reply after the tool result
#   5. turn 3, step 1 — a heavy-usage reply that trips the compaction budget
#   6. the RoleSummarizer's own request, consumed inline at turn 3's turn/end
script = [
  { text: "Deploying to prod.",
    tool_calls: [Terret::LLM::ToolCall.new(id: "t1", name: "deploy", args: { target: "prod" })] },
  { text: "Deploy was denied by policy." },
  { text: "Deploying to prod.",
    tool_calls: [Terret::LLM::ToolCall.new(id: "t2", name: "deploy", args: { target: "prod" })] },
  { text: "Deploy succeeded." },
  { text: "Running the big migration.",
    usage: { prompt_tokens: 900, completion_tokens: 40, cost: 0.12 } },
  { text: "SUMMARY: denied a deploy, allowed it after a policy update, then ran a heavy migration." }
]
ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))

ctx.with_owner("demo-tools") do
  ctx[:tools].register(name: "deploy", description: "Deploy to production",
                       params: { target: "string" }, mutating: true) do |target:|
    "deployed #{target}"
  end
  ctx[:prompt].register_section("identity", priority: 1) { "You are a deploy assistant." }
end

# render the transcript live from the single event stream — seq, type, and a
# terse payload, no side channels. Note: compaction and titling append from
# inside a turn/end listener, so their lines can print before turn/end's own
# line even though its seq is lower — the nested append's emit completes
# before the outer one continues (docs/lifecycle.md's re-entrant append note).
ctx.on("session/event") do |ev|
  summary = ev.payload.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
  puts format("%3d %-16s %s", ev.seq, ev.type, summary)
end

session = ctx[:sessions].create(id: "demo")
agent = ctx[:loop].spawn_agent(session_id: "demo")

puts "\n== act 1: policy denies, a hot update allows"
Terret::Tools::AllowList.install(agent.ctx, ["nothing"])
ctx[:loop].run_turn(agent, "deploy to prod")

Terret::Tools::AllowList.update(ctx, "demo", ["deploy"])
ctx[:loop].run_turn(agent, "deploy to prod, please")

puts "\n== act 2: an overweight turn compacts"
ctx[:loop].run_turn(agent, "run the big migration")
compacted = session.events.reverse_each.find { |e| e.type == "session/compacted" }
puts "-- compacted at seq=#{compacted.seq} upto_seq=#{compacted.payload[:upto_seq]}"
puts "-- derived projection now: #{ctx[:sessions].derive_messages('demo').map(&:text).inspect}"

puts "\n== act 3: title and bill"
puts "-- title: #{ctx[:sessions].title('demo').inspect}"
puts "-- usage: #{ctx[:sessions].usage('demo').inspect}"

puts "\n== act 4: a clean deploy resumes byte-identical"
digest = ->(msgs) { Digest::SHA256.hexdigest(msgs.map(&:inspect).join("\x1e")) }
before = digest.(ctx[:sessions].derive_messages("demo"))

# a fresh process, same directory: only the store and the projection matter here
redeployed = boot(STORE_DIR)
redeployed[:sessions].resume("demo")
after = digest.(redeployed[:sessions].derive_messages("demo"))

if before == after
  puts "-- byte-identical (#{after})"
else
  raise "clean deploy diverged: #{before} != #{after}" # a demo that lies is worse than none
end
