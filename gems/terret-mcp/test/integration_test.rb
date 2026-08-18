# frozen_string_literal: true

require "minitest/autorun"

MANCEPS_AVAILABLE = begin
  require "manceps"
  require "async"
  true
rescue LoadError
  false
end

require_relative "../lib/terret/mcp" if MANCEPS_AVAILABLE

class MCPIntegrationTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/stdio_server.rb", __dir__)

  def setup
    skip "manceps/async not installed" unless MANCEPS_AVAILABLE
  end

  def boot
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "mcp",      plugin: Terret::MCP::Service,
        config: { servers: { "fix" => { command: RbConfig.ruby, args: [FIXTURE], timeout: 2 } } } }
    ])
    loader.boot!
  end

  def test_discovers_and_calls_tools_on_a_real_stdio_server
    ctx = boot
    Sync do
      ctx[:mcp].mount!
      names = ctx[:tools].schemas.map { |s| s[:name] }.sort
      assert_equal %w[mcp__fix__echo mcp__fix__slow], names

      result = ctx[:tools].execute(
        Terret::Tools::Call.new(id: "t1", name: "mcp__fix__echo", args: { text: "hi" }, session_id: "x"),
        ctx: ctx
      )
      assert_nil result.error
      assert_equal "echo: hi", result.content
    ensure
      ctx[:mcp].unmount!("fix")
    end
  end

  def test_a_slow_server_call_yields_the_reactor_and_times_out_cleanly
    ctx = boot
    Sync do |task|
      ctx[:mcp].mount!
      ticks = 0
      ticker = task.async { 10.times { ticks += 1; sleep 0.1 } }

      result = ctx[:tools].execute(
        Terret::Tools::Call.new(id: "t1", name: "mcp__fix__slow", args: { seconds: 30 }, session_id: "x"),
        ctx: ctx
      )
      assert_match(/mcp timeout after 2s/, result.error)
      ticker.wait
      assert_equal 10, ticks, "the reactor must keep scheduling while MCP IO waits (fiber canary)"

      # poisoned connection heals: next call reconnects and succeeds
      again = ctx[:tools].execute(
        Terret::Tools::Call.new(id: "t2", name: "mcp__fix__echo", args: { text: "back" }, session_id: "x"),
        ctx: ctx
      )
      assert_nil again.error
      assert_equal "echo: back", again.content
    ensure
      ctx[:mcp].unmount!("fix")
    end
  end
end
