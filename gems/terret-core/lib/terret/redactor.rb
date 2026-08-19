# frozen_string_literal: true

module Terret
  # ctx[:redactor] — §13's "credentials never enter the session log", in the
  # two layers docs/exec.md §6 describes.
  #
  # The FIRST is a tools/post_execute listener: the waterfall every tool
  # result already passes through, so a tool that happened to hand back a
  # credential is rewritten before the loop appends it — and before any other
  # post_execute listener, or any in-memory consumer of the Result, reads it.
  #
  # The SECOND is a Sessions scrubber, and it is the one that makes the
  # promise true rather than likely: a secret can reach the log through a path
  # that never touches a tool result at all — a user's own message, an
  # injected steer, a plugin's durable event — and register_scrubber runs over
  # every String of every append regardless of type. Because that runs INSIDE
  # normalize_payload, the stored bytes and every projection derived from them
  # agree by construction, so the log invariant needs nothing special here.
  #
  # What this is not: comprehensive. Patterns are regexp sources on this row's
  # config, so it catches shapes a deployment named and nothing else. Driving
  # them from ctx[:credentials] (plan §6.9) is M8's job.
  class Redactor < Hames::Service
    service_key :redactor
    inject :sessions

    DEFAULT_REPLACEMENT = "[REDACTED]"

    def start(ctx)
      @ctx = ctx
      @patterns = compile(config[:patterns])

      ctx.on("tools/post_execute") { |result, next_| next_.(redact_result(result)) }
      # Registered through the seam rather than as a second listener: this
      # runs at the append boundary itself (Sessions#register_scrubber), which
      # is the whole reason the backstop is trustworthy.
      ctx[:sessions].register_scrubber(method(:redact))
    end

    # Patterns are compiled, so they are the one thing a hot swap has to
    # re-derive; the replacement token is read per call and is already live.
    # An uncompilable pattern raises here, and the loader rolls the row back.
    def reconfigure(config)
      @patterns = compile(config[:patterns])
    end

    # The redaction itself, and the method the Sessions scrubber calls. A
    # non-String is handed straight back: this is reached from the tools
    # pipeline too, where a result's content may be anything a handler
    # returned.
    def redact(text)
      return text unless text.is_a?(String)

      # gsub's BLOCK form, not its string form, which would read `\0`/`\1` in
      # a deployment's replacement token as backreferences — a token
      # containing `\0` would paste the matched secret back in and leave a
      # redactor that silently un-redacts.
      @patterns.reduce(text) { |acc, pattern| acc.gsub(pattern) { replacement } }
    end

    private

    def replacement = config[:replacement] || DEFAULT_REPLACEMENT

    # Both fields, because both are model-visible: derive_messages projects a
    # tool/result's error alongside its content, so a handler that echoes the
    # credential it was handed into a Failure message leaks through exactly
    # the same door. The append scrubber would catch either, but this layer
    # exists so the Result object itself is clean the moment it leaves the
    # pipeline.
    def redact_result(result)
      return result unless result.is_a?(Tools::Result)

      result.with(content: redact(result.content), error: redact(result.error))
    end

    # A pattern that does not compile is a configuration bug, so it fails at
    # boot (or at the reconfigure that introduced it) rather than raising on
    # every append forever after. A Regexp is accepted as itself, so a plugin
    # composing rows in Ruby need not stringify what it already has.
    def compile(patterns)
      Array(patterns).map do |pattern|
        next pattern if pattern.is_a?(Regexp)

        begin
          Regexp.new(pattern.to_s)
        rescue RegexpError => e
          raise RegexpError, "redactor pattern #{pattern.inspect} does not compile: #{e.message}"
        end
      end
    end
  end
end
