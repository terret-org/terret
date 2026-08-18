# frozen_string_literal: true

require "json"

module Terret
  module OpenRouter
    # The ctx.llm adapter. Transport is injectable: tests drive it with canned
    # SSE bodies; the default (lazily required) streams over async-http.
    # Retries apply only before any bytes have streamed — once the consumer
    # has seen deltas, a failure surfaces as StreamError and raises.
    class Adapter < LLM::AdapterBase
      DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"

      def initialize(api_key: nil, base_url: DEFAULT_BASE_URL, referer: nil,
                     title: nil, transport: nil, **retry_opts)
        super(**retry_opts)
        @api_key = api_key
        @base_url = base_url.chomp("/")
        @referer = referer
        @title = title
        @transport = transport
      end

      def stream(request, &on_event)
        body = JSON.generate(Translate.request_body(request))
        headers = request_headers
        with_retries do
          transport.call(url: "#{@base_url}/chat/completions",
                         headers: headers, body: body) do |status, chunks|
            check_status!(status, chunks)
            consume(chunks, &on_event)
          end
        end
      end

      private

      def consume(chunks, &on_event)
        parser = SSE::Parser.new
        acc = Accumulator.new
        chunks.each do |chunk|
          parser.feed(chunk) do |data|
            next if data == "[DONE]"

            acc.feed(JSON.parse(data, symbolize_names: true), &on_event)
          end
        end
        if (err = acc.error)
          raise LLM::AdapterError.new("mid-stream error: #{err.message}", status: err.code)
        end

        acc.finalize(&on_event)
      end

      def check_status!(status, chunks)
        return if status == 200

        body = chunks.to_a.join
        message = begin
          JSON.parse(body).dig("error", "message") || body
        rescue JSON::ParserError
          body
        end
        klass = status == 429 || status >= 500 ? LLM::RetryableError : LLM::AdapterError
        raise klass.new("OpenRouter #{status}: #{message}", status: status, body: body)
      end

      def request_headers
        key = @api_key || ENV["OPENROUTER_API_KEY"]
        unless key
          raise LLM::AdapterError, "no OpenRouter API key (set OPENROUTER_API_KEY or pass api_key:)"
        end

        headers = { "Authorization" => "Bearer #{key}", "Content-Type" => "application/json" }
        headers["HTTP-Referer"] = @referer if @referer
        headers["X-OpenRouter-Title"] = @title if @title # renamed upstream from X-Title
        headers
      end

      def transport
        @transport ||= begin
          require_relative "async_transport"
          AsyncTransport.new
        end
      end
    end
  end
end
