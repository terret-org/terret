# frozen_string_literal: true

# Boots the core stack on a JSONL store, runs a turn whose tool wedges
# forever mid-execution, prints WEDGED, and holds until killed. Driven by
# lifecycle_test.rb, which kill -9s this process to prove a mid-turn deploy
# leaves a genuinely dangling log (no ensure, no teardown) that a fresh
# process resumes.
#
# Usage: ruby wedged_boot.rb <jsonl_dir> <session_id>

require "async"
require_relative "../../../terret-core/lib/terret"

$stdout.sync = true

dir, sid = ARGV
abort "usage: wedged_boot.rb <jsonl_dir> <session_id>" unless dir && sid

Terret.declare_events!

loader = Hames::Loader.new
loader.layer([
  { id: "session_store", plugin: Terret::Store::JSONL, config: { dir: dir } },
  { id: "sessions", plugin: Terret::Sessions },
  { id: "prompt",   plugin: Terret::Prompt },
  { id: "tools",    plugin: Terret::Tools::Registry },
  { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
  { id: "loop",     plugin: Terret::Loop }
])
ctx = loader.boot!
ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(
  [{ text: "Deploying.",
     tool_calls: [Terret::LLM::ToolCall.new(id: "tc-kill", name: "deploy", args: { env: "prod" })] },
   { text: "Done." }]
))
ctx.with_owner("deploy-plugin") do
  ctx[:tools].register(name: "deploy", description: "Ship it",
                       params: { env: "string" }, mutating: true) { |env:| sleep }
end

ctx[:sessions].create(id: sid)
agent = ctx[:loop].spawn_agent(session_id: sid)

Sync do |task|
  task.async { ctx[:loop].run_turn(agent, "ship it") }
  task.async do
    # tool/call is in the projection only after Sessions#append wrote it
    # through to the store, so WEDGED means the log on disk already dangles
    sleep 0.005 until ctx[:sessions].fetch(sid).events.any? { |e| e.type == "tool/call" }
    puts "WEDGED"
    sleep # hold the wedge until the kill
  end.wait
end
