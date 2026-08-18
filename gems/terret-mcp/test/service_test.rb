# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret/mcp"

class MCPServiceTest < Minitest::Test
  FakeTool = Struct.new(:name, :description, :input_schema)

  # Duck-typed manceps client: canned tools, scripted results, call journal.
  class FakeClient
    attr_reader :calls, :connected, :disconnected

    def initialize(tools:, results: {})
      @tools = tools
      @results = results
      @calls = []
      @handlers = {}
      @connected = false
      @disconnected = false
    end

    def connect = @connected = true
    def disconnect = @disconnected = true
    def reconnect! = @connected = true
    def tools(*) = @tools
    def on(method, &block) = @handlers[method] = block
    def notify!(method) = @handlers.fetch(method).call({})
    def listen = nil

    Result = Struct.new(:content, :structured_content, :err, keyword_init: true) do
      def error? = err
      def structured? = !structured_content.nil?
      def text = content.to_s
    end

    def call_tool(name, **args)
      @calls << [name, args]
      # default results are structured so the fake's String content never
      # meets result_content's array path (real content is always an array)
      spec = @results.fetch(name) { { structured: { "ok" => name } } }
      Result.new(content: spec[:text], structured_content: spec[:structured], err: spec[:error] || false)
    end
  end

  class FlakyClient < FakeClient
    def initialize(**)
      super
      @attempts = 0
    end

    def tools(*)
      @attempts += 1
      raise "network blip" if @attempts == 1

      super
    end
  end

  def boot(servers:, strict: false, factory:)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "mcp",      plugin: Terret::MCP::Service,
        config: { servers: servers, strict: strict, client_factory: factory } }
    ])
    loader.boot!
  end

  def test_mount_registers_namespaced_tools_with_per_server_approval
    fake = FakeClient.new(tools: [FakeTool.new("search", "Find", { "type" => "object" })])
    ctx = boot(servers: { "nexus" => { url: "https://x/mcp", approval: :always } },
               factory: ->(_name, _cfg) { fake })

    ctx[:mcp].mount!
    assert fake.connected
    names = ctx[:tools].schemas.map { |s| s[:name] }
    assert_includes names, "mcp__nexus__search"
    d = ctx[:tools].fetch("mcp__nexus__search")
    assert_equal :always, d.approval
    assert d.mutating
  end

  def test_unmount_reverses_every_registration_and_disconnects
    fake = FakeClient.new(tools: [FakeTool.new("a", "", {}), FakeTool.new("b", "", {})])
    ctx = boot(servers: { "s" => { url: "https://x/mcp" } }, factory: ->(*) { fake })
    ctx[:mcp].mount!
    assert_equal 2, ctx[:tools].schemas.size

    ctx[:mcp].unmount!("s")
    assert_equal 0, ctx[:tools].schemas.size
    assert fake.disconnected
  end

  def test_calling_a_mounted_tool_round_trips_through_the_client
    fake = FakeClient.new(tools: [FakeTool.new("echo", "", {})],
                          results: { "echo" => { structured: { "said" => "hi" } } })
    ctx = boot(servers: { "s" => { url: "https://x/mcp" } }, factory: ->(*) { fake })
    ctx[:mcp].mount!

    result = ctx[:tools].execute(
      Terret::Tools::Call.new(id: "t1", name: "mcp__s__echo", args: { text: "hi" }, session_id: "x"),
      ctx: ctx
    )
    assert_nil result.error
    assert_equal({ "said" => "hi" }, result.content)
    assert_equal [["echo", { text: "hi" }]], fake.calls
  end

  def test_a_server_side_tool_error_maps_to_the_error_channel
    fake = FakeClient.new(tools: [FakeTool.new("bad", "", {})],
                          results: { "bad" => { text: "kaboom", error: true } })
    ctx = boot(servers: { "s" => { url: "https://x/mcp" } }, factory: ->(*) { fake })
    ctx[:mcp].mount!

    result = ctx[:tools].execute(
      Terret::Tools::Call.new(id: "t1", name: "mcp__s__bad", args: {}, session_id: "x"),
      ctx: ctx
    )
    assert_equal "kaboom", result.error
    assert_nil result.content
  end

  def test_strict_mode_refuses_servers_outside_the_config_row
    ctx = boot(servers: { "s" => { url: "https://x/mcp" } }, strict: true, factory: ->(*) { FakeClient.new(tools: []) })
    err = assert_raises(ArgumentError) { ctx[:mcp].mount!("ambient") }
    assert_match(/strict/, err.message)
  end

  def test_bad_server_names_and_missing_transport_are_refused_at_boot
    assert_raises(ArgumentError) do
      boot(servers: { "No Good" => { url: "https://x/mcp" } }, factory: ->(*) { FakeClient.new(tools: []) })
    end
    assert_raises(ArgumentError) do
      boot(servers: { "s" => { approval: :policy } }, factory: ->(*) { FakeClient.new(tools: []) })
    end
  end

  def test_a_failed_discovery_leaves_no_half_mounted_server
    fake = FlakyClient.new(tools: [FakeTool.new("a", "", {})])
    ctx = boot(servers: { "s" => { url: "https://x/mcp" } }, factory: ->(*) { fake })

    assert_raises(RuntimeError) { ctx[:mcp].mount! }
    assert_empty ctx[:mcp].mounted
    assert fake.disconnected, "the connected client must not leak"
    assert_equal 0, ctx[:tools].schemas.size

    ctx[:mcp].mount! # a retry must actually retry, not silently no-op
    assert_equal ["s"], ctx[:mcp].mounted
    assert_equal 1, ctx[:tools].schemas.size
  end
end
