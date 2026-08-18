# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Terret
  module Morph
    # ctx[:summarizer] backed by Morph's Compact API (POST /v1/compact):
    # extractive line-level compression, surviving lines byte-identical. Wire
    # shape mirrors the deployed agora integration (Morph::CompactClient).
    # Every failure declines to nil with a warn — compaction is an
    # optimization, and the Compactor skips the boundary when declined. All
    # knobs are read per call, so reconfigure is live by construction.
    class Summarizer < Hames::Service
      service_key :summarizer

      DEFAULT_BASE    = "https://api.morphllm.com/v1"
      DEFAULT_TIMEOUT = 30.0
      DEFAULT_RATIO   = 0.4

      def start(_ctx); end

      def reconfigure(_config); end # knobs are read per call

      def summarize(history)
        key = api_key
        return decline("MORPH_API_KEY not configured") if key.nil? || key.empty?

        body = JSON.generate({ input: render(history),
                               compression_ratio: config[:compression_ratio] || DEFAULT_RATIO,
                               preserve_recent: 0 })
        status, response = transport.call("#{api_base}/compact",
                                          { "Authorization" => "Bearer #{key}",
                                            "Content-Type" => "application/json" },
                                          body)
        return decline("HTTP #{status}") unless (200..299).cover?(status)

        parsed = JSON.parse(response.to_s)
        return decline("unexpected response shape: #{parsed.class}") unless parsed.is_a?(Hash)

        output = parsed["output"]
        return decline("non-string output: #{output.class}") unless output.is_a?(String)

        output.empty? ? decline("empty output") : output
      rescue JSON::ParserError => e
        decline("invalid JSON: #{e.message}")
      rescue StandardError => e
        decline("#{e.class}: #{e.message}")
      end

      private

      def api_key  = config[:api_key] || ENV["MORPH_API_KEY"]
      def api_base = config[:api_base] || ENV["MORPH_API_BASE"] || DEFAULT_BASE

      # timeout=0 must not mean "no timeout" (the agora/Faraday lesson):
      # floor anything non-positive back to the default.
      def timeout
        configured = (config[:timeout] || ENV["MORPH_COMPACT_TIMEOUT"]).to_f
        configured.positive? ? configured : DEFAULT_TIMEOUT
      end

      # The transcript Morph compresses: role-tagged lines. Extractive
      # compression keeps surviving lines byte-identical, so the compacted
      # history the model sees is a strict subset of what it already saw.
      def render(history)
        history.map { |m| "#{m.role}: #{m.text}" }.join("\n")
      end

      def transport
        config[:transport] || method(:http_post)
      end

      def http_post(url, headers, body)
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = timeout
        http.read_timeout = timeout
        http.write_timeout = timeout
        response = http.post(uri.request_uri, body, headers)
        [response.code.to_i, response.body]
      end

      def decline(message)
        warn "terret-morph: compact declined: #{message}"
        nil
      end
    end
  end
end
