# frozen_string_literal: true
# The headless demo against a real model over OpenRouter: a multi-step tool
# turn, rendered live from session/event, with usage accounting on step/end.
#
#   OPENROUTER_API_KEY=sk-or-... ruby examples/openrouter_demo.rb
#   TERRET_MODEL=anthropic/claude-sonnet-4.5 ruby examples/openrouter_demo.rb
#
# Requires the async-http gem (the only network dependency in the tree).

abort "set OPENROUTER_API_KEY to run this demo" unless ENV["OPENROUTER_API_KEY"]

Warning[:experimental] = false # async's resolv use of IO::Buffer warns on Ruby 4.0

require_relative "../gems/terret-core/lib/terret"
require_relative "../gems/terret-openrouter/lib/terret/openrouter"

model = ENV.fetch("TERRET_MODEL", "openai/gpt-5-mini")

loader = Hames::Loader.new
loader.layer([
  { id: "session_store", plugin: Terret::Store::Memory },
  { id: "sessions",   plugin: Terret::Sessions },
  { id: "prompt",     plugin: Terret::Prompt },
  { id: "tools",      plugin: Terret::Tools::Registry },
  { id: "llm",        plugin: Terret::LLM::Service, config: { roles: { main: "openrouter/#{model}" } } },
  { id: "loop",       plugin: Terret::Loop },
  { id: "openrouter", plugin: Terret::OpenRouter::Plugin,
    config: { title: "Terret demo", referer: "https://terret.org" } }
])
ctx = loader.boot!

ctx.with_owner("demo-tools") do
  ctx[:tools].register(
    name: "weather", description: "Current weather for a city",
    params: { type: "object", properties: { city: { type: "string" } },
              required: ["city"] }
  ) { |city:| "22C, clear skies in #{city}" }
  ctx[:prompt].register_section("identity", priority: 1) do
    "You are a terse assistant. Use the weather tool when asked about weather."
  end
end

ctx.on("session/event") do |ev|
  line = case ev.type
         when "user/message"      then "you>  #{ev.payload[:text]}"
         when "assistant/chunk"   then next print ev.payload[:text]
         when "assistant/message" then "\n"
         when "tool/call"         then "tool> #{ev.payload[:name]}(#{ev.payload[:args]})"
         when "tool/result"
           ev.payload[:error] ? "  !!  #{ev.payload[:error]}" : "  ->  #{ev.payload[:content]}"
         when "step/end"
           u = ev.payload[:usage]
           u && "[step #{ev.payload[:n]}: #{u[:prompt_tokens]}+#{u[:completion_tokens]} tokens, $#{u[:cost]}]"
         when "turn/end"          then "[turn #{ev.payload[:status]}]"
         end
  puts line if line
end

session = ctx[:sessions].create
agent = ctx[:loop].spawn_agent(session_id: session.id)
ctx[:loop].run_turn(agent, "What's the weather in Mexico City right now?")

puts "\n#{session.events.length} durable events; model: #{model}"
