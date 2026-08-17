# frozen_string_literal: true
# Headless demo: a two-step tool turn against the scripted adapter, with a
# policy plugin vetoing one tool call, printed straight from session/event.
#
#   ruby examples/headless_demo.rb

require_relative "../gems/terret-core/lib/terret"

loader = Hames::Loader.new
loader.layer([
  { id: "sessions", plugin: Terret::Sessions },
  { id: "prompt",   plugin: Terret::Prompt },
  { id: "tools",    plugin: Terret::Tools::Registry },
  { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
  { id: "loop",     plugin: Terret::Loop }
])
ctx = loader.boot!

script = [
  { text: "Let me check the weather and your calendar.",
    tool_calls: [
      Terret::LLM::ToolCall.new(id: "t1", name: "weather",  args: { city: "CDMX" }),
      Terret::LLM::ToolCall.new(id: "t2", name: "calendar", args: { day: "today" })
    ] },
  { text: "It's 22C in CDMX. I couldn't read your calendar (policy denied)." }
]
ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))

ctx.with_owner("demo-tools") do
  ctx[:tools].register(name: "weather", description: "Weather", params: { city: "string" }) do |city:|
    "22C, clear, #{city}"
  end
  ctx[:tools].register(name: "calendar", description: "Calendar", params: { day: "string" }) do |day:|
    "3 meetings #{day}"
  end
  ctx[:prompt].register_section("identity", priority: 1) { "You are a terse assistant." }
end

# a policy plugin — vetoes calendar reads via the tools pipeline
ctx.with_owner("policy") do
  ctx.on("tools/pre_execute") do |call, next_|
    call.name == "calendar" ? Terret::Tools::Veto.new(reason: "calendar access requires approval") : next_.(call)
  end
end

# render the transcript live from the single event stream — no side channels
ctx.on("session/event") do |ev|
  line = case ev.type
         when "user/message"      then "you>  #{ev.payload[:text]}"
         when "assistant/chunk"   then next print ev.payload[:text]
         when "assistant/message" then "\n"
         when "tool/call"         then "tool> #{ev.payload[:name]}(#{ev.payload[:args]})"
         when "tool/result"
           ev.payload[:error] ? "  !!  #{ev.payload[:error]}" : "  ->  #{ev.payload[:content]}"
         when "turn/end"          then "[turn #{ev.payload[:status]}]"
         end
  puts line if line
end

session = ctx[:sessions].create
agent = ctx[:loop].spawn_agent(session_id: session.id)
ctx[:loop].run_turn(agent, "Weather in CDMX, and what's on my calendar?")

puts "\n#{session.events.length} durable events; derived history roles: " \
     "#{ctx[:sessions].derive_messages(session.id).map(&:role).join(' -> ')}"
