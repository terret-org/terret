# frozen_string_literal: true

# The MCP client end to end: a real stdio server (the terret-mcp test
# fixture) mounted through real manceps, an allow list admitting one of its
# two tools, and a turn whose single step calls both — printed straight from
# the session event stream.
#
#   bundle exec ruby examples/mcp_demo.rb   # needs manceps (bundle install)

Warning[:experimental] = false

require "async"
require_relative "../gems/terret-mcp/lib/terret/mcp"

Hames.reset_events!
Terret.declare_events!

FIXTURE = File.expand_path("../gems/terret-mcp/test/fixtures/stdio_server.rb", __dir__)

loader = Hames::Loader.new
loader.layer([
  { id: "session_store", plugin: Terret::Store::Memory },
  { id: "sessions", plugin: Terret::Sessions },
  { id: "prompt",   plugin: Terret::Prompt },
  { id: "tools",    plugin: Terret::Tools::Registry },
  { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
  { id: "loop",     plugin: Terret::Loop },
  { id: "mcp",      plugin: Terret::MCP::Service,
    config: { servers: { "fix" => { command: RbConfig.ruby, args: [FIXTURE], timeout: 5 } } } }
])
ctx = loader.boot!

script = [
  { text: "Calling echo and the slow tool.",
    tool_calls: [
      Terret::LLM::ToolCall.new(id: "t1", name: "mcp__fix__echo", args: { text: "hello" }),
      # seconds: 30 would time out if it ever reached the server — it never
      # does, because the allow list denies it before dispatch
      Terret::LLM::ToolCall.new(id: "t2", name: "mcp__fix__slow", args: { seconds: 30 })
    ] },
  { text: "One tool ran, one was denied by policy." }
]
ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))

# render the transcript live from the single event stream — seq, type, and a
# terse payload, no side channels
ctx.on("session/event") do |ev|
  summary = ev.payload.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
  puts format("%3d %-16s %s", ev.seq, ev.type, summary)
end

Sync do
  ctx[:mcp].mount!
  puts "== mounted fix: #{ctx[:tools].schemas.map { |s| s[:name] }.sort}"

  session = ctx[:sessions].create
  agent = ctx[:loop].spawn_agent(session_id: session.id)
  Terret::Tools::AllowList.install(agent.ctx, ["mcp__fix__echo"])

  status = ctx[:loop].run_turn(agent, "echo hello, and try the slow tool")
  puts "== turn #{status}"
ensure
  ctx[:mcp].unmount!("fix")
  puts "== unmounted; #{ctx[:tools].schemas.size} tools remain"
end
