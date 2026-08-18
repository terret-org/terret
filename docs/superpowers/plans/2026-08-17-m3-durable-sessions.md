# M3 Durable Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The append-only session log survives the process exactly — SQLite/JSONL/memory store providers behind a `ctx[:session_store]` seam, resume/replay APIs, the compaction event decided, and a session sidebar in the web chat.

**Architecture:** Payloads become primitives at the append boundary (typed `LLM` parts encoded/decoded at the edges), so `decode(JSON(payload)) == payload` holds for every stored byte. `Sessions` keeps in-memory working sets and writes through to a provider. Spec: `docs/superpowers/specs/2026-08-17-m3-durable-sessions-design.md`.

**Tech Stack:** Ruby 4.0.6 (ALWAYS `mise exec -- ruby`/`rake`, never bare — the rbenv shim is broken), minitest, sqlite3 2.9.6 (verified working locally, precompiled). Repo conventions: plain imperative commit messages, NO attribution trailers, NO conventional-commit prefixes, work directly on main.

**Core tests are TDD (strict red-green).** The web chat file is examples convention: syntax check + boot check, live verification at the end.

---

### Task 1: The part codec

**Files:**
- Modify: `gems/terret-core/lib/terret/llm.rb` (after the `MessageStop` definition)
- Create: `gems/terret-core/test/llm_codec_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/terret"

# The part codec is the typed edge of the primitives contract: durable logs
# hold only storage-shaped hashes; adapters see only Data objects.
class LLMPartCodecTest < Minitest::Test
  L = Terret::LLM

  PARTS = [
    L::Text.new(text: "hello"),
    L::ToolCall.new(id: "tc1", name: "weather", args: { city: "CDMX" }),
    L::ToolResult.new(id: "tc1", content: "22C", error: nil),
    L::ToolResult.new(id: "tc2", content: nil, error: "denied")
  ].freeze

  def test_every_part_type_round_trips_through_primitives_and_json
    PARTS.each do |part|
      encoded = L.encode_part(part)
      tripped = JSON.parse(JSON.generate(encoded), symbolize_names: true)
      assert_equal part, L.decode_part(tripped)
    end
  end

  def test_encoded_parts_carry_storage_names_not_class_names
    assert_equal "tool_call", L.encode_part(PARTS[1])[:type]
    refute_match(/Terret/, JSON.generate(L.encode_part(PARTS[1])))
  end

  def test_unknown_part_and_unknown_tag_raise
    assert_raises(ArgumentError) { L.encode_part(Object.new) }
    assert_raises(ArgumentError) { L.decode_part({ type: "hologram" }) }
  end
end
```

- [ ] **Step 2: Verify RED**

Run: `mise exec -- ruby gems/terret-core/test/llm_codec_test.rb`
Expected: errors with `undefined method 'encode_part'` (NoMethodError), not test-file bugs.

- [ ] **Step 3: Implement — insert into `module LLM` in llm.rb, directly after the `MessageStop` line and before the `AdapterError` class**

```ruby
    # Storage codec for message parts. Durable logs hold only these primitive,
    # storage-named hashes ("text", never Terret::LLM::Text), so a class
    # rename can never invalidate stored sessions. decode(encode(p)) == p.
    module_function

    def encode_part(part)
      case part
      when Text       then { type: "text", text: part.text }
      when ToolCall   then { type: "tool_call", id: part.id, name: part.name, args: part.args }
      when ToolResult then { type: "tool_result", id: part.id, content: part.content, error: part.error }
      else raise ArgumentError, "cannot encode #{part.class} as a message part"
      end
    end

    def decode_part(hash)
      case hash[:type]
      when "text"        then Text.new(text: hash[:text])
      when "tool_call"   then ToolCall.new(id: hash[:id], name: hash[:name], args: hash[:args])
      when "tool_result" then ToolResult.new(id: hash[:id], content: hash[:content], error: hash[:error])
      else raise ArgumentError, "unknown part tag #{hash[:type].inspect}"
      end
    end
```

Note: `module_function` scopes only the two defs that follow it; the classes later in the module are unaffected.

- [ ] **Step 4: Verify GREEN, full suite**

Run: `mise exec -- ruby gems/terret-core/test/llm_codec_test.rb` → 3 runs, 0 failures.
Run: `mise exec -- rake test` → all suites green.

- [ ] **Step 5: Commit**

```bash
git add gems/terret-core/lib/terret/llm.rb gems/terret-core/test/llm_codec_test.rb
git commit -m "Add the storage codec for message parts

Durable logs will hold only primitive, storage-named hashes; typed
Data parts exist at the edges. Storage tags are deliberately not
class names, so a rename never invalidates stored sessions."
```

### Task 2: Primitives at the append boundary

**Files:**
- Modify: `gems/terret-core/lib/terret/sessions.rb`
- Modify: `gems/terret-core/lib/terret/loop.rb` (one line)
- Modify: `gems/terret-core/test/loop_test.rb` (two assertions + one new test)
- Create: `gems/terret-core/test/sessions_test.rb`

- [ ] **Step 1: Write the failing tests — new file sessions_test.rb**

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/terret"

class SessionsPrimitivesTest < Minitest::Test
  def sessions_ctx
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([{ id: "sessions", plugin: Terret::Sessions }])
    loader.boot!
  end

  def test_symbols_in_value_position_become_strings
    ctx = sessions_ctx
    s = ctx[:sessions].create
    ev = ctx[:sessions].append(s.id, "turn/end", { status: :failed })
    assert_equal "failed", ev.payload[:status]
  end

  def test_payloads_survive_a_json_round_trip_exactly
    ctx = sessions_ctx
    s = ctx[:sessions].create
    ev = ctx[:sessions].append(s.id, "tool/call",
                               { id: "t1", name: "weather", args: { :city => "CDMX", "n" => 2 } })
    tripped = JSON.parse(JSON.generate(ev.payload), symbolize_names: true)
    assert_equal ev.payload, tripped
    assert_equal 2, ev.payload[:args][:n] # string key coerced to symbol
  end

  def test_non_primitive_payloads_are_rejected
    ctx = sessions_ctx
    s = ctx[:sessions].create
    assert_raises(Terret::NonPrimitivePayload) do
      ctx[:sessions].append(s.id, "user/message", { text: Object.new })
    end
  end
end
```

- [ ] **Step 2: Also update loop_test.rb (these go RED after the implementation if forgotten — do them now):** in `test_pre_step_rejection_closes_a_durable_zero_step_turn` change `assert_equal :rejected, session.events.last.payload[:status]` to `assert_equal "rejected", ...`; in `test_a_failed_turn_still_closes_with_a_durable_turn_end` change `assert_equal :failed, ...` to `assert_equal "failed", ...`. Then ADD this test to TurnFlowTest:

```ruby
  def test_assistant_message_payloads_are_stored_as_primitives
    ctx, = boot(script: two_step_script)
    register_weather(ctx)
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "Weather?")

    parts = session.events.select { |e| e.type == "assistant/message" }
                   .flat_map { |e| e.payload[:parts] }
    assert(parts.all? { |p| p.is_a?(Hash) && p[:type].is_a?(String) })
    assert_equal parts, JSON.parse(JSON.generate(parts), symbolize_names: true)
  end
```

(loop_test.rb needs `require "json"` added below the minitest require.)

- [ ] **Step 3: Verify RED**

Run: `mise exec -- ruby gems/terret-core/test/sessions_test.rb` → symbol test fails (`:failed` ≠ `"failed"`), rejection test fails (nothing raised).
Run: `mise exec -- ruby gems/terret-core/test/loop_test.rb` → the new primitives test fails (parts are Data objects); the two status assertions fail (`:rejected`/`:failed` are still symbols).

- [ ] **Step 4: Implement**

In sessions.rb, next to `LogInvariantViolation`:

```ruby
  class NonPrimitivePayload < StandardError; end
```

In `Sessions#append`, change `payload: payload` to `payload: normalize_payload(payload)`. Add to the private section:

```ruby
    # The primitives contract: durable payloads hold only strings, numbers,
    # booleans, nil, arrays, and symbol-keyed hashes of the same. Symbols in
    # value position become strings; string keys become symbols. Anything
    # else raises — typed objects are encoded at the edges (LLM.encode_part).
    def normalize_payload(value)
      case value
      when String, Integer, Float, true, false, nil then value
      when Symbol then value.to_s
      when Array then value.map { |v| normalize_payload(v) }
      when Hash
        value.each_with_object({}) do |(k, v), out|
          key = k.is_a?(Symbol) ? k : k.to_s.to_sym
          raise NonPrimitivePayload, "duplicate key #{key.inspect} after coercion" if out.key?(key)

          out[key] = normalize_payload(v)
        end
      else
        raise NonPrimitivePayload, "#{value.class} is not storable; encode it first"
      end
    end
```

In `Sessions#derive_messages`, change the assistant branch to decode:

```ruby
        when "assistant/message"
          LLM::Message.new(role: :assistant,
                           parts: ev.payload[:parts].map { |p| LLM.decode_part(p) })
```

In loop.rb, change the assistant/message append to encode:

```ruby
        sessions.append(sid, "assistant/message",
                        { parts: message.parts.map { |p| LLM.encode_part(p) } })
```

- [ ] **Step 5: Verify GREEN, full suite**

Run: `mise exec -- rake test` → every suite green (openrouter's PluginTest exercises the whole stack and must stay green — its derived tool-history round-trip proves encode/decode digest consistency).
Run: `mise exec -- ruby examples/headless_demo.rb` → still renders the transcript and prints `derived history roles: user -> assistant -> tool -> tool -> assistant`.

- [ ] **Step 6: Commit**

```bash
git add gems/terret-core/lib/terret/sessions.rb gems/terret-core/lib/terret/loop.rb gems/terret-core/test/loop_test.rb gems/terret-core/test/sessions_test.rb
git commit -m "Enforce primitive payloads at the append boundary

The durable log is now storage-shaped everywhere: symbols coerce to
strings, string keys to symbols, typed parts encode through the LLM
codec, and anything else raises NonPrimitivePayload. This is the
property restart-exact persistence rests on: a JSON round trip of
any stored payload is the identity."
```

### Task 3: The store seam and the Memory provider

**Files:**
- Create: `gems/terret-core/lib/terret/store.rb`
- Create: `gems/terret-core/test/store_contract.rb` (shared module, NOT a `*_test.rb` file)
- Create: `gems/terret-core/test/store_memory_test.rb`
- Modify: `gems/terret-core/lib/terret.rb` (one require line)
- Modify: `gems/terret-core/lib/terret/sessions.rb`
- Modify: `gems/terret-core/test/loop_test.rb`, `gems/terret-core/test/sessions_test.rb` (boot rows)
- Modify: `gems/terret-openrouter/test/openrouter_test.rb` (two boot row lists)
- Modify: `examples/headless_demo.rb`, `examples/openrouter_demo.rb`, `examples/web_chat.rb` (boot rows)

- [ ] **Step 1: Write the shared contract (store_contract.rb)**

```ruby
# frozen_string_literal: true

# Behavioral contract every session store provider must satisfy. Include
# into a Minitest class that defines `build_store` returning a started
# provider instance.
module StoreContract
  def contract_event(session_id, seq, type: "user/message", payload: { text: "e#{seq}" })
    Terret::SessionEvent.new(
      id: "id-#{session_id}-#{seq}", session_id: session_id, seq: seq,
      at: Time.at(1_755_000_000 + seq, seq, :microsecond).utc, type: type, payload: payload
    )
  end

  def test_append_then_read_returns_events_in_order
    store = build_store
    3.times { |i| store.append(contract_event("s1", i)) }
    assert_equal [0, 1, 2], store.read("s1").map(&:seq)
    assert_equal %w[e0 e1 e2], store.read("s1").map { |e| e.payload[:text] }
  end

  def test_read_from_seq_replays_the_exact_tail
    store = build_store
    5.times { |i| store.append(contract_event("s1", i)) }
    assert_equal [3, 4], store.read("s1", from_seq: 3).map(&:seq)
  end

  def test_sessions_are_isolated_and_listed
    store = build_store
    store.append(contract_event("s1", 0))
    store.append(contract_event("s2", 0))
    assert_equal [], store.read("s3")
    assert_equal %w[s1 s2], store.session_ids.sort
  end

  def test_envelopes_round_trip_exactly
    store = build_store
    original = contract_event("s1", 0, type: "assistant/message",
                              payload: { parts: [{ type: "text", text: "héllo\nworld" }] })
    store.append(original)
    assert_equal original, store.read("s1").first
  end
end
```

- [ ] **Step 2: Write store_memory_test.rb**

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret"
require_relative "store_contract"

class MemoryStoreTest < Minitest::Test
  include StoreContract

  def build_store
    store = Terret::Store::Memory.new
    store.start(nil)
    store
  end
end
```

- [ ] **Step 3: Verify RED** — `mise exec -- ruby gems/terret-core/test/store_memory_test.rb` errors with `uninitialized constant Terret::Store`.

- [ ] **Step 4: Implement store.rb**

```ruby
# frozen_string_literal: true

module Terret
  # ctx[:session_store] — the persistence seam behind ctx.sessions. Providers
  # durably record SessionEvents (whose payloads are primitives by the append
  # contract) and hand them back exactly. Swapping the provider is a config
  # row edit; Sessions never knows which one it is talking to. start is
  # idempotent on every provider so an instance can ride across reboots.
  module Store
    # In-memory provider: the test default. Events are immutable, so sharing
    # objects with Sessions' working set costs nothing.
    class Memory < Hames::Service
      service_key :session_store

      def start(_ctx)
        @events ||= Hash.new { |h, k| h[k] = [] }
      end

      def append(event) = @events[event.session_id] << event

      def read(session_id, from_seq: 0)
        @events[session_id].select { |ev| ev.seq >= from_seq }
      end

      def session_ids = @events.keys
    end
  end
end
```

Add `require_relative "terret/store"` in `gems/terret-core/lib/terret.rb`, after the `terret/llm` require (Store subclasses Hames::Service, already loaded).

- [ ] **Step 5: Wire Sessions through the seam.** In sessions.rb: add `inject :session_store` under `service_key :sessions`. Rename the sessions hash to avoid confusion and write through:

```ruby
    def start(ctx)
      @ctx = ctx
      @store = ctx[:session_store]
      @cache = {}
    end
```

`create`: store into `@cache` instead of the old ivar. `fetch(id) = @cache.fetch(id)`. In `append`, after `s.events << ev` add `@store.append(ev)`. In `fork`, `@store[child_id] = child` becomes `@cache[child_id] = child`, and each copied event also writes through: inside the copy loop, `copy = ev.with(session_id: child_id)`, `child.events << copy`, `@store.append(copy)`. DELETE the `persist` method, the `@dir = config[:jsonl_dir]` line, and the `persist(ev)` call — the JSONL provider replaces them in Task 5. Leave the file's requires as they are. Add the two public delegates:

```ruby
    def read(session_id, from_seq: 0) = @store.read(session_id, from_seq: from_seq)

    def session_ids = @store.session_ids
```

- [ ] **Step 6: Add the store row everywhere.** Add `{ id: "session_store", plugin: Terret::Store::Memory },` as the FIRST row of every loader.layer list in: loop_test.rb (TerretTestHarness#boot), sessions_test.rb (sessions_ctx), openrouter_test.rb (PluginTest#boot AND LiveSmokeTest), examples/headless_demo.rb, examples/openrouter_demo.rb, examples/web_chat.rb.

- [ ] **Step 7: Verify GREEN** — `mise exec -- rake test` all green (5 test files now); `mise exec -- ruby examples/headless_demo.rb` works; `mise exec -- ruby -c examples/web_chat.rb` and `mise exec -- ruby -c examples/openrouter_demo.rb` → Syntax OK.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Put a session_store seam behind ctx.sessions

Sessions keeps its in-memory working set and writes every event
through ctx[:session_store]; the in-memory provider is the test
default and the row is explicit in every boot, because a visible
row is what makes the provider swap story real. The broken
payload.inspect JSONL side-write is gone."
```

### Task 4: Resume, fork lineage, replay-vs-tail

**Files:**
- Modify: `gems/terret-core/lib/terret/sessions.rb`
- Modify: `gems/terret-core/test/sessions_test.rb`

- [ ] **Step 1: Write the failing tests (append to sessions_test.rb, inside the class)**

```ruby
  def boot_with_store(store)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: store },
      { id: "sessions", plugin: Terret::Sessions }
    ])
    loader.boot!
  end

  def test_resume_rebuilds_a_session_from_the_store_and_continues_appending
    store = Terret::Store::Memory.new
    ctx1 = boot_with_store(store)
    s = ctx1[:sessions].create
    ctx1[:sessions].append(s.id, "user/message", { text: "hello" })

    ctx2 = boot_with_store(store) # same provider instance = same durable state
    resumed = ctx2[:sessions].resume(s.id)
    assert_equal s.events, resumed.events

    n = resumed.events.length
    ev = ctx2[:sessions].append(s.id, "user/message", { text: "again" })
    assert_equal n, ev.seq
  end

  def test_resume_is_idempotent_and_unknown_sessions_raise
    store = Terret::Store::Memory.new
    ctx = boot_with_store(store)
    s = ctx[:sessions].create
    assert_same ctx[:sessions].resume(s.id), ctx[:sessions].resume(s.id)
    assert_raises(KeyError) { ctx[:sessions].resume("nope") }
  end

  def test_replay_from_seq_equals_a_live_tail_from_that_point
    ctx = sessions_ctx
    sessions = ctx[:sessions]
    s = sessions.create
    3.times { |i| sessions.append(s.id, "user/message", { text: "before #{i}" }) }

    from = s.events.length
    tail = []
    ctx.on("session/event") { |ev| tail << ev if ev.session_id == s.id }
    3.times { |i| sessions.append(s.id, "user/message", { text: "after #{i}" }) }

    assert_equal tail, sessions.read(s.id, from_seq: from)
  end

  def test_fork_lineage_survives_resume
    store = Terret::Store::Memory.new
    ctx1 = boot_with_store(store)
    s = ctx1[:sessions].create
    ctx1[:sessions].append(s.id, "user/message", { text: "hello" })
    child = ctx1[:sessions].fork(s.id)

    ctx2 = boot_with_store(store)
    resumed = ctx2[:sessions].resume(child.id)
    assert_equal s.id, resumed.parent_id
    assert_equal child.events, resumed.events
  end
```

- [ ] **Step 2: Verify RED** — `mise exec -- ruby gems/terret-core/test/sessions_test.rb` → NoMethodError `resume`.

- [ ] **Step 3: Implement in sessions.rb (public, near fork)**

```ruby
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
```

and in the private section:

```ruby
    def parent_id_from(events)
      forked = events.reverse.find { |e| e.type == "session/forked" }
      forked ? forked.payload[:from] : events.first&.payload&.[](:parent_id)
    end
```

- [ ] **Step 4: Verify GREEN, full suite** — `mise exec -- rake test` all green.

- [ ] **Step 5: Commit**

```bash
git add gems/terret-core/lib/terret/sessions.rb gems/terret-core/test/sessions_test.rb
git commit -m "Add resume and the replay-from-seq contract to sessions

resume rebuilds a working set from the store and appending continues
after the last seq; read(from_seq:) provably equals a live tail from
the same point, which is the reconnect contract the socket will
inherit. Fork lineage survives the trip."
```

### Task 5: The JSONL provider

**Files:**
- Modify: `gems/terret-core/lib/terret/store.rb`
- Create: `gems/terret-core/test/store_jsonl_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/terret"
require_relative "store_contract"

class JSONLStoreTest < Minitest::Test
  include StoreContract

  def build_store
    store = Terret::Store::JSONL.new(dir: File.join(Dir.mktmpdir("terret-jsonl"), "sessions"))
    store.start(nil)
    store
  end

  def test_a_fresh_instance_reads_what_another_wrote
    dir = File.join(Dir.mktmpdir("terret-jsonl"), "sessions")
    writer = Terret::Store::JSONL.new(dir: dir)
    writer.start(nil)
    writer.append(contract_event("s1", 0))

    reader = Terret::Store::JSONL.new(dir: dir)
    reader.start(nil)
    assert_equal writer.read("s1"), reader.read("s1")
    assert_equal ["s1"], reader.session_ids
  end
end
```

- [ ] **Step 2: Verify RED** — errors with `uninitialized constant Terret::Store::JSONL`.

- [ ] **Step 3: Implement — append inside `module Store` in store.rb, after Memory. Add `require "json"`, `require "fileutils"`, `require "time"` at the top of store.rb.**

```ruby
    # JSONL provider: one file per session, one JSON envelope per line, made
    # for grepping. at carries microseconds so Time round-trips exactly.
    class JSONL < Hames::Service
      service_key :session_store

      def start(_ctx)
        @dir ||= config.fetch(:dir).tap { |d| FileUtils.mkdir_p(d) }
      end

      def append(event)
        File.open(path(event.session_id), "a") do |f|
          f.puts JSON.generate(
            id: event.id, session_id: event.session_id, seq: event.seq,
            at: event.at.iso8601(6), type: event.type, payload: event.payload
          )
        end
      end

      def read(session_id, from_seq: 0)
        return [] unless File.exist?(path(session_id))

        File.foreach(path(session_id)).filter_map do |line|
          h = JSON.parse(line, symbolize_names: true)
          next if h[:seq] < from_seq

          SessionEvent.new(id: h[:id], session_id: h[:session_id], seq: h[:seq],
                           at: Time.iso8601(h[:at]), type: h[:type], payload: h[:payload])
        end
      end

      def session_ids
        Dir[File.join(@dir, "*.jsonl")].map { |f| File.basename(f, ".jsonl") }
      end

      private

      def path(session_id) = File.join(@dir, "#{session_id}.jsonl")
    end
```

- [ ] **Step 4: Verify GREEN, full suite** — contract + fresh-instance tests pass; `mise exec -- rake test` green.

- [ ] **Step 5: Commit**

```bash
git add gems/terret-core/lib/terret/store.rb gems/terret-core/test/store_jsonl_test.rb
git commit -m "Add the JSONL store provider

One greppable file per session, one JSON envelope per line, with
microsecond timestamps so Time round-trips exactly. Replaces the
inspect-based side-write the seam removed."
```

### Task 6: The SQLite provider gem and the restart acceptance test

**Files:**
- Create: `gems/terret-store-sqlite/terret-store-sqlite.gemspec`
- Create: `gems/terret-store-sqlite/lib/terret/store/sqlite.rb`
- Create: `gems/terret-store-sqlite/test/sqlite_store_test.rb`
- Modify: `Gemfile` (add path row)

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/terret/store/sqlite"
require_relative "../../terret-core/test/store_contract"

class SQLiteStoreTest < Minitest::Test
  include StoreContract

  def build_store
    store = Terret::Store::SQLite.new(path: File.join(Dir.mktmpdir("terret-sqlite"), "t.sqlite3"))
    store.start(nil)
    store
  end
end

# The M3 acceptance: a full tool turn written through SQLite, reopened by a
# FRESH store instance on the same file, resumes with a byte-identical
# derived-context digest and keeps appending after the last seq.
class SQLiteRestartTest < Minitest::Test
  def boot(path)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::SQLite, config: { path: path } },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop",     plugin: Terret::Loop }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new([
      { text: "Checking.", tool_calls: [
        Terret::LLM::ToolCall.new(id: "t1", name: "weather", args: { city: "CDMX" })
      ] },
      { text: "22C.", usage: { prompt_tokens: 9, completion_tokens: 3, cost: 0.0001 } }
    ]))
    ctx.with_owner("t") do
      ctx[:tools].register(name: "weather", description: "w", params: {}) { |city:| "22C in #{city}" }
    end
    ctx
  end

  def test_a_session_survives_a_restart_with_byte_identical_derived_context
    path = File.join(Dir.mktmpdir("terret-sqlite"), "restart.sqlite3")

    ctx1 = boot(path)
    s = ctx1[:sessions].create
    agent = ctx1[:loop].spawn_agent(session_id: s.id)
    assert_equal :completed, ctx1[:loop].run_turn(agent, "Weather in CDMX?")
    before = ctx1[:sessions].derive_messages(s.id).map(&:inspect)

    ctx2 = boot(path) # fresh store instance, fresh Sessions — a real restart
    resumed = ctx2[:sessions].resume(s.id)
    after = ctx2[:sessions].derive_messages(s.id).map(&:inspect)
    assert_equal before, after

    n = resumed.events.length
    assert_equal n, ctx2[:sessions].append(s.id, "user/message", { text: "still here" }).seq
    assert_equal [s.id], ctx2[:sessions].session_ids
  end
end
```

- [ ] **Step 2: Verify RED** — `mise exec -- ruby gems/terret-store-sqlite/test/sqlite_store_test.rb` → LoadError (no lib file yet).

- [ ] **Step 3: Implement lib/terret/store/sqlite.rb**

```ruby
# frozen_string_literal: true

begin
  require "terret"
rescue LoadError
  require_relative "../../../../terret-core/lib/terret" # monorepo path source
end
require "sqlite3"
require "json"
require "time"
require "fileutils"

module Terret
  module Store
    # SQLite provider: the durable default for long-lived processes. WAL for
    # concurrent readers, busy_timeout instead of hand-rolled retries, one
    # row per event keyed (session_id, seq). Appends are synchronous; the
    # per-session writer task from plan §8 is deferred until many-agent
    # load exists.
    class SQLite < Hames::Service
      service_key :session_store

      SCHEMA = <<~SQL
        CREATE TABLE IF NOT EXISTS events (
          session_id TEXT NOT NULL,
          seq        INTEGER NOT NULL,
          id         TEXT NOT NULL,
          at         TEXT NOT NULL,
          type       TEXT NOT NULL,
          payload    TEXT NOT NULL,
          PRIMARY KEY (session_id, seq)
        )
      SQL

      def start(_ctx)
        @db ||= begin
          path = config.fetch(:path)
          FileUtils.mkdir_p(File.dirname(path))
          db = SQLite3::Database.new(path)
          db.busy_timeout = 5_000
          db.execute("PRAGMA journal_mode=WAL")
          db.execute(SCHEMA)
          db
        end
      end

      def stop(_ctx)
        @db&.close
        @db = nil
      end

      def append(event)
        @db.execute(
          "INSERT INTO events (session_id, seq, id, at, type, payload) VALUES (?, ?, ?, ?, ?, ?)",
          [event.session_id, event.seq, event.id, event.at.iso8601(6),
           event.type, JSON.generate(event.payload)]
        )
      end

      def read(session_id, from_seq: 0)
        rows = @db.execute(
          "SELECT id, seq, at, type, payload FROM events WHERE session_id = ? AND seq >= ? ORDER BY seq",
          [session_id, from_seq]
        )
        rows.map do |id, seq, at, type, payload|
          SessionEvent.new(id:, session_id:, seq:, at: Time.iso8601(at), type: type,
                           payload: JSON.parse(payload, symbolize_names: true))
        end
      end

      def session_ids
        @db.execute("SELECT DISTINCT session_id FROM events ORDER BY session_id").flatten
      end
    end
  end
end
```

- [ ] **Step 4: Write the gemspec (mirror the siblings)**

```ruby
Gem::Specification.new do |s|
  s.name = "terret-store-sqlite"
  s.version = "0.1.0"
  s.summary = "SQLite session store for the Terret agent harness"
  s.description = "Durable session persistence for Terret: the append-only " \
                  "session log stored one event per row in SQLite (WAL mode), " \
                  "behind the ctx[:session_store] seam, so sessions survive " \
                  "process restarts with byte-identical derived context."
  s.authors = ["Obie Fernandez"]
  s.email = ["obiefernandez@gmail.com"]
  s.homepage = "https://terret.org"
  s.license = "MIT"
  s.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb"] }
  s.required_ruby_version = ">= 4.0"
  s.add_dependency "terret-core", "~> 0.1"
  s.add_dependency "sqlite3", "~> 2.9"
  s.metadata = {
    "homepage_uri" => "https://terret.org",
    "source_code_uri" => "https://github.com/terret-org/terret",
    "bug_tracker_uri" => "https://github.com/terret-org/terret/issues",
    "rubygems_mfa_required" => "true"
  }
end
```

Add to the Gemfile, after the terret-openrouter line: `gem "terret-store-sqlite", path: "gems/terret-store-sqlite"`. Run `mise exec -- bundle install` (sqlite3 2.9.6 is already installed locally; CI resolves it fresh, precompiled).

- [ ] **Step 5: Verify GREEN, full suite** — `mise exec -- ruby gems/terret-store-sqlite/test/sqlite_store_test.rb` all pass; `mise exec -- rake test` (now six test files) green; `env -u OPENROUTER_API_KEY mise exec -- bundle exec rake test` green (CI simulation).

- [ ] **Step 6: Commit**

```bash
git add gems/terret-store-sqlite Gemfile
git commit -m "Add the SQLite store gem and prove the restart acceptance

One event per row behind the session_store seam, WAL mode, verified
by the M3 acceptance test: a full tool turn written through SQLite,
reopened by a fresh process-equivalent boot, resumes with a
byte-identical derived-context digest and keeps appending."
```

### Task 7: The compaction event

**Files:**
- Modify: `gems/terret-core/lib/terret.rb` (declaration)
- Modify: `gems/terret-core/lib/terret/sessions.rb` (projection)
- Modify: `gems/terret-core/test/sessions_test.rb`
- Regenerate: `docs/events.md`

- [ ] **Step 1: Write the failing tests (append to sessions_test.rb)**

```ruby
  def test_compaction_replaces_prior_history_in_the_projection
    ctx = sessions_ctx
    sessions = ctx[:sessions]
    s = sessions.create
    sessions.append(s.id, "user/message", { text: "old one" })
    sessions.append(s.id, "user/message", { text: "old two" })
    boundary = s.events.last.seq
    sessions.append(s.id, "session/compacted", { upto_seq: boundary, summary: "SUMMARY" })
    sessions.append(s.id, "user/message", { text: "fresh" })

    assert_equal %w[SUMMARY fresh], sessions.derive_messages(s.id).map(&:text)
  end

  def test_the_latest_compaction_wins
    ctx = sessions_ctx
    sessions = ctx[:sessions]
    s = sessions.create
    sessions.append(s.id, "user/message", { text: "ancient" })
    sessions.append(s.id, "session/compacted", { upto_seq: 1, summary: "FIRST" })
    sessions.append(s.id, "user/message", { text: "middle" })
    sessions.append(s.id, "session/compacted", { upto_seq: 3, summary: "SECOND" })
    sessions.append(s.id, "user/message", { text: "fresh" })

    assert_equal %w[SECOND fresh], sessions.derive_messages(s.id).map(&:text)
  end
```

- [ ] **Step 2: Verify RED** — first test raises `Hames::ContractError` (undeclared event `session/compacted`).

- [ ] **Step 3: Implement.** In `Terret.declare_events!`, with the other durable declarations:

```ruby
    e.("session/compacted", :emit, durable: true,
       doc: "history up to upto_seq replaced by summary (still model-visible)")
```

In sessions.rb, `derive_messages` becomes:

```ruby
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
```

and in the private section:

```ruby
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
```

- [ ] **Step 4: Verify GREEN, full suite, regenerate the catalog** — `mise exec -- rake test` green; `mise exec -- rake events:catalog` (docs/events.md gains the new row — this is an intended diff, commit it).

- [ ] **Step 5: Commit**

```bash
git add gems/terret-core/lib/terret.rb gems/terret-core/lib/terret/sessions.rb gems/terret-core/test/sessions_test.rb docs/events.md
git commit -m "Decide the compaction event ahead of the compactor

session/compacted is durable and model-visible: the projection drops
everything at or before its boundary and renders the summary in its
place, latest compaction wins. Declared now so the durable
vocabulary is closed before stored bytes harden; nothing emits it
until the M6 compactor."
```

### Task 8: Web chat session sidebar

**Files:**
- Modify: `examples/web_chat.rb`

The demo gains persistence and a ChatGPT-style left nav. All changes below; the file keeps its existing structure otherwise.

- [ ] **Step 1: Swap the store and requires.** After the terret-openrouter require add `require_relative "../gems/terret-store-sqlite/lib/terret/store/sqlite"`. In the boot layering, replace the Memory row (added in Task 3) with:

```ruby
  { id: "session_store", plugin: Terret::Store::SQLite,
    config: { path: File.expand_path("../tmp/web_chat.sqlite3", __dir__) } },
```

- [ ] **Step 2: AgentHost grows selection and boot-resume.** Replace the `initialize` and `reset!` methods and add `select!`:

```ruby
  def initialize(ctx, hub)
    @ctx = ctx
    @hub = hub
    @busy = false
    latest = most_recent_session_id
    latest ? select!(latest) : reset!
  end

  def reset!
    @session = @ctx[:sessions].create
    @agent = @ctx[:loop].spawn_agent(session_id: @session.id)
    @session
  end

  # Switch the globally active session (every tab follows, same as the
  # new-session button). Refused while a turn runs.
  def select!(session_id)
    return false if @busy

    @session = @ctx[:sessions].resume(session_id)
    @agent = @ctx[:loop].spawn_agent(session_id: @session.id)
    @session
  end
```

and in a private section at the bottom of the class:

```ruby
  private

  def most_recent_session_id
    @ctx[:sessions].session_ids
        .max_by { |id| @ctx[:sessions].read(id).last&.at || Time.at(0) }
  end
```

- [ ] **Step 3: Sidebar helpers — add these top-level methods after `composer_html`:**

```ruby
# The sidebar is cross-session state derived from store queries, deliberately
# separate from the per-session Renderer, which stays replay-pure.
def session_label(events)
  first = events.find { |ev| ev.type == "user/message" }
  first ? first.payload[:text][0, 40] : "untitled"
end

def sidebar_html(sessions, active_id)
  entries = sessions.session_ids
                    .map { |id| [id, sessions.read(id)] }
                    .sort_by { |(_id, events)| events.last&.at || Time.at(0) }
                    .reverse
  items = entries.map do |(id, events)|
    active = id == active_id ? " active" : ""
    <<~HTML
      <form action="/session/select" method="post" data-turbo="false">
        <input type="hidden" name="id" value="#{h(id)}">
        <button class="session#{active}" type="submit">#{h(session_label(events))}</button>
      </form>
    HTML
  end
  <<~HTML
    <form action="/session" method="post" data-turbo="false"><button class="new">+ new session</button></form>
    #{items.join}
  HTML
end

def sidebar_frame(sessions, active_id)
  turbo_tag("update", "sessions", sidebar_html(sessions, active_id))
end

# Rebuild every connected tab after a session switch: clear, replay the
# active session through a fresh Renderer, refresh the sidebar, then send
# the authoritative composer state (covers logs that end mid-turn).
def broadcast_session(hub, sessions, host)
  hub.broadcast(turbo_tag("update", "transcript", ""))
  replay = Renderer.new
  host.session.events.each do |ev|
    html = replay.render(ev)
    hub.broadcast(html) if html
  end
  hub.broadcast(sidebar_frame(sessions, host.session.id))
  hub.broadcast(turbo_tag("replace", "composer", composer_html(disabled: host.busy?)))
end
```

- [ ] **Step 4: SSE replay gains the sidebar and authoritative composer.** `sse_response` takes `(hub, host, sessions)`; after the `events.each` replay loop and before the tail `loop`, add:

```ruby
    body.write(sse_frame(sidebar_frame(sessions, host.session.id)))
    body.write(sse_frame(turbo_tag("replace", "composer", composer_html(disabled: host.busy?))))
```

Update the route call to `sse_response(hub, host, ctx[:sessions])`.

- [ ] **Step 5: Routes.** The `["POST", "/session"]` branch's success arm becomes:

```ruby
        host.reset!
        broadcast_session(hub, ctx[:sessions], host)
        Protocol::HTTP::Response[204, {}, []]
```

Add a new branch after it:

```ruby
    when ["POST", "/session/select"]
      id = begin
        URI.decode_www_form(request.read.to_s).to_h["id"].to_s
      rescue ArgumentError
        ""
      end
      if host.busy?
        Protocol::HTTP::Response[409, {}, ["a turn is already running"]]
      elsif id.empty? || !ctx[:sessions].session_ids.include?(id)
        Protocol::HTTP::Response[404, {}, ["unknown session"]]
      else
        host.select!(id)
        broadcast_session(hub, ctx[:sessions], host)
        Protocol::HTTP::Response[204, {}, []]
      end
```

- [ ] **Step 6: Page layout.** In `page_html`: the `<body>` becomes a sidebar + main split — replace the body markup (keep the script exactly as is) with:

```html
    <body>
      <nav id="sessions"></nav>
      <main>
        <header><span>terret · #{h(model)}</span></header>
        <div id="transcript"></div>
        #{composer_html}
        <script type="module">
          ...existing script unchanged...
        </script>
      </main>
    </body>
```

(the old header new-session form moves into the sidebar). Replace the `body` and `header` CSS rules and add nav/main rules:

```css
        body { font: 15px/1.5 system-ui, sans-serif; margin: 0; display: flex; min-height: 100vh; }
        nav#sessions { width: 240px; flex-shrink: 0; background: #f7f7f8; padding: 1rem .75rem; box-sizing: border-box; overflow-y: auto; }
        nav#sessions form { margin: 0 0 .25rem; }
        nav#sessions button { width: 100%; text-align: left; border: 0; background: transparent; padding: .5rem; border-radius: .375rem; cursor: pointer; font: inherit; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        nav#sessions button:hover { background: #ececf1; }
        nav#sessions button.active { background: #e3e3ea; font-weight: 600; }
        nav#sessions button.new { border: 1px solid #ccc; text-align: center; margin-bottom: 1rem; }
        main { flex: 1; max-width: 640px; margin: 2rem auto; padding: 0 1rem; }
        header { display: flex; justify-content: space-between; align-items: baseline; color: #666; }
```

- [ ] **Step 7: Syntax + boot check (no API spend).** `mise exec -- ruby -c examples/web_chat.rb` → Syntax OK. Start the server in background; verify: GET / → 200 and body contains `<nav id="sessions">`; POST /session → 204; POST /session/select with `id=bogus` → 404; GET /events (2s capture) contains a frame with `target="sessions"`; kill the server; confirm dead. Do NOT post message text. `mise exec -- rake test` still green. Note: `tmp/` is already gitignored — verify with `git status --short` that no sqlite file is staged.

- [ ] **Step 8: Commit**

```bash
git add examples/web_chat.rb
git commit -m "Give the web chat durable sessions and a session sidebar

The demo now boots on the SQLite store, reattaches to the most
recently active session on restart, and grows a ChatGPT-style left
nav: prior sessions labeled by their first message, click to load.
Selection is global — every tab follows, consistent with the demo's
single-shared-session model. SSE replay now ends with a sidebar
frame and the authoritative composer state."
```

### Task 9: Docs and CI simulation

**Files:**
- Modify: `CLAUDE.md`, `docs/terret-implementation-plan.md`

- [ ] **Step 1: CLAUDE.md** — the gem list ("Four gems in one repo") becomes five: add after the terret-openrouter bullet:

```markdown
- `gems/terret-store-sqlite` is the durable session store (M3): the append-only log
  one event per row in SQLite (WAL) behind the `ctx[:session_store]` seam. Memory and
  JSONL providers live in terret-core; the store row is explicit in every boot.
```

Also update the "What is here covers M0–M2" sentence to "covers M0–M3" and mention that session payloads are primitives at the append boundary (typed parts encode through `LLM.encode_part`).

- [ ] **Step 2: Plan §12 M3** — replace the M3 paragraph body's status with SHIPPED and a summary sentence mirroring what landed (primitives contract, store seam with three providers, resume/read, compaction event declared with projection, restart acceptance test green, web chat sidebar as the visible consumer). In §16, remove items 1 and 3 (both done: compaction decided, M3 implemented) and renumber the remaining (protocol.md + socket tests; hames-primer; trademark search). Bump the plan header to "Version 0.5" and "M0–M3 are shipped".

- [ ] **Step 3: Full CI simulation**

```bash
env -u OPENROUTER_API_KEY -u TERRET_LIVE mise exec -- bundle exec rake test
mise exec -- bundle exec rake events:catalog && git diff --exit-code docs/events.md
cd gems/terret-store-sqlite && mise exec -- gem build terret-store-sqlite.gemspec && rm -f terret-store-sqlite-0.1.0.gem && cd ../..
```

All green, catalog clean, gem builds with its lib file.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/terret-implementation-plan.md
git commit -m "Mark M3 shipped in the plan and agent guide

Durable sessions landed: the primitives contract, the session_store
seam with memory, JSONL, and SQLite providers, resume and replay
APIs, and the compaction event decided ahead of M6."
```

### Task 10: Live browser verification

**Files:** none (verification; fix-up commits only if issues surface)

- [ ] **Step 1:** Start the server with the real key (in env). Budget: at most 4 model turns.

- [ ] **Step 2: Verify in a browser (playwright):**

1. Fresh start (delete `tmp/web_chat.sqlite3` first): sidebar shows one "untitled" session. Send "What's the weather in Mexico City right now?" — streaming, tool lines, usage badge as before; the sidebar label updates to the message text on the next sidebar frame (send a second short message "thanks" if needed to observe it, or refresh).
2. **Restart resume (the M3 money check):** kill the server, start it again, reload the page — the full transcript reproduces from SQLite and the sidebar shows the session, active.
3. Click "+ new session", send "And in Tokyo?" — new transcript; sidebar now lists two sessions, newest first, labels correct.
4. Click the older session in the sidebar — transcript switches to the Mexico City conversation in BOTH tabs (open a second tab first).
5. POST /session/select during a running turn → 409 (submit a message, immediately curl `-d "id=<other-id>"` to /session/select).
6. Screenshots: `web_chat_sidebar.png` (two sessions listed), `web_chat_restart.png` (post-restart transcript).

- [ ] **Step 3:** Kill the server, confirm the port is free. Commit fixes only if anything needed fixing (`Fix web chat sidebar issues found in live verification`).
