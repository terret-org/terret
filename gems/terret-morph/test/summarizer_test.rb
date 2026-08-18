# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret/morph"

class MorphSummarizerTest < Minitest::Test
  HISTORY = [
    Terret::LLM::Message.new(role: :user, parts: [Terret::LLM::Text.new(text: "deploy the thing")]),
    Terret::LLM::Message.new(role: :assistant, parts: [Terret::LLM::Text.new(text: "Deployed.")])
  ].freeze

  def boot(transport:, config: {})
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "summarizer", plugin: Terret::Morph::Summarizer,
        config: { api_key: "test-key", transport: transport }.merge(config) }
    ])
    loader.boot!
  end

  def capture_warn
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  def test_happy_path_posts_the_agora_wire_shape_and_returns_output
    seen = nil
    transport = lambda do |url, headers, body|
      seen = [url, headers, JSON.parse(body, symbolize_names: true)]
      [200, JSON.generate({ output: "compressed transcript" })]
    end
    ctx = boot(transport: transport)

    assert_equal "compressed transcript", ctx[:summarizer].summarize(HISTORY)
    url, headers, body = seen
    assert_equal "https://api.morphllm.com/v1/compact", url
    assert_equal "Bearer test-key", headers["Authorization"]
    assert_equal "application/json", headers["Content-Type"]
    assert_in_delta 0.4, body[:compression_ratio]
    assert_equal 0, body[:preserve_recent]
    assert_includes body[:input], "user: deploy the thing"
    assert_includes body[:input], "assistant: Deployed."
  end

  def test_every_failure_mode_declines_to_nil_with_a_warn
    cases = {
      "HTTP 500"          => ->(*) { [500, "boom"] },
      "invalid JSON"      => ->(*) { [200, "not json"] },
      "unexpected shape"  => ->(*) { [200, JSON.generate([1, 2])] },
      "non-string output" => ->(*) { [200, JSON.generate({ output: 42 })] },
      "empty output"      => ->(*) { [200, JSON.generate({ output: "" })] },
      "transport error"   => ->(*) { raise IOError, "connection reset" }
    }
    cases.each do |label, transport|
      ctx = boot(transport: transport)
      result = nil
      warned = capture_warn { result = ctx[:summarizer].summarize(HISTORY) }
      assert_nil result, "#{label} must decline to nil"
      assert_match(/terret-morph/, warned, "#{label} must warn")
    end
  end

  def test_a_missing_api_key_declines_without_calling_the_transport
    called = false
    transport = ->(*) { called = true; [200, "{}"] }
    ctx = boot(transport: transport, config: { api_key: nil })
    old_env = ENV.delete("MORPH_API_KEY")
    begin
      warned = capture_warn { assert_nil ctx[:summarizer].summarize(HISTORY) }
      refute called, "no key, no call"
      assert_match(/MORPH_API_KEY/, warned)
    ensure
      ENV["MORPH_API_KEY"] = old_env if old_env
    end
  end

  def test_knobs_are_read_per_call_so_reconfigure_is_live
    urls = []
    transport = ->(url, *) { urls << url; [200, JSON.generate({ output: "x" })] }
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([{ id: "summarizer", plugin: Terret::Morph::Summarizer,
                    config: { api_key: "k", transport: transport } }])
    ctx = loader.boot!
    ctx[:summarizer].summarize(HISTORY)
    loader.reconfigure!("summarizer", { api_key: "k", transport: transport,
                                        api_base: "https://mirror.example/v1" })
    ctx[:summarizer].summarize(HISTORY)
    assert_equal ["https://api.morphllm.com/v1/compact", "https://mirror.example/v1/compact"], urls
  end

  def test_timeout_floors_zero_back_to_default
    ctx = boot(transport: ->(*) { [200, JSON.generate({ output: "x" })] },
               config: { timeout: 0 })
    assert_in_delta 30.0, ctx[:summarizer].send(:timeout)
  end

  def test_live_lane
    skip "set MORPH_LIVE=1 and MORPH_API_KEY for the live lane" unless ENV["MORPH_LIVE"] == "1" && ENV["MORPH_API_KEY"]
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([{ id: "summarizer", plugin: Terret::Morph::Summarizer, config: {} }])
    ctx = loader.boot!
    long = [Terret::LLM::Message.new(role: :user, parts: [Terret::LLM::Text.new(
      text: (1..40).map { |i| "line #{i}: fact number #{i} about the deploy" }.join("\n")
    )])]
    out = ctx[:summarizer].summarize(long)
    assert_kind_of String, out
    refute_empty out
    assert out.length < long.first.text.length, "extractive compression must shrink the input"
  end
end
