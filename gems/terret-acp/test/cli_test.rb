# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"

# `trt acp` boots a real composition and serves ACP on stdio. The suite needs
# async (the server parks the fiber); skip it when absent, as ws/openrouter do.
ASYNC_AVAILABLE = begin
  require "async"
  true
rescue LoadError
  false
end

if ASYNC_AVAILABLE
  require_relative "../../terret/lib/terret/boot" # Terret::CLI + Terret.boot, seeds the sibling load path
  require_relative "../lib/terret/acp"            # Terret::ACP::Service
  require_relative "fixtures/scripted_llm"        # a boot-time fake adapter
end

# The one integration test the plan asks for: a whole prompt turn driven
# through the `trt acp` subcommand, over an in-memory pipe, on a profile
# composed through Terret.boot with Memory + a scripted fake adapter. It proves
# the composed stack — CLI, boot, the acp row, the server, the loop — end to
# end, which the unit suites over a hand-built Loader cannot.
class CLITest < Minitest::Test
  def setup
    skip "async not installed" unless ASYNC_AVAILABLE
    @home = Dir.mktmpdir("terret-acp-home")
    @prev_home = ENV["TERRET_HOME"]
    ENV["TERRET_HOME"] = @home
  end

  def teardown
    ENV["TERRET_HOME"] = @prev_home
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
  end

  def write(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  # terret-base swapped offline, plus the acp row and a boot-time fake adapter.
  def offline_acp_profile(name = "editor")
    write(File.join(@home, "profiles", name, "profile.yml"), <<~YAML)
      bundles: [terret]
      settings:
        workspace: []
        store: { path: unused }
        model: { main: fake/scripted }
        sandbox: { image: unused }
    YAML
    write(File.join(@home, "profiles", name, "patch.yml"), <<~YAML)
      rows:
        - id: session_store
          plugin: Terret::Store::Memory
          config: {}
        - id: openrouter
          disabled: true
        - id: llm
          config: { roles: { main: fake/scripted } }
        - id: sandbox
          plugin: Terret::Exec::SandboxNone
          config: {}
        - id: scripted_llm
          plugin: Terret::ACPTest::ScriptedLLM
          after: llm
        - id: acp
          plugin: Terret::ACP::Service
          after: loop
    YAML
    name
  end

  def test_trt_acp_serves_a_whole_prompt_turn_over_stdio
    name = offline_acp_profile
    server_in, client_out = IO.pipe
    client_in, server_out = IO.pipe
    [client_out, server_out].each { |io| io.sync = true }
    err = StringIO.new

    # The server runs its own reactor in this thread; the test is the editor on
    # the other ends of the two pipes, reading and writing from the main thread.
    thread = Thread.new do
      Terret::CLI.start(["acp", "-p", name, "--home", @home],
                        out: server_out, err: err, input: server_in)
    end

    send = ->(h) { client_out.write("#{JSON.generate(h)}\n") }
    recv = -> { JSON.parse(client_in.gets, symbolize_names: true) }

    send.call(jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 })
    assert_equal 1, recv.call[:result][:protocolVersion]

    send.call(jsonrpc: "2.0", id: 2, method: "session/new",
              params: { cwd: "/workspace", mcpServers: [] })
    sid = recv.call[:result][:sessionId]
    refute_nil sid

    send.call(jsonrpc: "2.0", id: 3, method: "session/prompt",
              params: { sessionId: sid, prompt: [{ type: "text", text: "hi" }] })

    # Notifications stream before the pending prompt answers; read until id 3.
    frames = []
    loop do
      frame = recv.call
      frames << frame
      break if frame[:id] == 3
    end

    response = frames.find { |f| f[:id] == 3 }
    assert_equal "end_turn", response[:result][:stopReason]

    chunks = frames.select { |f| f[:method] == "session/update" }
                   .map { |f| f[:params][:update] }
                   .select { |u| u[:sessionUpdate] == "agent_message_chunk" }
                   .map { |u| u[:content][:text] }.join
    assert_equal "Hello from the editor.", chunks

    client_out.close # EOF -> the server read loop ends and serve returns
    assert_equal 0, thread.value, "the subcommand exits cleanly on disconnect"
    assert_includes err.string, "serving ACP on stdio", "diagnostics go to stderr, not the ACP stream"
  ensure
    thread&.join(2)
    [client_out, server_out, client_in, server_in].each { |io| io&.close unless io&.closed? }
  end
end
