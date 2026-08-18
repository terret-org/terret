# frozen_string_literal: true

# The M4 socket, end to end on one reactor: boot a harness with the scripted
# adapter, serve the websocket, run a turn from a client, drop the client
# mid-session, then reconnect with from_seq and watch the exact catch-up.
#
#   ruby examples/ws_demo.rb   # needs async-websocket (bundle install)

Warning[:experimental] = false

require "json"
require "socket"
require "async"
require "async/websocket/client"
require "async/http/endpoint"
require_relative "../gems/terret-ws/lib/terret/ws"

Hames.reset_events!
Terret.declare_events!

loader = Hames::Loader.new
loader.layer([
  { id: "session_store", plugin: Terret::Store::Memory },
  { id: "sessions", plugin: Terret::Sessions },
  { id: "prompt",   plugin: Terret::Prompt },
  { id: "tools",    plugin: Terret::Tools::Registry },
  { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
  { id: "loop",     plugin: Terret::Loop },
  { id: "ws",       plugin: Terret::WS::Service, config: { tokens: { "demo" => "demo-token" } } }
])
ctx = loader.boot!
ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new([
  { text: "First reply, streamed over the socket." },
  { text: "Second reply after the reconnect." }
]))

server = TCPServer.new("127.0.0.1", 0)
port = server.addr[1]
server.close

Sync do |task|
  task.async { ctx[:ws].serve(port: port) }
  sleep 0.2

  endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:#{port}/agents/demo/ws")
  # A fresh array per connect: async-websocket's UpgradeRequest appends the
  # Sec-WebSocket-Key onto whatever headers it's given, so a shared array
  # would carry the first connection's stale key into the second request.
  auth_headers = -> { [["authorization", "Bearer demo-token"]] }
  last_seq = -1

  puts "== first connection"
  Async::WebSocket::Client.connect(endpoint, headers: auth_headers.call) do |conn|
    conn.write(JSON.generate(type: "subscribe", from_seq: 0))
    conn.write(JSON.generate(type: "inject", text: "hello agent", wake: true))
    while (msg = conn.read)
      f = JSON.parse(msg.to_str, symbolize_names: true)
      puts "  #{f[:seq] ? format('%3d %s', f[:seq], f[:type]) : "  · #{f[:type]}"}"
      last_seq = f[:seq] if f[:seq]
      break if f[:type] == "turn/end"
    end
  end

  puts "== disconnected; a turn runs while nobody is watching"
  ctx[:loop].run_turn(ctx[:loop].agent("agent-demo"), "carry on without me")

  puts "== reconnect from seq #{last_seq + 1}: exactly the missed events"
  Async::WebSocket::Client.connect(endpoint, headers: auth_headers.call) do |conn|
    conn.write(JSON.generate(type: "subscribe", from_seq: last_seq + 1))
    while (msg = conn.read)
      f = JSON.parse(msg.to_str, symbolize_names: true)
      next unless f[:seq]

      puts format("  %3d %s", f[:seq], f[:type])
      break if f[:type] == "turn/end"
    end
  end

  task.stop
end
