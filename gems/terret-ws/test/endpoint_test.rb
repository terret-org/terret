# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "socket"

WS_AVAILABLE = begin
  require "async"
  require "async/websocket/client"
  require "async/http/endpoint"
  true
rescue LoadError
  false
end

require_relative "../lib/terret/ws" if WS_AVAILABLE

class EndpointTest < Minitest::Test
  def setup
    skip "async-websocket not installed" unless WS_AVAILABLE
  end

  def boot(script:, tokens:)
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
      { id: "ws",       plugin: Terret::WS::Service, config: { tokens: tokens, heartbeat: 1 } }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))
    ctx
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def test_a_real_turn_over_a_real_socket
    ctx = boot(script: [{ text: "Hello over websocket." }], tokens: { "s1" => "secret" })
    port = free_port

    Sync do |task|
      server = task.async { ctx[:ws].serve(port: port) }
      sleep 0.2 # let the listener bind

      endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:#{port}/agents/s1/ws")
      frames = []
      Async::WebSocket::Client.connect(endpoint,
                                       headers: [["authorization", "Bearer secret"]]) do |conn|
        conn.write(JSON.generate(type: "subscribe", from_seq: 0))
        conn.write(JSON.generate(type: "inject", text: "hi", wake: true))
        while (msg = conn.read)
          frame = JSON.parse(msg.to_str, symbolize_names: true)
          frames << frame
          break if frame[:type] == "turn/end"
        end
      end

      assert_equal "hello", frames.first[:type]
      chunkless = frames.select { |f| f.key?(:seq) }.map { |f| f[:type] }
                        .reject { |t| t == "assistant/chunk" }
      assert_equal %w[
        session/created
        turn/start
        step/start user/message assistant/message step/end
        turn/end
      ], chunkless
      server.stop
    end
  end

  def test_a_bad_token_gets_an_unauthorized_error_frame
    ctx = boot(script: [], tokens: { "s1" => "secret" })
    port = free_port

    Sync do |task|
      server = task.async { ctx[:ws].serve(port: port) }
      sleep 0.2

      endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:#{port}/agents/s1/ws")
      frames = []
      Async::WebSocket::Client.connect(endpoint,
                                       headers: [["authorization", "Bearer wrong"]]) do |conn|
        while (msg = conn.read)
          frames << JSON.parse(msg.to_str, symbolize_names: true)
        end
      rescue EOFError
        # server closed on us, which is the point
      end

      assert_equal [{ type: "error", code: "unauthorized" }], frames
      server.stop
    end
  end

  def test_a_binary_frame_gets_bad_frame_and_the_connection_survives
    ctx = boot(script: [{ text: "hi" }], tokens: { "s1" => "secret" })
    port = free_port

    Sync do |task|
      server = task.async { ctx[:ws].serve(port: port) }
      sleep 0.2

      endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:#{port}/agents/s1/ws")
      frames = []
      Async::WebSocket::Client.connect(endpoint,
                                       headers: [["authorization", "Bearer secret"]]) do |conn|
        # The wire contract is JSON text frames only -- a binary frame with
        # otherwise-valid JSON payload must still be rejected as bad_frame.
        conn.send_binary(JSON.generate(type: "subscribe", from_seq: 0))
        frames << JSON.parse(conn.read.to_str, symbolize_names: true) # hello
        frames << JSON.parse(conn.read.to_str, symbolize_names: true) # bad_frame

        # the connection must still work normally afterward
        conn.write(JSON.generate(type: "subscribe", from_seq: 0))
        conn.write(JSON.generate(type: "inject", text: "hi", wake: true))
        while (msg = conn.read)
          frame = JSON.parse(msg.to_str, symbolize_names: true)
          frames << frame
          break if frame[:type] == "turn/end"
        end
      end

      assert_equal "hello", frames[0][:type]
      assert_equal "error", frames[1][:type]
      assert_equal "bad_frame", frames[1][:code]

      chunkless = frames.select { |f| f.key?(:seq) }.map { |f| f[:type] }
                        .reject { |t| t == "assistant/chunk" }
      assert_equal %w[
        session/created
        turn/start
        step/start user/message assistant/message step/end
        turn/end
      ], chunkless
      server.stop
    end
  end
end
