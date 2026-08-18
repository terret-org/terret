# frozen_string_literal: true

# Minimal legacy-wire (2025-06-18/2025-11-25) MCP stdio server used by
# terret-mcp's integration tests. Newline-delimited JSON-RPC: initialize,
# tools/list (echo + slow), tools/call. Deliberately tiny and dependency-free.

require "json"

$stdout.sync = true

TOOLS = [
  { "name" => "echo", "description" => "Echoes its input",
    "inputSchema" => { "type" => "object", "properties" => { "text" => { "type" => "string" } } } },
  { "name" => "slow", "description" => "Sleeps then answers",
    "inputSchema" => { "type" => "object", "properties" => { "seconds" => { "type" => "number" } } } }
].freeze

def reply(id, result) = $stdout.puts(JSON.generate(jsonrpc: "2.0", id: id, result: result))
def fail_rpc(id, code, msg) = $stdout.puts(JSON.generate(jsonrpc: "2.0", id: id, error: { code: code, message: msg }))

while (line = $stdin.gets)
  msg = JSON.parse(line) rescue next
  id = msg["id"]
  case msg["method"]
  when "initialize"
    reply(id, { "protocolVersion" => msg.dig("params", "protocolVersion"),
                "capabilities" => { "tools" => { "listChanged" => false } },
                "serverInfo" => { "name" => "terret-fixture", "version" => "1.0" } })
  when "notifications/initialized", "notifications/cancelled" then next
  when "ping" then reply(id, {}) if id
  when "tools/list"
    reply(id, { "tools" => TOOLS })
  when "tools/call"
    name = msg.dig("params", "name")
    args = msg.dig("params", "arguments") || {}
    case name
    when "echo"
      reply(id, { "content" => [{ "type" => "text", "text" => "echo: #{args['text']}" }], "isError" => false })
    when "slow"
      sleep(args.fetch("seconds", 3))
      reply(id, { "content" => [{ "type" => "text", "text" => "finally" }], "isError" => false })
    else
      reply(id, { "content" => [{ "type" => "text", "text" => "no such tool #{name}" }], "isError" => true })
    end
  else
    fail_rpc(id, -32_601, "method not found: #{msg['method']}") if id
  end
end
