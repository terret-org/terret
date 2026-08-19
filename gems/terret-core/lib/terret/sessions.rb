# frozen_string_literal: true

require "securerandom"
require "digest"
require "json"

module Terret
  SessionEvent = Data.define(:id, :session_id, :seq, :at, :type, :payload)

  class LogInvariantViolation < StandardError; end
  class NonPrimitivePayload < StandardError; end
  # A registered scrubber broke its contract. Distinct from
  # NonPrimitivePayload on purpose: that one means the DATA was unstorable
  # (something a caller can fix by encoding it), this one means a PLUGIN is
  # broken, and the two must not be rescued by the same handler.
  class ScrubberContractViolation < StandardError; end

  # ctx.sessions — the append-only session log. The single source of the
  # context the model sees: derive_messages projects model history from it,
  # and a digest invariant asserts that what goes out to an adapter is
  # exactly what replaying the log yields ("model-visible means logged").
  class Sessions < Hames::Service
    service_key :sessions
    inject :session_store
    config_schema({}) # the session log takes no config

    Session = Struct.new(:id, :events, :parent_id, keyword_init: true)

    # Payload keys whose values the harness minted to point at something else:
    # tool call ids and their approval foreign keys, the part tag decode_part
    # dispatches on, lineage, verdicts, the live allow list.
    # A pattern written for a credential — long hex, a UUID shape — matches
    # these too, and rewriting one protects nothing (none of it is
    # model-carried) while it can wreck the log for good: two tool calls that
    # collapse to one id are a request providers reject, a mangled tag makes
    # the session undecodable, and a rewritten pattern list silently changes
    # what an agent may run. Add a key here only when the harness itself
    # generates its value. A tool NAME is deliberately absent: the model
    # chooses it, so it is content — and redacting one fails safe, because a
    # name that stops resolving comes back as a not-found error rather than
    # collapsing two calls onto one identifier.
    STRUCTURAL_KEYS = %i[id call_id type verdict status agent parent_id
                         from boundary upto_seq n patterns].freeze

    # Keys whose value is a structural CONTAINER rather than a leaf: the
    # exemption reaches through them to the identifiers inside, because an
    # assistant message's encoded parts each carry their own tag and id.
    STRUCTURAL_CONTAINERS = %i[parts].freeze

    def start(ctx)
      @ctx = ctx
      @store = ctx[:session_store]
      @cache = {}
      @locks = {}
      @locks_mutex = Mutex.new
      @emit_mutex = Mutex.new
      @emit_queue = []
      @emitting = false
      @scrubbers = []
    end

    # Rewrite every String of every durable payload on its way into the log
    # (§13's log boundary; docs/exec.md §6). Registration is an effect, so the
    # returned disposer unregisters and unloading the owning plugin reaps it.
    #
    # This is the boundary the scrubbing has to happen at rather than anywhere
    # downstream: the stored event and every projection derived from it —
    # derive_messages, and so both sides of the digest assert_log_invariant!
    # compares — read the same already-scrubbed bytes, so "model-visible means
    # logged" holds by construction. A read-time filter over the projection
    # would leave the secret in the log itself and split the digest in two.
    #
    # Scrubbers fold in registration order: each is handed the previous one's
    # output, so a later one can rewrite what an earlier one produced.
    # What a live in-memory value would look like once stored, for a caller
    # that has to compare one against a payload already in the log — the
    # approvals gate matches a recorded verdict on the call's args, and
    # scrubbing rewrites one side of that comparison. CONTENT scope, because
    # such a value always sits nested under a content key (`args`), so its own
    # keys get no structural exemption.
    def stored_form(value) = normalize_payload(value, structural: false)

    # Whether anything is registered. Callers that must reshape what they
    # append to give a scrubber a fair look at it — the loop's chunk carry —
    # ask this so they can stay exactly as they were when nobody is scrubbing.
    def scrubbing? = !@scrubbers.empty?

    # `ctx:` decides the registration's LIFETIME, not its reach: the scrubber
    # list is the service's, so a scrubber always sees every append, but a
    # caller passing its forked agent context ties ownership to that fork —
    # the same bleed Registry#register closed, where a registration made by an
    # agent outlived the agent that made it.
    def register_scrubber(callable, ctx: @ctx)
      ctx.effect do
        @scrubbers << callable
        # Identity, not ==: removing "the entry equal to this callable" would
        # take a twin down with it if the same object were registered twice,
        # and a scrubber that defines its own == could unregister a stranger.
        lambda do
          i = @scrubbers.rindex { |s| s.equal?(callable) }
          @scrubbers.delete_at(i) if i
        end
      end
    end

    def create(id: SecureRandom.hex(6), parent_id: nil)
      s = Session.new(id:, events: [], parent_id:)
      @cache[id] = s
      append(id, "session/created", { parent_id: })
      s
    end

    def fetch(id) = @cache.fetch(id)

    def append(session_id, type, payload = {})
      decl = Hames.event(type)
      raise Hames::ContractError, "#{type} is not a durable event" unless decl.durable

      s = fetch(session_id)
      normalized = normalize_payload(payload)
      ev = lock_for(session_id).synchronize do
        e = SessionEvent.new(
          id: SecureRandom.hex(8), session_id:, seq: s.events.length,
          at: Time.now.utc, type: type.to_s, payload: normalized
        )
        # durable first: if the store raises, nothing believes the event happened
        @store.append(e)
        s.events << e
        e
      end
      fan_out(ev)
      ev
    end

    # Project provider-neutral model history from the durable log.
    def derive_messages(session_id, upto: nil)
      events = fetch(session_id).events
      events = events.take(upto) if upto
      apply_compaction(events).filter_map do |ev|
        case ev.type
        when "user/message", "context/injected"
          LLM::Message.new(role: :user, parts: [LLM::Text.new(text: ev.payload[:text])])
        when "session/compacted"
          LLM::Message.new(role: :user, parts: [LLM::Text.new(text: ev.payload[:summary])])
        when "assistant/message"
          LLM::Message.new(role: :assistant,
                           parts: ev.payload[:parts].map { |p| LLM.decode_part(p) })
        when "tool/result"
          LLM::Message.new(role: :tool, parts: [
            LLM::ToolResult.new(id: ev.payload[:id], content: ev.payload[:content],
                                error: ev.payload[:error])
          ])
        end
      end
    end

    # Lifetime spend, projected from the log: sums every step/end's usage.
    # A step whose provider sent no usage still counts as a step; its costs
    # count as zero rather than poisoning the sum.
    def usage(session_id)
      out = { prompt_tokens: 0, completion_tokens: 0, cost: 0.0, steps: 0 }
      fetch(session_id).events.each do |ev|
        next unless ev.type == "step/end"

        out[:steps] += 1
        u = ev.payload[:usage] or next
        out[:prompt_tokens]     += u[:prompt_tokens]     || 0
        out[:completion_tokens] += u[:completion_tokens] || 0
        out[:cost]              += u[:cost]              || 0.0
      end
      out
    end

    # The latest session/titled's title, or nil. Metadata, not model history.
    def title(session_id)
      fetch(session_id).events.reverse_each
                       .find { |e| e.type == "session/titled" }
                       &.payload&.[](:title)
    end

    # The enforcement point for "model-visible means logged": the loop calls
    # this with the message list it is about to send; a mismatch against the
    # log projection raises in dev/test.
    def assert_log_invariant!(session_id, outbound_messages)
      derived = derive_messages(session_id)
      return if digest(derived) == digest(outbound_messages)

      raise LogInvariantViolation,
            "outbound request diverges from session log projection for #{session_id}"
    end

    # Forks the in-memory working set; resume a store-only session first.
    def fork(source_id, boundary: nil, child_id: SecureRandom.hex(6))
      src = fetch(source_id)
      child = Session.new(id: child_id, events: [], parent_id: source_id)
      @cache[child_id] = child
      events = boundary ? src.events.take(boundary) : src.events.dup
      events.each do |ev|
        copy = ev.with(session_id: child_id)
        @store.append(copy)
        child.events << copy
      end
      append(child_id, "session/forked", { from: source_id, boundary: boundary })
      child
    end

    def read(session_id, from_seq: 0) = @store.read(session_id, from_seq: from_seq)

    def session_ids = @store.session_ids

    # Rebuild a session's working set from the durable store. Idempotent: a
    # session already in memory is returned as-is (write-through keeps the
    # store equal). New appends continue after the last recorded seq.
    def resume(session_id)
      return @cache[session_id] if @cache.key?(session_id)

      events = @store.read(session_id)
      raise KeyError, "unknown session #{session_id}" if events.empty?

      @cache[session_id] = Session.new(id: session_id, events: events,
                                       parent_id: parent_id_from(events))
    end

    private

    # Seq assignment, the durable write, and the memory push are one critical
    # section per session. The store write is a yield point — JSONL opens a
    # file, and a fiber scheduler switches there — so without this two
    # appenders (a connection frame and a turn, say) read the same
    # events.length and both claim it. Mutex is fiber-aware under the
    # scheduler, so this parks a fiber rather than stalling the reactor.
    def lock_for(session_id)
      @locks_mutex.synchronize { @locks[session_id] ||= Mutex.new }
    end

    # Fan-out runs OUTSIDE the append lock, and in seq order. A listener that
    # appends while handling an event — the compactor and the titler both do,
    # on turn/end — would otherwise deliver its nested event to every other
    # subscriber before the event it reacted to, so a socket tail would see
    # the log out of order. Queueing behind the delivery in flight fixes that,
    # at a price worth naming: a listener's own append returns before that
    # event fans out. Assumes one reactor; the flag is mutex-guarded so
    # threaded appenders cannot lose a queued event between the two.
    def fan_out(ev)
      @emit_mutex.synchronize do
        @emit_queue << ev
        return if @emitting

        @emitting = true
      end
      drain_emits
    end

    def drain_emits
      while (ev = next_emit)
        @ctx.emit("session/event", ev)
      end
    rescue Exception
      @emit_mutex.synchronize { @emitting = false }
      raise
    end

    def next_emit
      @emit_mutex.synchronize do
        ev = @emit_queue.shift
        @emitting = false unless ev
        ev
      end
    end

    # Compacted history is still model-visible, so it lives in the log and
    # projects as a user message standing in for everything at or before its
    # boundary. The latest compaction wins; superseded ones drop out.
    def apply_compaction(events)
      latest = nil
      events.each { |ev| latest = ev if ev.type == "session/compacted" }
      return events unless latest

      survivors = events.select do |ev|
        ev.seq > latest.payload[:upto_seq] && ev.type != "session/compacted"
      end
      [latest] + survivors
    end

    def parent_id_from(events)
      forked = events.reverse.find { |e| e.type == "session/forked" }
      forked ? forked.payload[:from] : events.first&.payload&.[](:parent_id)
    end

    # The primitives contract: durable payloads hold only strings, numbers,
    # booleans, nil, arrays, and symbol-keyed hashes of the same. Symbols in
    # value position become strings; string keys become symbols. Anything
    # else raises — typed objects are encoded at the edges (LLM.encode_part).
    #
    # `scrub` and `structural` carry the redaction scope down the recursion:
    # see STRUCTURAL_KEYS for what the exemption is and #child_scope for
    # where it stops.
    def normalize_payload(value, scrub: true, structural: true)
      case value
      when Integer, true, false, nil then value
      when String
        utf8 = begin
          value.encoding == Encoding::UTF_8 ? value : value.encode(Encoding::UTF_8)
        rescue EncodingError
          raise NonPrimitivePayload,
                "#{value.encoding.name} string does not convert to UTF-8; scrub it first"
        end
        unless utf8.valid_encoding?
          raise NonPrimitivePayload, "invalid UTF-8 string is not storable; scrub it first"
        end

        # After validation, so a scrubber is always handed storable UTF-8 —
        # and re-validated below, because it hands something back.
        scrub && !@scrubbers.empty? ? scrub_string(utf8) : utf8
      when Float
        raise NonPrimitivePayload, "non-finite Float is not storable" unless value.finite?

        value
        # Through the String arm rather than straight to the store: a symbol
        # in value position is content like any other, and `to_s` on an
        # ASCII-only symbol hands back a US-ASCII string that no scrubber
        # would have seen and no encoding check would have normalized.
      when Symbol then normalize_payload(value.to_s, scrub:, structural:)
      when Array then value.map { |v| normalize_payload(v, scrub:, structural:) }
      when Hash
        value.each_with_object({}) do |(k, v), out|
          key = case k
                when Symbol then k
                when String then k.to_sym
                else raise NonPrimitivePayload, "#{k.class} is not a storable hash key"
                end
          raise NonPrimitivePayload, "duplicate key #{key.inspect} after coercion" if out.key?(key)

          child_scrub, child_structural = child_scope(key, scrub, structural)
          out[key] = normalize_payload(v, scrub: child_scrub, structural: child_structural)
        end
      else
        raise NonPrimitivePayload, "#{value.class} is not storable; encode it first"
      end
    end

    # Where a key sits decides whether its value is exempt, because the same
    # NAME means different things at different depths: `parts[0][:name]` is
    # the tool a model called, while `args[:name]` is a terminal name the
    # model itself wrote and `args[:content]` is a whole file. So the
    # exemption holds only while nothing content-bearing has been entered:
    # descending into anything outside these two lists turns it off for good,
    # and everything below that point is scrubbed whatever it is called.
    def child_scope(key, scrub, structural)
      return [false, false] unless scrub # already inside an exempt subtree
      return [false, false] if structural && STRUCTURAL_KEYS.include?(key)
      return [true, true]   if structural && STRUCTURAL_CONTAINERS.include?(key)

      [true, false]
    end

    # Fold a payload string through the registered scrubbers, checking each
    # answer. A scrubber runs after the primitives contract has already
    # admitted the value, so a bad answer would land in the store unexamined:
    # a nil where text was, or bytes the store's JSON generator rejects a
    # frame later, with nothing left to say which plugin did it. Model-reachable
    # data must never crash the harness, but a broken PLUGIN may and should —
    # so this raises, naming the offender (a Proc's inspect carries its
    # source location) rather than repairing what it cannot guess at.
    def scrub_string(text)
      @scrubbers.reduce(text) do |acc, scrubber|
        out = scrubber.call(acc)
        unless out.is_a?(String)
          raise ScrubberContractViolation,
                "scrubber #{scrubber.inspect} returned #{out.class}, not a String"
        end
        unless out.encoding == Encoding::UTF_8 && out.valid_encoding?
          raise ScrubberContractViolation,
                "scrubber #{scrubber.inspect} returned #{out.encoding.name} that is not valid " \
                "UTF-8; a scrubber is handed UTF-8 and must hand UTF-8 back"
        end

        out
      end
    end

    def digest(messages)
      Digest::SHA256.hexdigest(messages.map(&:inspect).join("\x1e"))
    end
  end
end
