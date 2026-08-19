# frozen_string_literal: true

module Terret
  # ctx[:titler] — one durable title per session (plan §6.2's titler role,
  # §12 M6). Rides the first turn/end: generates through the :titler model
  # role when the roles map has one, else falls back to the first user line
  # truncated to 40 chars. session/titled is metadata — projection-invisible,
  # like the approval and policy events — so titling can never disturb
  # derived context. The :role knob is read per call, so reconfigure is live
  # by construction.
  class Titler < Hames::Service
    service_key :titler
    inject :sessions, :llm
    config_schema role: { type: [String, Symbol], default: :titler,
                          doc: "llm role a title is generated under" }

    PROMPT = "Title this conversation in at most six words. Reply with the title only."

    def start(ctx)
      @ctx = ctx
      ctx.on("session/event") do |ev|
        next unless ev.type == "turn/end"
        next if @ctx[:sessions].title(ev.session_id)

        title!(ev.session_id)
      end
    end

    def reconfigure(_config); end

    # Append a title now (re-titling is the caller's explicit choice; the
    # listener above only ever titles once). Returns the event, or nil when
    # there is nothing to title.
    def title!(session_id)
      sessions = @ctx[:sessions]
      history = sessions.derive_messages(session_id)
      return if history.empty?

      title = (generate(history) || fallback(sessions.fetch(session_id).events)).to_s.strip
      return if title.empty?

      sessions.append(session_id, "session/titled", { title: title[0, 80] })
    end

    private

    def generate(history)
      request = LLM::Request.new(model: nil, system: PROMPT, messages: history, tools: [])
      @ctx[:llm].stream(@ctx, role: config[:role] || :titler, request: request) { |_ev| }.text
    rescue KeyError
      nil # no :titler role configured — the fallback carries it
    end

    def fallback(events)
      events.find { |e| e.type == "user/message" }&.payload&.[](:text)&.[](0, 40)
    end
  end
end
