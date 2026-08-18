# frozen_string_literal: true

module Terret
  # ctx[:compactor] — turns a long history into a short one without breaking
  # "model-visible means logged" (§2.5): the summary is itself a durable
  # event, and derive_messages projects it in place of everything at or
  # before its boundary. The §12 contract: upto_seq is ALWAYS the seq
  # immediately preceding the compaction event — the projection prepends the
  # summary, so any gap would interleave it among events that predate it.
  # The boundary is computed at append time, after the summarizer returns:
  # only projection-invisible events can land during summarization (the
  # agent is still mid-turn, so nothing model-visible can interleave).
  #
  # Summary GENERATION is a seam: ctx[:summarizer] (sole provider, like the
  # session store). A summarizer may decline by returning nil/empty —
  # compaction is an optimization, so a decline warns and the next
  # overweight turn retries. A summarizer that raises inside the trigger is
  # isolated by emit dispatch; a manual compact! raises through.
  class Compactor < Hames::Service
    service_key :compactor
    inject :sessions, :summarizer

    def start(ctx)
      @ctx = ctx
      @budget = config[:budget]
      # Always registered, gated at fire time: a hot-set budget (reconfigure)
      # arms the trigger without a remount.
      ctx.on("session/event") do |ev|
        next unless @budget && ev.type == "turn/end"

        compact!(ev.session_id) if overweight?(ev.session_id)
      end
    end

    def reconfigure(config)
      @budget = config[:budget]
    end

    # Summarize the whole projected history and append the boundary event.
    # Returns the appended SessionEvent, or nil when the summarizer declined.
    def compact!(session_id)
      sessions = @ctx[:sessions]
      history = sessions.derive_messages(session_id)
      raise ArgumentError, "nothing to compact in #{session_id}" if history.empty?

      summary = @ctx[:summarizer].summarize(history)
      unless summary.is_a?(String) && !summary.strip.empty?
        warn "terret: compaction skipped for #{session_id}: summarizer declined"
        return nil
      end

      sessions.append(session_id, "session/compacted",
                      { upto_seq: sessions.fetch(session_id).events.last.seq,
                        summary: summary })
    end

    private

    # The last step/end's prompt_tokens is what the next request will roughly
    # cost before compaction; over budget means compact now, while idle.
    def overweight?(session_id)
      last = @ctx[:sessions].fetch(session_id).events.reverse_each
                            .find { |e| e.type == "step/end" }
      tokens = last&.payload&.dig(:usage, :prompt_tokens)
      !!(tokens && tokens >= @budget)
    end
  end

  # ctx[:summarizer], the no-signup default: one model call through the
  # :compactor role (a config row away on any adapter). Raises KeyError when
  # the role is unconfigured — set the role or mount a provider that doesn't
  # need one (terret-morph).
  class RoleSummarizer < Hames::Service
    service_key :summarizer
    inject :llm

    PROMPT = <<~TEXT
      Summarize the conversation so far for your own future context. Preserve
      user goals and constraints, decisions made, tool results that still
      matter, and open questions. Reply with one compact briefing only.
    TEXT

    def start(ctx)
      @ctx = ctx
    end

    def reconfigure(_config); end # :role is read per call — already live

    def summarize(history)
      request = LLM::Request.new(model: nil, system: PROMPT, messages: history, tools: [])
      @ctx[:llm].stream(@ctx, role: config[:role] || :compactor, request: request) { |_ev| }.text
    end
  end
end
