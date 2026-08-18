# frozen_string_literal: true

# Interactive playground for the M4 socket. Two modes, two terminals:
#
#   Terminal 1:  bundle exec ruby examples/ws_playground.rb server
#   Terminal 2:  bundle exec ruby examples/ws_playground.rb client [from_seq]
#
# The server persists to tmp/ws_playground.sqlite3 — kill it, restart it,
# reconnect with `client 0`, and watch the whole history replay.
#
# With OPENROUTER_API_KEY set the agent runs a real model (override with
# TERRET_MODEL, default openai/gpt-5-mini). Without it, a canned adapter
# echoes what you type — and if your message contains "count", it calls a
# deliberately slow countdown tool so you have a window to steer or cancel.
#
# Client commands (anything else is sent as a waking inject):
#   /steer <text>      inject without wake (rides into the running turn)
#   /cancel [reason]   cancel the running turn
#   /approve <id>      append approval/resolved (verdict approved)
#   /deny <id>         append approval/resolved (verdict denied)
#   /model <prov/mod>  repoint the main model role
#   /quit              disconnect (the agent survives; reconnect to catch up)

Warning[:experimental] = false

require "json"
require "async"
require "async/websocket/client"
require "async/http/endpoint"
require_relative "../gems/terret-ws/lib/terret/ws"
require_relative "../gems/terret-store-sqlite/lib/terret/store/sqlite"

PORT = 9292
AGENT = "play"
TOKEN = "dev-token"
URL = "http://127.0.0.1:#{PORT}/agents/#{AGENT}/ws"

# A canned adapter interesting enough to poke at: echoes, and calls the slow
# countdown tool when the input mentions "count".
class PlaygroundAdapter
  def stream(request)
    last = request.messages.last
    if last.role == :tool
      return say("The countdown finished while you watched the event stream. " \
                 "Try /cancel next time, or say something else.") { |ev| yield ev }
    end

    text = last.text.to_s
    if text.downcase.include?("count")
      tc = Terret::LLM::ToolCall.new(id: "tc-#{rand(10_000)}", name: "countdown",
                                     args: { seconds: 8 })
      intro = "Starting a slow countdown — steer or cancel me while it runs."
      intro.chars.each_slice(8) { |c| yield Terret::LLM::TextDelta.new(text: c.join) }
      yield Terret::LLM::ToolCallEnd.new(tool_call: tc)
      yield Terret::LLM::MessageStop.new(stop_reason: :tool_use)
      Terret::LLM::Message.new(role: :assistant,
                               parts: [Terret::LLM::Text.new(text: intro), tc])
    else
      say("Echo: #{text}") { |ev| yield ev }
    end
  end

  private

  def say(reply)
    reply.chars.each_slice(8) { |c| yield Terret::LLM::TextDelta.new(text: c.join) }
    yield Terret::LLM::MessageStop.new(stop_reason: :end_turn)
    Terret::LLM::Message.new(role: :assistant, parts: [Terret::LLM::Text.new(text: reply)])
  end
end

def serve!
  Hames.reset_events!
  Terret.declare_events!

  real = ENV["OPENROUTER_API_KEY"]
  model = ENV.fetch("TERRET_MODEL", "openai/gpt-5-mini")
  role = real ? "openrouter/#{model}" : "fake/playground"

  loader = Hames::Loader.new
  loader.layer([
    { id: "session_store", plugin: Terret::Store::SQLite,
      config: { path: File.expand_path("../tmp/ws_playground.sqlite3", __dir__) } },
    { id: "sessions", plugin: Terret::Sessions },
    { id: "prompt",   plugin: Terret::Prompt },
    { id: "tools",    plugin: Terret::Tools::Registry },
    { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: role } } },
    { id: "loop",     plugin: Terret::Loop },
    { id: "ws",       plugin: Terret::WS::Service,
      config: { tokens: { AGENT => TOKEN }, heartbeat: 15 } }
  ])
  ctx = loader.boot!

  if real
    require_relative "../gems/terret-openrouter/lib/terret/openrouter"
    ctx[:llm].register_adapter("openrouter", Terret::OpenRouter::Adapter.new(api_key: real))
  else
    ctx[:llm].register_adapter("fake", PlaygroundAdapter.new)
  end

  ctx.with_owner("playground-tools") do
    ctx[:tools].register(name: "countdown", description: "Counts down slowly",
                         params: { seconds: "integer" }) do |seconds:|
      seconds.to_i.clamp(1, 30).times { sleep 1 }
      "counted down #{seconds} seconds"
    end
    ctx[:tools].register(name: "weather", description: "Weather lookup",
                         params: { city: "string" }) { |city:| "22C in #{city}" }
  end

  puts "serving ws://127.0.0.1:#{PORT}/agents/#{AGENT}/ws  (#{real ? role : 'canned adapter'})"
  puts "log: tmp/ws_playground.sqlite3 — restart me and reconnect to prove resume"
  ctx[:ws].serve(port: PORT)
end

def client!(from_seq)
  endpoint = Async::HTTP::Endpoint.parse(URL)
  Sync do |task|
    Async::WebSocket::Client.connect(endpoint,
                                     headers: [["authorization", "Bearer #{TOKEN}"]]) do |conn|
      printer = task.async do
        while (msg = conn.read)
          f = JSON.parse(msg.to_str, symbolize_names: true)
          if f[:seq]
            label = f[:type] == "assistant/chunk" ? f.dig(:payload, :text) : f[:payload].inspect
            puts format("%4d  %-18s %s", f[:seq], f[:type], label)
          else
            puts ">> #{f[:type]}: #{f.reject { |k, _| k == :type }.inspect}"
          end
        end
        puts ">> server closed the connection"
      end

      # write + flush: without the flush a frame written while the printer
      # task is parked inside conn.read stays buffered and never reaches the
      # server (the subscribe only worked because the first read flushed it)
      send_frame = lambda do |hash|
        conn.write(JSON.generate(hash))
        conn.flush
      end

      send_frame.call(type: "subscribe", from_seq: from_seq)
      puts "(subscribed from #{from_seq} — type to talk, /quit to drop, /cancel, /steer ...)"

      while (line = $stdin.gets&.strip)
        case line
        when "/quit" then break
        when %r{\A/steer (.+)}   then send_frame.call(type: "inject", text: $1, wake: false)
        when %r{\A/cancel ?(.*)} then send_frame.call(type: "cancel", reason: $1.empty? ? nil : $1)
        when %r{\A/approve (.+)} then send_frame.call(type: "approve", call_id: $1)
        when %r{\A/deny (.+)}    then send_frame.call(type: "deny", call_id: $1)
        when %r{\A/model (.+)}   then send_frame.call(type: "set_model", role: "main", model: $1)
        when "" then next
        else send_frame.call(type: "inject", text: line, wake: true)
        end
      end
      printer.stop
    end
  end
end

case ARGV[0]
when "server" then serve!
when "client" then client!((ARGV[1] || 0).to_i)
else
  puts "usage: bundle exec ruby examples/ws_playground.rb server"
  puts "       bundle exec ruby examples/ws_playground.rb client [from_seq]"
end
