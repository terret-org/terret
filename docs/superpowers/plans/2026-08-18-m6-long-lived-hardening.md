# M6: Long-Lived Agent Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship M6 from `docs/terret-implementation-plan.md` §12: everything a session that runs for weeks needs and a short run does not — context compaction behind a durable boundary event, durable approvals that park a tool call and resolve over the socket (surviving a process death in between), wake-on-stimulus hardening, session titling, and per-session cost accounting — accepted by an agent that runs across many wakes and a deploy without losing derived context, with a parked approval resolving after a restart.

**Architecture:** Everything lands as plugins on existing seams; no new gem. Three new terret-core services — `ctx[:approvals]` (a `tools/execute`-stage middleware that parks calls on a `Thread::Queue` and reads verdicts from the durable log), `ctx[:compactor]` (summarizes projected history through a `:compactor` model role and appends `session/compacted` with the boundary contract), `ctx[:titler]` (one durable `session/titled` per session, `:titler` role with a truncation fallback) — plus `Loop#resume_turn`, which re-enters an open turn from the log so a parked approval resolves after a real process death. Two kernel/core debts from §14 get paid first because the new machinery stands on them: `Context#emit` isolates listener failures (debt 2), and the Loop's agent registry gets a lifecycle (debt 4: collision refusal, disposal, cap, session index). Debt 3 (UTF-8 at the append boundary) rides along. The socket learns to validate resolutions, deny-on-cancel while parked, and trigger a resume when a verdict lands for an agent with no parked fiber.

**Tech Stack:** Ruby 4.0.6, plain minitest via the Rakefile glob. Zero new dependencies anywhere: the parking primitive is `Thread::Queue#pop`, which is **empirically verified cooperative under the async fiber scheduler on this Ruby** (parks the fiber, not the thread; blocks the thread in plain minitest, where tests resolve from a `Thread`). The restart lane uses the JSONL store (core, stdlib-only) and a real `kill -9`.

---

## Context primer (read before any task)

- Repo: seven gems under `gems/`; this plan adds **no gem** — new services live in terret-core, socket changes in terret-ws. Run everything through `mise exec --` (rbenv lacks 4.0.6). Full gates: `mise exec -- rake test` AND `mise exec -- bundle exec rake test`. `Gemfile.lock` is deliberately gitignored — never commit it.
- House rules: `# frozen_string_literal: true` everywhere, `Data.define` for values (`Struct` only where mutation is the point), strict TDD (failing test first, always report the failure mode), house-style commit subjects (plain evocative sentence, no prefixes, no AI attribution), one implementer commits at a time, `git log -1` HEAD-guard before every commit, NEVER stage `docs/superpowers/plans/*`.
- **Empirical facts (verified against this checkout at `1376959`):**
  - `Thread::Queue#pop` under `Async` parks only the calling fiber; a sibling fiber's `push` resumes it (probe: `[:parking, :resolving, [:unparked, :approved]]`). This is the approvals parking primitive — terret-core stays stdlib-only.
  - `Hames::Context#waterfall` dispatches parent-first: root listeners run before fork listeners, registration order within each context. A pre_execute listener that returns a `Veto` without calling `next_` short-circuits everything after it, **including the `tools/execute` waterfall** — `Registry#execute` returns the veto Result before the execute stage runs. That is why the approvals gate lives on `tools/execute`, not `tools/pre_execute`: the per-agent AllowList (a fork-installed pre_execute listener) must be able to deny a call *before* a human is asked, and pre_execute-at-root would run the approvals gate first.
  - `Sessions#append` is durable-first (`@store.append` → memory push → `ctx.emit("session/event", ev)`), and the emit runs listeners **inline** in the appending fiber. A listener may itself call `Sessions#append` (re-entrant append is safe: the outer event is already in `s.events`, so the nested event gets the next seq and its own emit completes before the outer one returns). Task 2 makes emit isolate listener errors, so a failing consumer can no longer surface into a producer whose append already committed.
  - `Loop#run_turn` (gems/terret-core/lib/terret/loop.rb) flips `agent.status = :running` before any yield point, appends `turn/start`, then loops steps: drain inbox → `agent/pre_step` waterfall on a `Claim` → append `step/start` + claimed messages → `derive_messages` → `agent/request` waterfall → `assert_log_invariant!` → `ctx[:llm].stream` → append `assistant/message` → per tool call append `tool/call`, execute through `ctx[:tools].execute(call, ctx: agent.ctx)`, append `tool/result` → append `step/end` (with `usage:` when the adapter yielded one). `ensure` runs `agent/turn_stopping` (serial), appends `turn/end {status:}`, clears cancel, flips `:idle`.
  - The store contract is three methods (`append(event)`, `read(session_id, from_seq: 0)`, `session_ids`); JSONL (gems/terret-core/lib/terret/store.rb) survives torn lines (crash mid-write loses the line, not the session) — exactly what the kill -9 lane needs.
  - `LLM::Service#stream(ctx, role:, request:)` resolves `role` from `config[:roles]` (`KeyError` when absent) and returns the final assistant `Message` (`#text` joins Text parts). `FakeAdapter` scripts are arrays of `{ text:, tool_calls: [LLM::ToolCall...], usage: {prompt_tokens:, completion_tokens:, cost:} }` consumed strictly in order — **every LLM-calling service in one test shares that one script**, so scripts must account for compactor/titler calls when those roles point at `fake/scripted`.
  - `normalize_payload` (sessions.rb) admits strings/numbers/booleans/nil/arrays/symbol-keyed hashes; symbols in value position become strings; **`approval` metadata like `:always` therefore round-trips as `"always"` in payloads** — compare accordingly.
  - WS: `Connection` (gems/terret-ws/lib/terret/ws/connection.rb) dispatches `approve`/`deny` to `handle_resolution`, today a blind `sessions.append("approval/resolved", {call_id:, verdict:, reason:})`. `Service#attach` resolves the session, then `@ctx[:loop].agent("agent-#{sid}") || spawn_agent(session_id: sid)`. Turn tasks root on the server task via the `runner` lambda; `Sync`-based `Connection#run` owns a writer fiber and a `session/event` tail that **already rescues itself** (keep that — defense in depth under Task 2).
  - Test harnesses: terret-core tests use the `TerretTestHarness#boot(script:, extra_rows:)` module-per-file pattern (Memory store, roles `{main: "fake/scripted"}`); terret-ws `protocol_test.rb` has `boot(script:, extra_rows:, store:)`, `FakeSocket` (io contract: `read`→String|nil, `write`, `close`; helpers `client_send`, `events`, `event_types`, `protocol_frames`), `connect(ctx, agent, root)`, and the bounded `await { }` helper that stops children on timeout. Copy those conventions, never invent parallel ones.
- **Do not relax the log invariant.** Compaction and titling are model-visible only through their durable events; the compactor summarizes via its own `ctx[:llm].stream` call (a utility request derived from the log, not a session request — the loop's invariant assert never sees it).
- Existing tests will feel two deliberate behavior changes: steers log as `context/injected` (Task 5) and `spawn_agent` collisions raise (Task 4). Each task lists the suites to re-run; fix assertions only where the changed behavior is the point, never by weakening an unrelated test.

## File map

| File | Status | Responsibility |
|---|---|---|
| `docs/lifecycle.md` | create | the long-lived-agent primer: status machine, approvals, compaction, titling, cost (written first) |
| `gems/hames/lib/hames/context.rb` | modify | `emit` isolates listener failures (§14 debt 2) |
| `gems/hames/test/hames_test.rb` | modify | emit-isolation tests |
| `gems/terret-core/lib/terret/sessions.rb` | modify | UTF-8 at the boundary (debt 3); `usage` rollup; `title` reader |
| `gems/terret-core/test/sessions_test.rb` | modify | boundary, rollup, title tests |
| `gems/terret-core/lib/terret/loop.rb` | modify | registry lifecycle (debt 4); `context/injected` steers; `resume_turn`/`resumable?`; `:waiting_approval` |
| `gems/terret-core/test/loop_test.rb` | modify | lifecycle, steer, resume tests |
| `gems/terret-core/lib/terret/approvals.rb` | create | `ctx[:approvals]`: execute-stage gate, durable park/resolve, `pending`/`deny_pending!` |
| `gems/terret-core/test/approvals_test.rb` | create | approvals unit tests (threads stand in for the reactor) |
| `gems/terret-core/lib/terret/compactor.rb` | create | `ctx[:compactor]`: `compact!`, budget trigger, boundary contract |
| `gems/terret-core/test/compactor_test.rb` | create | compaction tests incl. invariant-across-compaction |
| `gems/terret-core/lib/terret/titler.rb` | create | `ctx[:titler]`: once-per-session durable title, role + fallback |
| `gems/terret-core/test/titler_test.rb` | create | titling tests |
| `gems/terret-core/lib/terret.rb` | modify | declare `session/titled`; require the three new services |
| `docs/events.md` | modify | regenerated catalog (Task 10) |
| `gems/terret-ws/lib/terret/ws/service.rb` | modify | wake-race requeue; `resumer` lambda; inject `:approvals` |
| `gems/terret-ws/lib/terret/ws/connection.rb` | modify | resolution validation (`stale_call`), cancel-while-parked, resume-on-verdict |
| `gems/terret-ws/test/protocol_test.rb` | modify | socket approval tests, wake-race test, in-process M6 acceptance |
| `gems/terret-ws/test/lifecycle_test.rb` | create | the kill -9 restart lane |
| `gems/terret-ws/test/fixtures/parked_boot.rb` | create | subprocess fixture: boots, parks on approval, prints PARKED |
| `docs/protocol.md` | modify | approval semantics now real; `stale_call`; cancel-while-parked; wake race |
| `examples/lifecycle_demo.rb` | create | park→approve→complete, compaction, title, cost, clean-deploy resume |
| `examples/web_chat.rb` | modify | sidebar label prefers `Sessions#title`; agent disposal on reselect |
| `CLAUDE.md`, `docs/terret-implementation-plan.md` | modify | M6 shipped, §14 debts paid (final task) |

---

### Task 1: The primer — `docs/lifecycle.md` before any code

Primer-first is house style (docs/protocol.md and docs/mcp.md both predate their code). Write the contract, then build to it.

**Files:**
- Create: `docs/lifecycle.md`

- [ ] **Step 1: Write the primer**

Cover, in this order, in the repo's documentation voice (declarative present tense, no marketing):

1. **What "long-lived" means here** — a session measured in weeks: many turns, many wakes, deploys in between. Everything below exists so that derived context survives all three.
2. **The status machine.** `idle → running → waiting_approval → running → idle`. `:waiting_approval` is a sub-state of a turn: the agent is mid-turn with a fiber parked inside the tools pipeline. A parked agent refuses new turns exactly like a running one. (The plan §6.4 machine also names `waiting_input | stopping | done/failed`; those states arrive with M7/M8 work — say so.)
3. **Durable approvals.** A tool definition's `approval:` field (`:never` default, `:policy`, `:always`) is consumed by `ctx[:approvals]`: `:always` always asks, `:policy` asks when the definition is `mutating:` (plan §13's spirit: mutation is what needs a human under policy), `:never` passes through. The gate is `tools/execute`-stage middleware, so a pre_execute veto (the per-agent AllowList) settles a call before anyone is asked. Parking appends durable `approval/requested {call_id, name, args}`; resolution is a durable `approval/resolved {call_id, verdict, reason?}` append (the socket's `approve`/`deny` frames land exactly there); the parked fiber resumes on the in-process fan-out of that append. **Both sides are in the log, so a parked call survives a restart:** on resume, the gate finds the recorded verdict and never parks; with no verdict yet, the open turn is re-entered by `Loop#resume_turn` when the verdict finally lands. Cancel while parked denies every pending approval durably (`deny_pending!`), then cancels the turn. There is no timeout: a parked approval is by design parked until decided; cancel is the escape hatch.
4. **Resuming an open turn.** `Loop#resumable?(session_id)` — the log has a `turn/start` after its last `turn/end`. `resume_turn` appends no second `turn/start`; it completes the open step first (re-executes tool calls owed by the last assistant message that lack a `tool/result`, reading approval verdicts from the log), appends the step's `step/end` (without `usage:` — the original step's usage died with the process), then continues stepping normally and closes with `turn/end`. Honest edges, documented not hidden: an unclosed `step/start` from a crash stays unclosed (step numbering continues past it); a turn that crashed after a final no-tool assistant message resumes with one extra model request (the model sees its own history and wraps up).
5. **Compaction.** `session/compacted {upto_seq, summary}` is durable and model-visible (§2.5). The projection replaces everything at or before `upto_seq` with the summary as a user message; the latest compaction wins. **The boundary contract:** `upto_seq` is always the seq immediately preceding the compaction event itself — the compactor compacts the whole prefix, computing the boundary at append time, so projection-invisible events (a raced-in `approval/resolved`) can land during summarization without breaking the contract. Triggering: `ctx[:compactor]` with `config[:budget]` compacts after any turn whose last `step/end` carried `usage.prompt_tokens >= budget`; `compact!(session_id)` is the manual form. Compaction failure (summarizer error) is non-fatal: the listener is isolated, the turn is already closed, the next turn retries.
6. **Titling.** One durable `session/titled {title}` per session, appended by `ctx[:titler]` at the first `turn/end`. Uses the `:titler` model role when configured; falls back to the first user message truncated to 40 chars. Projection-invisible (metadata, like approval events). `Sessions#title` reads the latest.
7. **Cost accounting.** Usage arrives on `step/end` events (the adapter yields it; OpenRouter includes it automatically in the final SSE chunk). `Sessions#usage(session_id)` sums every `step/end`'s usage over the log — `{prompt_tokens:, completion_tokens:, cost:, steps:}` — so a session's lifetime spend is a pure projection, correct across restarts because the log is.
8. **Agent lifecycle.** One live agent per session; `spawn_agent` refuses id and session collisions (`AgentExists`) and enforces `config[:max_agents]` (default 128, `AgentCapExceeded`) — §14's blast-radius cap. `dispose_agent(id)` disposes the agent's forked context (its listeners and effects die with it) and frees the slot; only idle agents can be disposed. `agent_for_session` is the session→agent index the approvals service uses to flip status.
9. **Wake-on-stimulus.** `inject(text, wake: false)` queues in the inbox until a waking message arrives; `wake: true` on an idle agent starts a turn. Two wakes racing in one read burst: the loser's `TurnAlreadyRunning` requeues its text into the inbox — it rides the winner's next step (or the next turn), never drops.

- [ ] **Step 2: Cross-check against code facts**

Every API named in the primer must match what the tasks below build (`pending`, `deny_pending!`, `resume_turn`, `resumable?`, `compact!`, `usage`, `title`, `dispose_agent`, `agent_for_session`, `max_agents`). Fix the primer, not the plan, if you spot drift.

- [ ] **Step 3: Commit**

```bash
git add docs/lifecycle.md
git commit -m "Write the long-lived agent primer before the code"
```

---

### Task 2: Kernel — `emit` isolates listener failures (§14 debt 2)

`Context#emit` runs listeners inline and unrescued, so any listener error surfaces to the producer *after* a durable append has committed (Sessions appends store-first, then emits). M6 multiplies `session/event` listeners (approvals, compactor, titler, the socket tail); the kernel decision §14 asked for is due: fire-and-forget dispatch isolates each listener. Waterfall/serial/parallel keep raising — their results are load-bearing.

**Files:**
- Modify: `gems/hames/lib/hames/context.rb` (the `emit` method)
- Test: `gems/hames/test/hames_test.rb`

- [ ] **Step 1: Write the failing tests**

Add a test class at the bottom of `gems/hames/test/hames_test.rb`:

```ruby
class HamesEmitIsolationTest < Minitest::Test
  def setup
    Hames.reset_events!
    Hames.event("boom", mode: :emit, durable: false, doc: nil)
    Hames.event("flow", mode: :waterfall, durable: false, doc: nil)
    @ctx = Hames::Context.new
  end
  # (match Hames.event's kwargs to how existing hames tests declare events —
  # if they omit durable:/doc:, omit them here too)

  def test_a_raising_emit_listener_is_isolated_and_later_listeners_still_run
    seen = []
    @ctx.on("boom") { |_| raise "listener bug" }
    @ctx.on("boom") { |x| seen << x }

    warned = capture_warn { @ctx.emit("boom", 1) } # must not raise
    assert_equal [1], seen
    assert_includes warned, "listener bug"
    assert_includes warned, "RuntimeError"
  end

  def test_waterfall_listeners_still_raise_through
    @ctx.on("flow") { |_x, _next_| raise "load-bearing" }
    assert_raises(RuntimeError) { @ctx.waterfall("flow", 1) }
  end

  private

  def capture_warn
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end
end
```

Add `require "stringio"` at the top of the file if it is not already there.

- [ ] **Step 2: Run and verify the failure mode**

Run: `mise exec -- ruby gems/hames/test/hames_test.rb`
Expected: `test_a_raising_emit_listener_is_isolated_...` errors with `RuntimeError: listener bug` escaping `emit` (that is the bug being fixed). The waterfall test passes already.

- [ ] **Step 3: Implement**

In `gems/hames/lib/hames/context.rb`, replace the `emit` method:

```ruby
    # emit: fire-and-forget, registration order, no return value. Listener
    # failures are isolated (warned, not raised): by the time listeners run,
    # the producer's fact is already committed — a durable append emits after
    # the store write — so a consumer bug must not un-happen it. The other
    # modes raise through: their results are load-bearing.
    def emit(name, *args)
      Hames.assert_mode!(name, :emit)
      listeners_for(name).each do |l|
        l.block.call(*args)
      rescue StandardError => e
        warn "hames: emit(#{name}): listener isolated: #{e.class}: #{e.message}"
      end
      nil
    end
```

- [ ] **Step 4: Run the kernel suite, then everything**

Run: `mise exec -- ruby gems/hames/test/hames_test.rb` — all green.
Run: `mise exec -- rake test` — all green (the socket's own listener rescue keeps working; nothing depended on emit raising).

- [ ] **Step 5: Commit**

```bash
git add gems/hames/lib/hames/context.rb gems/hames/test/hames_test.rb
git commit -m "Isolate emit listeners from their producers"
```

> **Execution fallout (recorded during Task 2):** `protocol_test.rb`'s
> `test_an_unexpected_dispatch_error_surfaces_as_internal` injected its failure
> via a raising `session/event` listener — which this task makes a non-error by
> design. Ruling: the test's intent (dispatch-path failures surface as
> `internal`, then close) is still contract; its injection was re-aimed at the
> dispatch path itself (singleton-stub `sessions.read` to raise, drive it with a
> `subscribe` frame — deliberately not the approve path, which Task 11
> rewrites). That one test rides Task 2's commit.

---
### Task 3: Core — refuse invalid UTF-8 at the append boundary (§14 debt 3)

The JSONL and SQLite stores `JSON.generate` payloads that `normalize_payload` admits without an encoding check, so an invalid-UTF-8 string in a tool result fails the append at the *store* (a `JSON::GeneratorError` deep in a provider) instead of at the boundary with a clear class. Tighten `normalize_payload`: every stored string is valid UTF-8, converted when convertible, refused loudly when not.

**Files:**
- Modify: `gems/terret-core/lib/terret/sessions.rb` (`normalize_payload`)
- Test: `gems/terret-core/test/sessions_test.rb`

- [ ] **Step 1: Write the failing tests**

Add to the existing sessions test file (follow its harness conventions — look at how existing tests boot Sessions with the Memory store):

```ruby
  def test_invalid_utf8_raises_non_primitive_payload_at_the_boundary
    ctx, = boot
    s = ctx[:sessions].create
    junk = "ok \xFF\xFE not utf8".dup.force_encoding(Encoding::UTF_8)
    err = assert_raises(Terret::NonPrimitivePayload) do
      ctx[:sessions].append(s.id, "user/message", { text: junk })
    end
    assert_match(/UTF-8/, err.message)
  end

  def test_binary_strings_raise_and_name_their_encoding
    ctx, = boot
    s = ctx[:sessions].create
    blob = [0xDE, 0xAD].pack("C*") # ASCII-8BIT with high bytes
    err = assert_raises(Terret::NonPrimitivePayload) do
      ctx[:sessions].append(s.id, "user/message", { text: blob })
    end
    assert_match(/ASCII-8BIT/, err.message)
  end

  def test_convertible_encodings_convert_and_store_as_utf8
    ctx, = boot
    s = ctx[:sessions].create
    latin = "caf\xE9".dup.force_encoding(Encoding::ISO_8859_1)
    ev = ctx[:sessions].append(s.id, "user/message", { text: latin })
    assert_equal "café", ev.payload[:text]
    assert_equal Encoding::UTF_8, ev.payload[:text].encoding
  end
```

(If the file's boot helper differs in name or signature, use the file's own — do not invent a second harness.)

- [ ] **Step 2: Run and verify the failure mode**

Run: `mise exec -- ruby gems/terret-core/test/sessions_test.rb`
Expected: the first two tests fail — invalid UTF-8 is admitted today (no raise, or a store-level error), and Latin-1 is stored unconverted.

- [ ] **Step 3: Implement**

In `normalize_payload`'s `case`, replace the `when String, Integer, true, false, nil then value` arm with two arms (Integer/booleans/nil keep their arm; String gets its own):

```ruby
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

        utf8
```

(`encode` from UTF-8 to UTF-8 is a no-op that does not validate, hence the explicit `valid_encoding?` check; from any other encoding, invalid bytes raise `InvalidByteSequenceError` and unconvertible characters raise `UndefinedConversionError` — both `EncodingError`.)

- [ ] **Step 4: Run the core suite, then everything**

Run: `mise exec -- ruby gems/terret-core/test/sessions_test.rb` — green.
Run: `mise exec -- rake test` — green (nothing in the suites stores non-UTF-8 today; if an MCP translate test does, its fixture is the thing to fix — translated tool content must be scrubbed at the translate layer, which is exactly the boundary this debt wanted enforced).

- [ ] **Step 5: Commit**

```bash
git add gems/terret-core/lib/terret/sessions.rb gems/terret-core/test/sessions_test.rb
git commit -m "Refuse invalid UTF-8 at the append boundary"
```

> **Execution fallout (recorded during Task 3):** `protocol_test.rb`'s
> `test_a_poison_payload_drops_the_connection_not_the_append` pinned the
> pre-boundary world — invalid UTF-8 appends durably, the socket's JSON
> serializer fails, the connection drops `internal`. The new boundary makes
> that vector impossible (append refuses first), and the old test didn't fail
> but HUNG (an exception inside its `Sync` block never surfaced — also the
> cause of the "infra-killed" full-suite runs). Ruling: replaced by
> `test_a_poison_payload_is_refused_at_the_boundary_and_the_socket_survives`
> (append raises `NonPrimitivePayload`, log untouched, connection lives). The
> socket-failure-domain contract stays pinned by the tail-listener-rescue test
> (~line 634). That one test rides Task 3's commit.

---

### Task 4: Core — the agent registry gets a lifecycle (§14 debt 4)

`Loop#spawn_agent` is an unconditional hash assignment: no cap, no removal, no disposal of a replaced agent's forked context, silent id replacement. Long-lived processes cannot afford any of those. Also added here: `agent_for_session`, the index the approvals service (Task 7) needs to flip agent status from a listener that only knows a session id, and the `:waiting_approval` status value on `Agent`.

**Files:**
- Modify: `gems/terret-core/lib/terret/loop.rb`
- Test: `gems/terret-core/test/loop_test.rb`
- Verify: `examples/web_chat.rb` (its AgentHost respawns agents — see Step 6)

- [ ] **Step 1: Write the failing tests**

Add a test class at the bottom of `gems/terret-core/test/loop_test.rb`:

```ruby
class AgentLifecycleTest < Minitest::Test
  include TerretTestHarness

  def test_spawning_a_taken_id_raises_instead_of_silently_replacing
    ctx, = boot(script: [])
    s = ctx[:sessions].create
    ctx[:loop].spawn_agent(session_id: s.id)
    assert_raises(Terret::AgentExists) { ctx[:loop].spawn_agent(session_id: s.id) }
  end

  def test_one_live_agent_per_session
    ctx, = boot(script: [])
    s = ctx[:sessions].create
    ctx[:loop].spawn_agent(session_id: s.id, id: "a1")
    assert_raises(Terret::AgentExists) { ctx[:loop].spawn_agent(session_id: s.id, id: "a2") }
  end

  def test_agent_for_session_finds_the_live_agent
    ctx, = boot(script: [])
    s = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: s.id)
    assert_same agent, ctx[:loop].agent_for_session(s.id)
    assert_nil ctx[:loop].agent_for_session("nope")
  end

  def test_dispose_agent_disposes_the_fork_and_frees_both_slots
    ctx, = boot(script: [])
    s = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: s.id)
    fired = []
    agent.ctx.on("session/event") { |ev| fired << ev.type }

    ctx[:loop].dispose_agent(agent.id)
    ctx[:sessions].append(s.id, "user/message", { text: "after" })

    assert_empty fired, "a disposed agent's fork must not keep listening"
    assert_nil ctx[:loop].agent(agent.id)
    assert_nil ctx[:loop].agent_for_session(s.id)
    # the slot is genuinely free: respawning works
    ctx[:loop].spawn_agent(session_id: s.id)
  end

  def test_dispose_refuses_a_busy_agent
    ctx, = boot(script: [])
    s = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: s.id)
    agent.status = :running
    assert_raises(Terret::TurnAlreadyRunning) { ctx[:loop].dispose_agent(agent.id) }
    agent.status = :waiting_approval
    assert_raises(Terret::TurnAlreadyRunning) { ctx[:loop].dispose_agent(agent.id) }
  end

  def test_the_agent_cap_holds
    ctx2, = boot_with_cap(2)
    a = ctx2[:sessions].create
    b = ctx2[:sessions].create
    c = ctx2[:sessions].create
    ctx2[:loop].spawn_agent(session_id: a.id)
    ctx2[:loop].spawn_agent(session_id: b.id)
    err = assert_raises(Terret::AgentCapExceeded) { ctx2[:loop].spawn_agent(session_id: c.id) }
    assert_match(/max_agents/, err.message)
  end

  private

  def boot_with_cap(n)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop",     plugin: Terret::Loop, config: { max_agents: n } }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new([]))
    [ctx, loader]
  end
end
```

- [ ] **Step 2: Run and verify the failure mode**

Run: `mise exec -- ruby gems/terret-core/test/loop_test.rb`
Expected: `NameError` for `Terret::AgentExists` / `AgentCapExceeded`, `NoMethodError` for `agent_for_session` / `dispose_agent`, and the collision test failing because replacement is silent today.

- [ ] **Step 3: Implement**

In `gems/terret-core/lib/terret/loop.rb`, next to `TurnAlreadyRunning`:

```ruby
  # Raised on id or session collision in spawn_agent: silent replacement
  # leaked the old agent's forked context and orphaned its mid-turn state
  # (plan §14). Dispose the old agent first, explicitly.
  class AgentExists < StandardError; end

  # The hard cap on agents per process (plan §14, blast-radius): shard by
  # process rather than raising the cap when this bites.
  class AgentCapExceeded < StandardError; end
```

Replace `start`, `spawn_agent`, and `agent` in `Loop`:

```ruby
    def start(ctx)
      @ctx = ctx
      @agents = {}
      @by_session = {}
      @max_agents = config[:max_agents] || 128
    end

    def spawn_agent(session_id:, id: "agent-#{session_id}")
      raise AgentExists, "agent #{id} already exists" if @agents.key?(id)
      if (live = @by_session[session_id])
        raise AgentExists, "session #{session_id} already has agent #{live.id}"
      end
      if @agents.size >= @max_agents
        raise AgentCapExceeded,
              "#{@agents.size} agents live; max_agents is #{@max_agents}"
      end

      agent = Agent.new(id:, session_id:, ctx: @ctx.fork)
      @agents[id] = agent
      @by_session[session_id] = agent
      agent
    end

    # Live-agent lookup for interfaces (§9.2); nil when never spawned.
    def agent(id) = @agents[id]

    # Session -> live agent, for services that learn a session id from an
    # event and need the agent (approvals flips status through this).
    def agent_for_session(session_id) = @by_session[session_id]

    # Tear an idle agent down: its forked context disposes (listeners and
    # effects die with it) and both registry slots free. Mid-turn agents
    # refuse — cancel or resolve first.
    def dispose_agent(id)
      agent = @agents.fetch(id)
      unless agent.status == :idle
        raise TurnAlreadyRunning, "agent #{id} is #{agent.status}; dispose only idle agents"
      end

      agent.ctx.dispose!
      @agents.delete(id)
      @by_session.delete(agent.session_id)
      agent
    end
```

No `Agent` code change is needed for `:waiting_approval` (`status` is `attr_accessor`), but extend the comment on `@status = :idle` in `Agent#initialize`:

```ruby
      @status = :idle # :idle | :running | :waiting_approval (parked in the tools pipeline)
```

- [ ] **Step 4: Run the core suite, then everything**

Run: `mise exec -- ruby gems/terret-core/test/loop_test.rb` — green.
Run: `mise exec -- rake test` — expected fallout is limited to anything spawning twice for one session; the WS service already guards with `agent(...) || spawn_agent`. Fix only genuine double-spawns.

- [ ] **Step 5: Verify the WS resume path still works**

Run: `mise exec -- bundle exec ruby gems/terret-ws/test/protocol_test.rb` — green. (`Service#attach` resolves `agent("agent-#{sid}") || spawn_agent(...)`; with one agent per session that guard is now load-bearing, not just polite.)

- [ ] **Step 6: Check web_chat's respawn path**

Read `examples/web_chat.rb`'s AgentHost. If selecting a session spawns a fresh agent while an old one is still registered (same or different session), it now raises `AgentExists`. Fix by disposing first:

```ruby
# in AgentHost#select! (or wherever the old agent is dropped):
old = @ctx[:loop].agent_for_session(id) || (@agent if defined?(@agent) && @agent)
@ctx[:loop].dispose_agent(old.id) if old && old.status == :idle
```

Adapt to the file's actual shape — the principle is: never abandon a registered agent; dispose it. Then smoke it:

Run: `mise exec -- bundle exec ruby examples/web_chat.rb` (briefly; Ctrl-C after it binds) — boots clean.

- [ ] **Step 7: Commit**

```bash
git add gems/terret-core/lib/terret/loop.rb gems/terret-core/test/loop_test.rb examples/web_chat.rb
git commit -m "Give the agent registry a lifecycle"
```

---

### Task 5: Core — steers log as `context/injected`

`context/injected` has been declared and projected since M2 ("agent.inject landed in a request") but nothing emits it: the loop logs drained-inbox steers as `user/message`. Long-lived sessions live on injected stimuli, so the distinction earns its keep now. The `Claim` payload becomes typed entries so provenance survives the `agent/pre_step` waterfall.

**Files:**
- Modify: `gems/terret-core/lib/terret/loop.rb` (`Claim`, `run_turn`)
- Test: `gems/terret-core/test/loop_test.rb`
- Verify: `gems/terret-ws/test/protocol_test.rb`, `examples/web_chat.rb` (renderer)

- [ ] **Step 1: Grep for Claim consumers first**

Run: `grep -rn "Claim\|pre_step" gems/ examples/ --include="*.rb" | grep -v test`
Expected consumers: the loop itself. Any `agent/pre_step` listener in tests rewrites or rejects claims — note their shapes; they change in Step 3's sweep.

- [ ] **Step 2: Write the failing test**

In `gems/terret-core/test/loop_test.rb` (inside the existing steer-focused test class if one exists, else `TurnFlowTest`):

```ruby
  def test_steers_log_as_context_injected_and_input_as_user_message
    ctx, = boot(script: [{ text: "ok" }])
    agent, session = spawn(ctx)
    agent.inject("remember the tone")

    ctx[:loop].run_turn(agent, "hello")

    typed = session.events.filter_map do |e|
      [e.type, e.payload[:text]] if %w[user/message context/injected].include?(e.type)
    end
    assert_equal [["user/message", "hello"], ["context/injected", "remember the tone"]], typed
  end
```

Run: `mise exec -- ruby gems/terret-core/test/loop_test.rb`
Expected: FAIL — both currently log as `user/message`.

- [ ] **Step 3: Implement**

In `gems/terret-core/lib/terret/loop.rb`, change the `Claim` docstring and the loop body. `Claim.messages` becomes an array of `[type, text]` pairs:

```ruby
  # Claimed messages are [type, text] pairs — "user/message" for the turn's
  # input, "context/injected" for steers drained from the inbox — so the log
  # records provenance even after a pre_step listener rewrites the claim.
  Claim = Data.define(:messages, :rejected, :reason) do
    def self.of(messages) = new(messages:, rejected: false, reason: nil)
    def self.reject(reason:) = new(messages: [], rejected: true, reason:)
  end
```

In `run_turn`, `pending` now holds pairs from the start:

```ruby
      pending = input.nil? ? [] : [["user/message", input]]
```

and the drain/claim/log section becomes:

```ruby
          # anything injected since the last step rides along with this one
          steered = agent.drain_inbox
          pending.concat(steered.map { |t| ["context/injected", t] })

          claim = ctx.waterfall("agent/pre_step", Claim.of(pending)) { |c| c }
          if claim.rejected || (steps.zero? && claim.messages.empty? && pending.empty?)
            agent.requeue(steered) if claim.rejected
            status = claim.rejected ? :rejected : :empty
            break
          end
          ...
          claim.messages.each { |(type, text)| sessions.append(sid, type, { text: text }) }
```

(`requeue` still takes raw texts — `steered` is untouched. Everything else in the method is unchanged in this task.)

- [ ] **Step 4: Sweep the suites**

Run: `mise exec -- rake test`
Expected fallout, fix each *as the point of the change, not by weakening*:
- loop tests asserting `user/message` for steered texts → now `context/injected` (the projection is identical: both render as user-role messages, so derived-history and invariant tests hold untouched).
- any `agent/pre_step` test listener that builds `Claim.of(["text"])` → `Claim.of([["user/message", "text"]])`.
- terret-ws protocol tests asserting an `inject` frame's durable trace as `user/message` → `context/injected` **only for non-wake injects that ride a later step**; a wake inject's text is the turn *input* and stays `user/message`.

- [ ] **Step 5: Check the web_chat renderer**

Run: `grep -n "user/message" examples/web_chat.rb`
Wherever the renderer cases on `"user/message"`, make it also render `"context/injected"` (same bubble is fine; a `(injected)` prefix is better). Smoke-boot the demo as in Task 4.

- [ ] **Step 6: Commit**

```bash
git add gems/terret-core/lib/terret/loop.rb gems/terret-core/test/loop_test.rb gems/terret-ws/test/protocol_test.rb examples/web_chat.rb
git commit -m "Log steers as context/injected"
```

---

### Task 6: Core — `Sessions#usage`, the lifetime-spend projection

Usage lands on `step/end` events and nothing sums it. The rollup is a pure projection over the log — correct across restarts because the log is.

**Files:**
- Modify: `gems/terret-core/lib/terret/sessions.rb`
- Test: `gems/terret-core/test/sessions_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
  def test_usage_sums_every_step_end_over_the_log
    ctx, = boot
    s = ctx[:sessions].create
    ctx[:sessions].append(s.id, "step/end", { n: 1, usage: { prompt_tokens: 10, completion_tokens: 5, cost: 0.01 } })
    ctx[:sessions].append(s.id, "step/end", { n: 2 }) # provider sent no usage
    ctx[:sessions].append(s.id, "step/end", { n: 3, usage: { prompt_tokens: 40, completion_tokens: 2, cost: 0.005 } })

    assert_equal({ prompt_tokens: 50, completion_tokens: 7, cost: 0.015, steps: 3 },
                 ctx[:sessions].usage(s.id))
  end

  def test_usage_of_a_fresh_session_is_zero
    ctx, = boot
    s = ctx[:sessions].create
    assert_equal({ prompt_tokens: 0, completion_tokens: 0, cost: 0.0, steps: 0 },
                 ctx[:sessions].usage(s.id))
  end
```

Run: `mise exec -- ruby gems/terret-core/test/sessions_test.rb`
Expected: `NoMethodError: usage`.

- [ ] **Step 2: Implement**

In `Sessions`, after `derive_messages`:

```ruby
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
```

- [ ] **Step 3: Run, then commit**

Run: `mise exec -- ruby gems/terret-core/test/sessions_test.rb` then `mise exec -- rake test` — green.

```bash
git add gems/terret-core/lib/terret/sessions.rb gems/terret-core/test/sessions_test.rb
git commit -m "Sum a session's spend from its log"
```

---
### Task 7: Core — `ctx[:approvals]`, durable parking on the execute stage

The heart of M6. A `tools/execute`-stage middleware (root context) that consumes the `approval:` metadata M5 left inert: `:always` always asks, `:policy` asks when the definition is `mutating:`, `:never` passes through. Parking appends durable `approval/requested`, blocks the calling fiber on a `Thread::Queue`, and resumes when a matching `approval/resolved` lands (the service's own `session/event` listener pushes the verdict). A verdict already in the log settles the call without parking — that single property is what makes approvals survive restarts.

**Why the execute stage, not pre_execute:** the per-agent AllowList is a pre_execute listener on the agent's fork; root pre_execute listeners run *before* fork ones, so an approvals gate there would ask a human about a call the allow list was about to veto. On the execute stage, every pre_execute veto has already settled the call before the gate can park it. Denial therefore renders as an error `Result` (the execute stage produces Results), same model-visible shape as a veto.

**Files:**
- Create: `gems/terret-core/lib/terret/approvals.rb`
- Modify: `gems/terret-core/lib/terret.rb` (require)
- Test: `gems/terret-core/test/approvals_test.rb`

- [ ] **Step 1: Write the failing tests**

Create `gems/terret-core/test/approvals_test.rb`. Plain minitest has no reactor, so parking tests run the turn in a background `Thread` and resolve from the test thread (`Thread::Queue` is thread-safe; under async it is fiber-cooperative — Task 12/13 prove that side):

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret"

module ApprovalsHarness
  def boot(script:, extra_rows: [])
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
      { id: "approvals", plugin: Terret::Tools::Approvals },
      *extra_rows
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))
    [ctx, loader]
  end

  def spawn(ctx)
    session = ctx[:sessions].create
    [ctx[:loop].spawn_agent(session_id: session.id), session]
  end

  DEPLOY_CALL = Terret::LLM::ToolCall.new(id: "tc1", name: "deploy", args: { env: "prod" })

  def register_deploy(ctx, approval:, mutating: true)
    ctx.with_owner("deploy-plugin") do
      ctx[:tools].register(name: "deploy", description: "Ship it",
                           params: { env: "string" }, mutating: mutating,
                           approval: approval) { |env:| "deployed to #{env}" }
    end
  end

  def park_script = [{ text: "Deploying.", tool_calls: [DEPLOY_CALL] }, { text: "Done." }]

  # Run a turn in a background thread; wait until the agent parks.
  def park_turn(ctx, agent)
    t = Thread.new { ctx[:loop].run_turn(agent, "ship it") }
    deadline = Time.now + 5
    until agent.status == :waiting_approval
      raise "never parked (status=#{agent.status})" if Time.now > deadline
      sleep 0.005
    end
    t
  end
end

class ApprovalsGateTest < Minitest::Test
  include ApprovalsHarness

  def test_never_and_unmutating_policy_pass_through_without_asking
    [[:never, true], [:policy, false]].each do |approval, mutating|
      ctx, = boot(script: park_script)
      register_deploy(ctx, approval: approval, mutating: mutating)
      agent, session = spawn(ctx)
      assert_equal :completed, ctx[:loop].run_turn(agent, "ship it")
      refute session.events.map(&:type).include?("approval/requested")
      assert_equal "deployed to prod",
                   session.events.find { |e| e.type == "tool/result" }.payload[:content]
    end
  end

  def test_always_parks_and_an_approval_unparks_and_executes
    ctx, = boot(script: park_script)
    register_deploy(ctx, approval: :always)
    agent, session = spawn(ctx)
    turn = park_turn(ctx, agent)

    requested = session.events.find { |e| e.type == "approval/requested" }
    assert_equal({ call_id: "tc1", name: "deploy", args: { env: "prod" } }, requested.payload)
    assert ctx[:approvals].pending?(session.id, "tc1")

    ctx[:sessions].append(session.id, "approval/resolved", { call_id: "tc1", verdict: "approved" })
    assert_equal :completed, turn.value
    assert_equal "deployed to prod",
                 session.events.find { |e| e.type == "tool/result" }.payload[:content]
    assert_equal :idle, agent.status
    refute ctx[:approvals].pending?(session.id, "tc1")
  end

  def test_a_denial_renders_as_an_error_result_and_the_turn_continues
    ctx, = boot(script: park_script)
    register_deploy(ctx, approval: :always)
    agent, session = spawn(ctx)
    turn = park_turn(ctx, agent)

    ctx[:sessions].append(session.id, "approval/resolved",
                          { call_id: "tc1", verdict: "denied", reason: "not on a Friday" })
    assert_equal :completed, turn.value
    result = session.events.find { |e| e.type == "tool/result" }
    assert_nil result.payload[:content]
    assert_match(/denied.*not on a Friday/, result.payload[:error])
  end

  def test_a_verdict_already_in_the_log_settles_without_parking
    # The restart property, minus the restart: the resolved event precedes
    # execution, so the gate must consume it and never park.
    ctx, = boot(script: park_script)
    register_deploy(ctx, approval: :always)
    agent, session = spawn(ctx)
    ctx[:sessions].append(session.id, "approval/resolved", { call_id: "tc1", verdict: "approved" })

    assert_equal :completed, ctx[:loop].run_turn(agent, "ship it")
    assert_equal "deployed to prod",
                 session.events.find { |e| e.type == "tool/result" }.payload[:content]
    # exactly one requested/resolved pair would be wrong: nothing new was requested
    refute session.events.map(&:type).include?("approval/requested")
  end

  def test_a_prior_veto_settles_the_call_before_anyone_is_asked
    ctx, = boot(script: park_script)
    register_deploy(ctx, approval: :always)
    agent, session = spawn(ctx)
    Terret::Tools::AllowList.install(agent.ctx, ["weather"]) # deploy not listed

    assert_equal :completed, ctx[:loop].run_turn(agent, "ship it")
    refute session.events.map(&:type).include?("approval/requested"),
           "a vetoed call must never ask for approval"
    assert_match(/allow list/, session.events.find { |e| e.type == "tool/result" }.payload[:error])
  end

  def test_deny_pending_denies_durably_and_unparks
    ctx, = boot(script: park_script)
    register_deploy(ctx, approval: :always)
    agent, session = spawn(ctx)
    turn = park_turn(ctx, agent)

    ctx[:approvals].deny_pending!(session.id, reason: "cancelled")
    assert_equal :completed, turn.value
    resolved = session.events.find { |e| e.type == "approval/resolved" }
    assert_equal "denied", resolved.payload[:verdict]
    assert_empty ctx[:approvals].pending(session.id)
  end

  def test_pending_lists_requested_without_resolved
    ctx, = boot(script: [])
    _, session = spawn(ctx)
    ctx[:sessions].append(session.id, "approval/requested", { call_id: "a", name: "x", args: {} })
    ctx[:sessions].append(session.id, "approval/requested", { call_id: "b", name: "y", args: {} })
    ctx[:sessions].append(session.id, "approval/resolved",  { call_id: "a", verdict: "approved" })
    assert_equal ["b"], ctx[:approvals].pending(session.id)
  end

  def test_a_vanished_tool_still_renders_a_recoverable_error
    ctx, = boot(script: [{ text: "Trying.", tool_calls: [DEPLOY_CALL] }, { text: "Oh well." }])
    agent, session = spawn(ctx) # deploy never registered
    assert_equal :completed, ctx[:loop].run_turn(agent, "ship it")
    assert_match(/KeyError/, session.events.find { |e| e.type == "tool/result" }.payload[:error])
  end
end
```

- [ ] **Step 2: Run and verify the failure mode**

Run: `mise exec -- ruby gems/terret-core/test/approvals_test.rb`
Expected: `NameError: uninitialized constant Terret::Tools::Approvals`.

- [ ] **Step 3: Implement**

Create `gems/terret-core/lib/terret/approvals.rb`:

```ruby
# frozen_string_literal: true

module Terret
  module Tools
    # ctx[:approvals] — durable human-in-the-loop gating (plan §6.3, §12 M6).
    # An execute-stage middleware parks calls whose definition demands a
    # decision, appends durable approval/requested, and resumes when a
    # matching approval/resolved lands in the log (the socket's approve/deny
    # frames append exactly that). Both sides are durable, so a parked call
    # survives a process death: on resume the gate finds the recorded verdict
    # and never parks. It gates on tools/execute rather than tools/pre_execute
    # so pre_execute vetoes (the per-agent AllowList) settle a call before a
    # human is ever asked.
    class Approvals < Hames::Service
      service_key :approvals
      inject :sessions, :tools, :loop

      def start(ctx)
        @ctx = ctx
        @waiting = {} # [session_id, call_id] => Thread::Queue awaiting one verdict payload

        ctx.on("tools/execute") do |call, next_|
          gate(call, next_)
        end
        ctx.on("session/event") do |ev|
          next unless ev.type == "approval/resolved"

          @waiting.delete([ev.session_id, ev.payload[:call_id]])&.push(ev.payload)
        end
      end

      # Log-derived: requested without a matching resolved. The in-memory
      # waiter map is never consulted — after a restart it is empty while the
      # log still knows what is owed.
      def pending(session_id)
        events = @ctx[:sessions].fetch(session_id).events
        resolved = events.filter_map { |e| e.payload[:call_id] if e.type == "approval/resolved" }
        events.filter_map do |e|
          next unless e.type == "approval/requested"
          next if resolved.include?(e.payload[:call_id])

          e.payload[:call_id]
        end
      end

      def pending?(session_id, call_id) = pending(session_id).include?(call_id)

      # Cancel's escape hatch: deny everything parked for a session, durably.
      # Each denial is an ordinary approval/resolved append, so an in-process
      # parked fiber unparks through the same listener as a socket verdict,
      # and a restart-orphaned request settles for good.
      def deny_pending!(session_id, reason: "cancelled")
        pending(session_id).each do |call_id|
          @ctx[:sessions].append(session_id, "approval/resolved",
                                 { call_id: call_id, verdict: "denied", reason: reason })
        end
      end

      private

      def gate(call, next_)
        d = begin
          @ctx[:tools].fetch(call.name)
        rescue KeyError
          nil # vanished tool: fall through — the base renders its recoverable error
        end
        return next_.(call) unless d && requires_approval?(d)

        verdict = recorded_verdict(call) || park(call)
        if verdict[:verdict] == "approved"
          next_.(call)
        else
          reason = verdict[:reason] || "no reason given"
          Result.new(id: call.id, content: nil, error: "#{call.name} denied: #{reason}")
        end
      end

      # :always asks every time; :policy asks when the tool mutates (plan
      # §13's spirit: mutation is what needs a human under policy); :never
      # (the default) passes through.
      def requires_approval?(d)
        d.approval == :always || (d.approval == :policy && d.mutating)
      end

      # A verdict already in the log (replay after a restart, or a decision
      # that raced ahead of execution) settles the call without parking.
      def recorded_verdict(call)
        @ctx[:sessions].fetch(call.session_id).events.find do |e|
          e.type == "approval/resolved" && e.payload[:call_id] == call.id
        end&.payload
      end

      def park(call)
        q = Thread::Queue.new
        key = [call.session_id, call.id]
        # waiter first, then the durable request: a verdict can never land in
        # the gap between the append's fan-out and the waiter existing
        @waiting[key] = q
        agent = @ctx[:loop].agent_for_session(call.session_id)
        @ctx[:sessions].append(call.session_id, "approval/requested",
                               { call_id: call.id, name: call.name, args: call.args })
        agent&.status = :waiting_approval
        # cooperative under the fiber scheduler (parks the fiber); blocks the
        # thread under plain minitest, where tests resolve from another thread
        q.pop
      ensure
        agent.status = :running if agent && agent.status == :waiting_approval
        @waiting.delete(key)
      end
    end
  end
end
```

In `gems/terret-core/lib/terret.rb`, add after the `terret/tools` require:

```ruby
require_relative "terret/approvals"
```

- [ ] **Step 4: Run the approvals suite, then everything**

Run: `mise exec -- ruby gems/terret-core/test/approvals_test.rb` — green.
Run: `mise exec -- rake test` — green (no default boot mounts the row; nothing else changes).

- [ ] **Step 5: Commit**

```bash
git add gems/terret-core/lib/terret/approvals.rb gems/terret-core/lib/terret.rb gems/terret-core/test/approvals_test.rb
git commit -m "Park tool calls on durable approvals"
```

---

### Task 8: Core — `Loop#resume_turn`, re-entering an open turn from the log

A process death while parked leaves the log mid-turn: `turn/start` … `tool/call` … `approval/requested`, no `tool/result`, no `turn/end`. When the verdict finally arrives there is no fiber to unpark — the turn must be re-entered from the log. `run_turn` refactors into a shared `turning` wrapper (status guard + rescue + the `turn/end` ensure) and a `step_loop`; `resume_turn` completes the open step first (executing tool calls owed by the last assistant message, whose approval verdicts the Task 7 gate reads from the log), then continues stepping normally.

**Files:**
- Modify: `gems/terret-core/lib/terret/loop.rb`
- Test: `gems/terret-core/test/loop_test.rb`

- [ ] **Step 1: Write the failing tests**

Add a test class to `gems/terret-core/test/loop_test.rb`. The dangling logs are crafted by hand — byte-honest replicas of what a killed process leaves, and the only way to get one without an actual kill (that lane is Task 12):

```ruby
class ResumeTurnTest < Minitest::Test
  include TerretTestHarness

  DEPLOY_CALL = Terret::LLM::ToolCall.new(id: "tc9", name: "deploy", args: { env: "prod" })

  def register_deploy(ctx, approval: :always)
    ctx.with_owner("deploy-plugin") do
      ctx[:tools].register(name: "deploy", description: "Ship it",
                           params: { env: "string" }, mutating: true,
                           approval: approval) { |env:| "deployed to #{env}" }
    end
  end

  # What a kill -9 leaves behind: an open turn, an assistant message owing a
  # tool result, the call and the approval request logged, no resolution.
  def craft_dangling_log(ctx, session)
    sid = session.id
    sessions = ctx[:sessions]
    sessions.append(sid, "turn/start", { agent: "agent-#{sid}" })
    sessions.append(sid, "step/start", { n: 1 })
    sessions.append(sid, "user/message", { text: "ship it" })
    sessions.append(sid, "assistant/message",
                    { parts: [Terret::LLM.encode_part(Terret::LLM::Text.new(text: "Deploying.")),
                              Terret::LLM.encode_part(DEPLOY_CALL)] })
    sessions.append(sid, "tool/call", { id: "tc9", name: "deploy", args: { env: "prod" } })
    sessions.append(sid, "approval/requested", { call_id: "tc9", name: "deploy", args: { env: "prod" } })
  end

  def boot_with_approvals(script)
    boot(script: script, extra_rows: [{ id: "approvals", plugin: Terret::Tools::Approvals }])
  end

  def test_resumable_reads_the_open_turn_from_the_log
    ctx, = boot_with_approvals([])
    session = ctx[:sessions].create
    refute ctx[:loop].resumable?(session.id)
    craft_dangling_log(ctx, session)
    assert ctx[:loop].resumable?(session.id)
  end

  def test_resume_with_a_recorded_approval_completes_the_turn
    # the model owes one more step after the tool result: script has one entry
    ctx, = boot_with_approvals([{ text: "Deployed." }])
    register_deploy(ctx)
    session = ctx[:sessions].create
    craft_dangling_log(ctx, session)
    ctx[:sessions].append(session.id, "approval/resolved", { call_id: "tc9", verdict: "approved" })
    agent = ctx[:loop].spawn_agent(session_id: session.id)

    assert_equal :completed, ctx[:loop].resume_turn(agent)

    types = session.events.map(&:type)
    assert_equal 1, types.count("turn/start"), "resume must not open a second turn"
    assert_equal 1, types.count("turn/end")
    result = session.events.find { |e| e.type == "tool/result" }
    assert_equal "deployed to prod", result.payload[:content]
    # the crashed step closes without usage (it died with the process)
    step_end = session.events.find { |e| e.type == "step/end" }
    assert_equal({ n: 1 }, step_end.payload)
    # and the turn continued: the scripted "Deployed." landed as step 2
    assert_equal "Deployed.",
                 Terret::LLM.decode_part(session.events.select { |e| e.type == "assistant/message" }
                                                       .last.payload[:parts].first).text
  end

  def test_resume_with_no_verdict_parks_again
    ctx, = boot_with_approvals([{ text: "Deployed." }])
    register_deploy(ctx)
    session = ctx[:sessions].create
    craft_dangling_log(ctx, session)
    agent = ctx[:loop].spawn_agent(session_id: session.id)

    t = Thread.new { ctx[:loop].resume_turn(agent) }
    deadline = Time.now + 5
    until agent.status == :waiting_approval
      raise "never re-parked" if Time.now > deadline
      sleep 0.005
    end
    # no SECOND approval/requested: the pending one still stands
    assert_equal 1, session.events.count { |e| e.type == "approval/requested" }

    ctx[:sessions].append(session.id, "approval/resolved", { call_id: "tc9", verdict: "approved" })
    assert_equal :completed, t.value
  end

  def test_resume_after_a_crash_before_the_model_replied_re_requests
    ctx, = boot_with_approvals([{ text: "Here you go." }])
    session = ctx[:sessions].create
    sid = session.id
    ctx[:sessions].append(sid, "turn/start", { agent: "agent-#{sid}" })
    ctx[:sessions].append(sid, "step/start", { n: 1 })
    ctx[:sessions].append(sid, "user/message", { text: "hello?" })
    agent = ctx[:loop].spawn_agent(session_id: sid)

    assert_equal :completed, ctx[:loop].resume_turn(agent)
    # the dead step/start stays unclosed; stepping continued at n=2
    assert_equal [1, 2], session.events.select { |e| e.type == "step/start" }.map { |e| e.payload[:n] }
  end

  def test_resume_refuses_when_nothing_is_open
    ctx, = boot_with_approvals([{ text: "hi" }])
    agent, = spawn(ctx)
    ctx[:loop].run_turn(agent, "hello")
    assert_raises(ArgumentError) { ctx[:loop].resume_turn(agent) }
  end

  def test_the_invariant_holds_across_a_resume
    ctx, = boot_with_approvals([{ text: "Deployed." }])
    register_deploy(ctx)
    session = ctx[:sessions].create
    craft_dangling_log(ctx, session)
    ctx[:sessions].append(session.id, "approval/resolved", { call_id: "tc9", verdict: "approved" })
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    ctx[:loop].resume_turn(agent) # assert_log_invariant! runs inside every step; no raise = held
    ctx[:sessions].assert_log_invariant!(session.id, ctx[:sessions].derive_messages(session.id))
  end
end
```

Note the parked-approval double-`requested` guard in `test_resume_with_no_verdict_parks_again`: the gate parks on the *pending* request. That requires one addition to Task 7's `park` — see Step 3.

- [ ] **Step 2: Run and verify the failure mode**

Run: `mise exec -- ruby gems/terret-core/test/loop_test.rb`
Expected: `NoMethodError: resumable?` / `resume_turn`.

- [ ] **Step 3: Implement**

**3a. One addition to `Approvals#park`** (`gems/terret-core/lib/terret/approvals.rb`): a resume re-executes a call whose `approval/requested` is already logged and still pending — parking again must not append a duplicate request:

```ruby
      def park(call)
        q = Thread::Queue.new
        key = [call.session_id, call.id]
        # waiter first, then the durable request: a verdict can never land in
        # the gap between the append's fan-out and the waiter existing
        @waiting[key] = q
        agent = @ctx[:loop].agent_for_session(call.session_id)
        unless pending?(call.session_id, call.id) # a resume re-parks on the standing request
          @ctx[:sessions].append(call.session_id, "approval/requested",
                                 { call_id: call.id, name: call.name, args: call.args })
        end
        agent&.status = :waiting_approval
        # cooperative under the fiber scheduler (parks the fiber); blocks the
        # thread under plain minitest, where tests resolve from another thread
        q.pop
      ensure
        agent.status = :running if agent && agent.status == :waiting_approval
        @waiting.delete(key)
      end
```

**3b. The loop refactor.** In `gems/terret-core/lib/terret/loop.rb`, replace `run_turn` entirely with the following (`TurnState` is a `Struct` — mutation is the point; it carries what the shared `ensure` needs):

```ruby
    TurnState = Struct.new(:status, :steered)

    # Runs one turn for `input`. Returns the turn status symbol.
    def run_turn(agent, input)
      turning(agent) do |state, sessions, sid|
        sessions.append(sid, "turn/start", { agent: agent.id })
        step_loop(agent, state, pending: input.nil? ? [] : [["user/message", input]], steps: 0)
      end
    end

    # Continue a turn the log left open (a process death mid-park, plan
    # §6.3/§12 M6). No second turn/start — the open one is already durable.
    # The open step completes first: tool calls owed by the last assistant
    # message that lack a tool/result re-execute through the pipeline, where
    # the approvals gate reads verdicts from the log — an approved call runs,
    # an unresolved one parks again on its standing request. Then stepping
    # continues as normal.
    def resume_turn(agent)
      raise ArgumentError, "session #{agent.session_id} has no open turn" unless resumable?(agent.session_id)

      turning(agent) do |state, _sessions, _sid|
        step_loop(agent, state, pending: [], steps: complete_dangling(agent))
      end
    end

    # The log has a turn/start after its last turn/end.
    def resumable?(session_id)
      events = @ctx[:sessions].fetch(session_id).events
      opened = events.rindex { |e| e.type == "turn/start" }
      return false unless opened

      events[opened..].none? { |e| e.type == "turn/end" }
    end
```

Then the private machinery (all `private` methods of `Loop`):

```ruby
    private

    # Shared turn envelope: the status guard, the failure rescue, and the
    # turn/end ensure. Both entry points run their body inside it.
    def turning(agent)
      unless agent.status == :idle
        raise TurnAlreadyRunning, "agent #{agent.id} is #{agent.status}"
      end

      ctx      = agent.ctx
      sessions = ctx[:sessions]
      sid      = agent.session_id
      agent.status = :running
      state = TurnState.new(:completed, [])

      begin
        yield state, sessions, sid
      rescue Exception
        state.status = :failed
        agent.requeue(state.steered) unless state.steered.empty?
        raise
      ensure
        begin
          ctx.serial("agent/turn_stopping", agent)
          payload = { status: state.status }
          payload[:reason] = agent.cancel_reason if state.status == :cancelled && agent.cancel_reason
          sessions.append(sid, "turn/end", payload)
        ensure
          agent.clear_cancel!
          agent.status = :idle
        end
      end
      state.status
    end

    # The step cycle run_turn always had, extracted so resume_turn can enter
    # it mid-turn. `pending` holds [type, text] pairs (Task 5); `steps` is
    # how many step/starts the turn has already logged.
    def step_loop(agent, state, pending:, steps:)
      ctx      = agent.ctx
      sessions = ctx[:sessions]
      sid      = agent.session_id

      loop do
        if agent.cancelled?
          state.status = :cancelled
          return
        end

        # anything injected since the last step rides along with this one
        state.steered = agent.drain_inbox
        pending.concat(state.steered.map { |t| ["context/injected", t] })

        claim = ctx.waterfall("agent/pre_step", Claim.of(pending)) { |c| c }
        if claim.rejected || (steps.zero? && claim.messages.empty? && pending.empty?)
          agent.requeue(state.steered) if claim.rejected
          state.status = claim.rejected ? :rejected : :empty
          return
        end

        steps += 1
        raise "runaway turn" if steps > MAX_STEPS

        sessions.append(sid, "step/start", { n: steps })
        claim.messages.each { |(type, text)| sessions.append(sid, type, { text: text }) }
        state.steered = [] # once logged, these must never requeue
        pending = []

        history = sessions.derive_messages(sid)
        request = LLM::Request.new(model: nil, system: ctx[:prompt].render(agent:),
                                   messages: history, tools: ctx[:tools].schemas)
        request = ctx.waterfall("agent/request", request)
        sessions.assert_log_invariant!(sid, request.messages)

        usage = nil
        message = ctx[:llm].stream(ctx, role: :main, request: request) do |ev|
          case ev
          when LLM::TextDelta
            sessions.append(sid, "assistant/chunk", { text: ev.text })
          when LLM::Usage
            usage = ev
          end
        end
        sessions.append(sid, "assistant/message",
                        { parts: message.parts.map { |p| LLM.encode_part(p) } })
        step_end = usage ? { n: steps, usage: usage.to_h } : { n: steps }

        calls = message.tool_calls
        if calls.empty?
          sessions.append(sid, "step/end", step_end)
          state.status = :cancelled if agent.cancelled?
          return # nothing owed
        end

        calls.each do |tc|
          sessions.append(sid, "tool/call", { id: tc.id, name: tc.name, args: tc.args })
          if agent.cancelled?
            sessions.append(sid, "tool/result",
                            { id: tc.id, content: nil, error: "cancelled before execution" })
            next
          end

          execute_and_record(ctx, sessions, sid, tc)
        end
        sessions.append(sid, "step/end", step_end)
        # redundant under the sync driver (the next iteration's top check
        # would catch it); becomes load-bearing once tools can yield (§8)
        if agent.cancelled?
          state.status = :cancelled
          return
        end
        # tools owe another request -> next step
      end
    end

    def execute_and_record(ctx, sessions, sid, tc)
      result = ctx[:tools].execute(
        Tools::Call.new(id: tc.id, name: tc.name, args: tc.args, session_id: sid),
        ctx: ctx
      )
      sessions.append(sid, "tool/result",
                      { id: result.id, content: result.content, error: result.error })
    end

    # Close the crash-opened step: execute tool calls the last assistant
    # message owes that have no tool/result yet (the projection is the truth
    # — a tool/call event may itself have died unwritten), append the missing
    # tool/call events, results, and the step's step/end (without usage: the
    # original step's usage died with the process). Returns the step count so
    # step_loop numbers onward from it. Honest edges: an unclosed step/start
    # with no owed calls stays unclosed and stepping just continues; a turn
    # that crashed after a final no-tool assistant message resumes with one
    # extra model request (the model sees its history and wraps up).
    def complete_dangling(agent)
      ctx      = agent.ctx
      sessions = ctx[:sessions]
      sid      = agent.session_id
      events   = sessions.fetch(sid).events
      turn     = events[events.rindex { |e| e.type == "turn/start" }..]
      steps    = turn.count { |e| e.type == "step/start" }

      resolved = turn.filter_map { |e| e.payload[:id] if e.type == "tool/result" }
      owed = last_assistant_tool_calls(sessions.derive_messages(sid))
               .reject { |tc| resolved.include?(tc.id) }
      return steps if owed.empty?

      logged = turn.filter_map { |e| e.payload[:id] if e.type == "tool/call" }
      owed.each do |tc|
        unless logged.include?(tc.id)
          sessions.append(sid, "tool/call", { id: tc.id, name: tc.name, args: tc.args })
        end
        execute_and_record(ctx, sessions, sid, tc)
      end
      sessions.append(sid, "step/end", { n: steps })
      steps
    end

    def last_assistant_tool_calls(msgs)
      msgs.reverse_each do |m|
        next if m.role == :tool
        return m.role == :assistant ? m.tool_calls : []
      end
      []
    end
```

Delete the old `run_turn` body entirely — `turning` + `step_loop` replace it line-for-line except where this plan says otherwise. The Task 5 typed-pending logic is already woven in above.

- [ ] **Step 4: Run everything**

Run: `mise exec -- ruby gems/terret-core/test/loop_test.rb` — green, including every pre-existing turn-flow test (the refactor must be behavior-preserving for the non-resume paths; if a golden-order test fails, the refactor drifted — fix the refactor, not the test).
Run: `mise exec -- rake test` and `mise exec -- bundle exec ruby gems/terret-ws/test/protocol_test.rb` — green.

- [ ] **Step 5: Commit**

```bash
git add gems/terret-core/lib/terret/loop.rb gems/terret-core/lib/terret/approvals.rb gems/terret-core/test/loop_test.rb
git commit -m "Resume an open turn from the log"
```

---
> **RESCOPE (recorded mid-execution, after Task 8, user-confirmed):** Terret's
> primary workload is autonomous agentic systems, not interactive use. Durable
> human-in-the-loop approvals (Tasks 7–8's machinery) stay as landed — they are
> opt-in plugin rows and already wire contract — but the remaining milestone
> pivots: **everything configurable is hot-reloadable on the fly via event**,
> per-agent permissions are policy-as-code (deny-by-default allow lists,
> mutable mid-session, restart-surviving), and turn resumption triggers on
> wake, not only on an approval verdict. Compaction gains a summarizer seam
> with two providers: a basic role-based one in core (no signup) and a
> Morph-backed one (new `terret-morph` gem, wire mirrored from the deployed
> agora integration) — the user wants Morph in use ASAP. Tasks 9–18 below
> replace the original Tasks 9–15; Tasks 1–8 keep their numbers. The file map
> above predates the rescope — trust each task's own Files list where they
> disagree (notably: `wedged_boot.rb` replaces `parked_boot.rb`, and
> `gems/terret-morph/*`, `gems/hames/lib/hames/loader.rb`,
> `gems/terret-ws/lib/terret/ws/frames.rb` join the map).

### Task 9: Kernel — the reconfigure contract (`config/updated`)

Config today is a boot-time capture: services read `config[:x]` in `start` and squirrel values into ivars. This task makes hot-reload a first-class kernel contract: a `Hames::Service#reconfigure(config)` hook, a `Hames::Loader#reconfigure!(id, config)` API that replaces a row's config **wholesale** (matching layering semantics — never a merge), and a live `config/updated` event for observers. Adopted immediately where knobs matter: `Loop` (`max_agents`) and `WS::Service` (`tokens` — live bearer rotation — plus `heartbeat`/`queue_limit` for future connections).

**Files:**
- Modify: `gems/hames/lib/hames/service.rb` (the `reconfigure` default + config swap)
- Modify: `gems/hames/lib/hames/loader.rb` (`reconfigure!`)
- Modify: `gems/terret-core/lib/terret.rb` (declare `config/updated`, `:emit`, not durable)
- Modify: `gems/terret-core/lib/terret/loop.rb` (adopt), `gems/terret-ws/lib/terret/ws/service.rb` (adopt)
- Modify: `docs/events.md` (regenerated — new declared event)
- Test: `gems/hames/test/hames_test.rb`, `gems/terret-core/test/loop_test.rb`, `gems/terret-ws/test/protocol_test.rb`

- [ ] **Step 1: Read the loader first**

`Hames::Loader` keeps rows and mounted instances for `unload!` — read `gems/hames/lib/hames/loader.rb` and adapt the code below to its actual row/instance bookkeeping. The contract is fixed; the bookkeeping names are the loader's own.

- [ ] **Step 2: Write the failing tests**

In `gems/hames/test/hames_test.rb` (adapt event declaration kwargs to the file's conventions):

```ruby
class HamesReconfigureTest < Minitest::Test
  class Knobbed < Hames::Service
    service_key :knobbed
    attr_reader :knob, :seen

    def start(_ctx)
      @knob = config[:knob]
      @seen = []
    end

    def reconfigure(config)
      @knob = config[:knob]
    end
  end

  class Stubborn < Hames::Service
    service_key :stubborn
    def start(_ctx); end
    # no reconfigure override
  end

  def setup
    Hames.reset_events!
  end

  def boot(rows)
    loader = Hames::Loader.new
    loader.layer(rows)
    [loader.boot!, loader]
  end

  def test_reconfigure_swaps_config_wholesale_and_invokes_the_hook
    ctx, loader = boot([{ id: "knobbed", plugin: Knobbed, config: { knob: 1, extra: true } }])
    loader.reconfigure!("knobbed", { knob: 2 })
    assert_equal 2, ctx[:knobbed].knob
    assert_equal({ knob: 2 }, ctx[:knobbed].config, "wholesale replace: :extra must be gone")
  end

  def test_reconfigure_emits_config_updated_when_declared
    Hames.event("config/updated", mode: :emit)
    ctx, loader = boot([{ id: "knobbed", plugin: Knobbed, config: { knob: 1 } }])
    seen = []
    ctx.on("config/updated") { |id, cfg| seen << [id, cfg] }
    loader.reconfigure!("knobbed", { knob: 3 })
    assert_equal [["knobbed", { knob: 3 }]], seen
  end

  def test_reconfigure_without_the_declaration_does_not_raise
    ctx, loader = boot([{ id: "knobbed", plugin: Knobbed, config: { knob: 1 } }])
    loader.reconfigure!("knobbed", { knob: 4 }) # no config/updated declared: no emit, no raise
    assert_equal 4, ctx[:knobbed].knob
  end

  def test_a_service_without_the_hook_warns_and_keeps_running
    _ctx, loader = boot([{ id: "stubborn", plugin: Stubborn, config: {} }])
    warned = capture_warn { loader.reconfigure!("stubborn", { x: 1 }) }
    assert_match(/does not support hot-reconfigure/, warned)
  end

  def test_reconfiguring_an_unknown_row_raises
    _ctx, loader = boot([])
    assert_raises(KeyError) { loader.reconfigure!("ghost", {}) }
  end

  private

  def capture_warn
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end
end
```

Adoption tests — in `gems/terret-core/test/loop_test.rb`:

```ruby
  def test_max_agents_hot_reloads
    ctx, loader = boot_with_cap(1)
    a = ctx[:sessions].create
    b = ctx[:sessions].create
    ctx[:loop].spawn_agent(session_id: a.id)
    assert_raises(Terret::AgentCapExceeded) { ctx[:loop].spawn_agent(session_id: b.id) }

    loader.reconfigure!("loop", { max_agents: 2 })
    ctx[:loop].spawn_agent(session_id: b.id) # the raised spawn now succeeds, no restart
  end
```

(`boot_with_cap` already exists from Task 4 and returns `[ctx, loader]`.)

In `gems/terret-ws/test/protocol_test.rb` — token rotation. The WS `Service` is not mounted in the default harness rows; write this as a focused unit against a booted service row (adapt to the harness; the point is `authorized?` reads the live token set):

```ruby
  def test_bearer_tokens_hot_reload
    ctx = boot(script: [], extra_rows: [
      { id: "ws", plugin: Terret::WS::Service, config: { tokens: { "s1" => "old" } } }
    ])
    loader = ctx[:__loader] # if the harness doesn't expose the loader, boot one locally in this test
    assert ctx[:ws].authorized?("s1", "old")
    loader.reconfigure!("ws", { tokens: { "s1" => "new" } })
    refute ctx[:ws].authorized?("s1", "old"), "rotated-out token must stop authorizing"
    assert ctx[:ws].authorized?("s1", "new")
  end
```

(The harness `boot` returns only ctx; either extend it to also return the loader — updating its few callers is mechanical — or boot locally inside this test. State which you did.)

- [ ] **Step 3: Run and verify failure modes**

`mise exec -- ruby gems/hames/test/hames_test.rb` → `NoMethodError: reconfigure!`. Adoption tests → cap change has no effect / `NoMethodError`.

- [ ] **Step 4: Implement**

`gems/hames/lib/hames/service.rb`:

```ruby
    # Hot-reload hook (plan §M6): the loader replaces config wholesale, then
    # calls this. Override to re-derive whatever start captured. The default
    # warns — a service running on stale knobs should say so, not hide it.
    def reconfigure(_config)
      warn "hames: #{self.class} does not support hot-reconfigure; remount the row to apply"
    end

    # Loader-only: swap the config object under the reader.
    def replace_config!(config)
      @config = config
    end
```

`gems/hames/lib/hames/loader.rb` (adapt names to its bookkeeping):

```ruby
    # Hot config swap — wholesale, like layering, never a merge. Replaces the
    # row's config, swaps the mounted service's, invokes its reconfigure hook,
    # and emits config/updated when the app vocabulary declares it (hames
    # itself declares no events and stays app-agnostic).
    def reconfigure!(id, config)
      row = @rows.find { |r| r[:id] == id } or raise KeyError, "no row #{id.inspect}"
      row[:config] = config
      service = <the mounted instance for this row>
      service.replace_config!(config)
      service.reconfigure(config)
      @ctx.emit("config/updated", id, config) if Hames.declared?("config/updated")
      config
    end
```

`gems/terret-core/lib/terret.rb`, with the live extension points:

```ruby
    e.("config/updated",   :emit,      doc: "a row's config was hot-swapped (id, config)")
```

Adoption — `Loop`:

```ruby
    def reconfigure(config)
      @max_agents = config[:max_agents] || 128
    end
```

`WS::Service`:

```ruby
      def reconfigure(config)
        @tokens = config[:tokens] || {}
        @queue_limit = config[:queue_limit] || 256
        @heartbeat = config[:heartbeat] || 20
      end
```

- [ ] **Step 5: Catalog + gates**

`mise exec -- rake events:catalog` (one new row). Then all suites: `mise exec -- rake test`, `mise exec -- bundle exec rake test`, foreground, one at a time.

- [ ] **Step 6: Commit**

HEAD-guard, then stage exactly the touched files (hames service/loader + tests, terret.rb, loop.rb + test, ws service + test, docs/events.md):

```bash
git commit -m "Teach services to reconfigure on the fly"
```

---

### Task 10: Core+WS — hot-reloadable per-agent permissions through the log

The user-facing heart of the rescope. The M5 `AllowList` freezes its patterns in a closure; this task makes per-agent permissions a **log projection**: the active pattern set is the last durable `policy/updated` event in the agent's session, falling back to the install-time patterns as the floor. `update` is an ordinary durable append — effective on the very next tool call with no restart, **and replay rebuilds it, so a hot-reloaded policy survives a deploy for free**. The socket drives it with a new `set_policy` frame (same seam-first pattern as `set_model`). Deny-by-default stays; a denied call is an error result the model reacts to.

**Files:**
- Modify: `gems/terret-core/lib/terret.rb` (declare `policy/updated`, durable)
- Modify: `gems/terret-core/lib/terret/tools.rb` (AllowList v2)
- Modify: `gems/terret-ws/lib/terret/ws/frames.rb` (`set_policy` frame)
- Modify: `gems/terret-ws/lib/terret/ws/connection.rb` (handler)
- Modify: `docs/protocol.md`, `docs/lifecycle.md` (new "Hot-reloadable permissions" section), `docs/events.md` (regenerated)
- Test: `gems/terret-core/test/loop_test.rb`, `gems/terret-ws/test/protocol_test.rb`

- [ ] **Step 1: Write the failing core tests**

In `gems/terret-core/test/loop_test.rb` (a new class; reuse `TerretTestHarness`):

```ruby
class HotPolicyTest < Minitest::Test
  include TerretTestHarness

  PING = Terret::LLM::ToolCall.new(id: "tp1", name: "ping", args: {})

  def register_ping(ctx)
    ctx.with_owner("ping-plugin") do
      ctx[:tools].register(name: "ping", description: "Pong", params: {}) { "pong" }
    end
  end

  def test_policy_updates_take_effect_without_reinstall
    ctx, = boot(script: [{ text: "Pinging.", tool_calls: [PING] }, { text: "done" },
                         { text: "Pinging.", tool_calls: [PING.with(id: "tp2")] }, { text: "done" }])
    register_ping(ctx)
    agent, session = spawn(ctx)
    Terret::Tools::AllowList.install(agent.ctx, ["nothing"]) # floor denies

    ctx[:loop].run_turn(agent, "ping please")
    first = session.events.find { |e| e.type == "tool/result" }
    assert_match(/allow list/, first.payload[:error])

    Terret::Tools::AllowList.update(ctx, session.id, ["ping"])
    ctx[:loop].run_turn(agent, "again")
    last = session.events.select { |e| e.type == "tool/result" }.last
    assert_equal "pong", last.payload[:content]
  end

  def test_the_last_policy_update_wins
    ctx, = boot(script: [])
    _, session = spawn(ctx)
    Terret::Tools::AllowList.update(ctx, session.id, ["a"])
    Terret::Tools::AllowList.update(ctx, session.id, ["b"])
    ev = session.events.select { |e| e.type == "policy/updated" }
    assert_equal 2, ev.length
    assert_equal ["b"], ev.last.payload[:patterns]
  end

  def test_a_hot_policy_survives_a_restart_by_replay
    dir = File.join(Dir.mktmpdir("terret-policy"), "store")
    # life A: JSONL store, floor allows ping, hot update denies everything
    ctx, = boot_jsonl(dir, script: [])
    session = ctx[:sessions].create(id: "p1")
    Terret::Tools::AllowList.update(ctx, "p1", ["nothing"])

    # life B: fresh boot, same dir; the embedder reinstalls only the BOOT floor
    ctx2, = boot_jsonl(dir, script: [{ text: "Pinging.", tool_calls: [PING] }, { text: "done" }])
    register_ping(ctx2)
    ctx2[:sessions].resume("p1")
    agent = ctx2[:loop].spawn_agent(session_id: "p1")
    Terret::Tools::AllowList.install(agent.ctx, ["ping"]) # boot floor says yes...

    ctx2[:loop].run_turn(agent, "ping?")
    result = ctx2[:sessions].fetch("p1").events.find { |e| e.type == "tool/result" }
    assert_match(/allow list/, result.payload[:error],
                 "...but the logged policy says no, and the log wins")
  end

  def test_policy_is_projection_invisible
    ctx, = boot(script: [])
    _, session = spawn(ctx)
    Terret::Tools::AllowList.update(ctx, session.id, ["x"])
    assert_empty ctx[:sessions].derive_messages(session.id)
  end

  private

  def boot_jsonl(dir, script:)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::JSONL, config: { dir: dir } },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop",     plugin: Terret::Loop }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))
    [ctx, loader]
  end
end
```

- [ ] **Step 2: Implement the core side**

Declare in `terret.rb` with the durable events:

```ruby
    e.("policy/updated",   :emit, durable: true,
       doc: "agent allow-list replaced (metadata; projection-invisible)")
```

Replace `AllowList` in `gems/terret-core/lib/terret/tools.rb`:

```ruby
    # Deny-by-default allow list (plan §6.3), hot-reloadable (§12 M6): the
    # ACTIVE pattern set is the last durable policy/updated event in the
    # call's session, falling back to the install-time patterns as the floor.
    # update is an ordinary durable append — it takes effect on the very next
    # call with no reinstall, and replay rebuilds it, so a hot-reloaded
    # policy survives a restart while the floor only governs sessions that
    # never updated. Patterns are File.fnmatch globs; matching is
    # case-sensitive and "*" does not match dotfiles — both fail closed.
    module AllowList
      def self.install(ctx, patterns)
        floor = Array(patterns).map(&:to_s)
        ctx.on("tools/pre_execute") do |call, next_|
          active = current_patterns(ctx, call.session_id) || floor
          if active.any? { |p| File.fnmatch(p, call.name) }
            next_.(call)
          else
            Veto.new(reason: "#{call.name} is not on the allow list")
          end
        end
      end

      # Hot update: durable, per-session, last one wins.
      def self.update(ctx, session_id, patterns)
        ctx[:sessions].append(session_id, "policy/updated",
                              { patterns: Array(patterns).map(&:to_s) })
      end

      def self.current_patterns(ctx, session_id)
        ctx[:sessions].fetch(session_id).events.reverse_each
                      .find { |e| e.type == "policy/updated" }
                      &.payload&.[](:patterns)
      rescue KeyError
        nil # session unknown to this context: the floor applies
      end
    end
```

Regenerate the catalog (`mise exec -- rake events:catalog`). Run the core tests — green.

- [ ] **Step 3: The socket frame, failing test first**

In `gems/terret-ws/test/protocol_test.rb`:

```ruby
  def test_set_policy_flips_permissions_mid_session
    Sync do |task|
      ping = Terret::LLM::ToolCall.new(id: "tp9", name: "ping", args: {})
      ctx = boot(script: [{ text: "Pinging.", tool_calls: [ping] }, { text: "done" }])
      ctx.with_owner("ping-plugin") do
        ctx[:tools].register(name: "ping", description: "Pong", params: {}) { "pong" }
      end
      agent, session = spawn_agent(ctx)
      Terret::Tools::AllowList.install(agent.ctx, ["nothing"])
      sock, = connect(ctx, agent, task)

      sock.client_send({ type: "set_policy", patterns: ["ping"] })
      await { session.events.any? { |e| e.type == "policy/updated" } }

      sock.client_send({ type: "inject", text: "go", wake: true })
      await { session.events.any? { |e| e.type == "turn/end" } }
      assert_equal "pong", session.events.find { |e| e.type == "tool/result" }.payload[:content]
      sock.client_close
    end
  end

  def test_set_policy_rejects_non_string_patterns
    Sync do |task|
      ctx = boot(script: [])
      agent, session = spawn_agent(ctx)
      sock, = connect(ctx, agent, task)
      sock.client_send({ type: "set_policy", patterns: [1, 2] })
      await { sock.protocol_frames.any? { |f| f[:code] == "bad_frame" } }
      refute session.events.map(&:type).include?("policy/updated")
      sock.client_close
    end
  end
```

Implement: `frames.rb` `CLIENT` gains `"set_policy" => [:patterns]` (read how `Frames.decode` validates required fields and follow it); `connection.rb` dispatch gains `when "set_policy" then handle_set_policy(frame[:patterns])` and:

```ruby
      def handle_set_policy(patterns)
        unless patterns.is_a?(Array) && patterns.all? { |p| p.is_a?(String) }
          return push_frame(Frames.error(code: "bad_frame",
                                         message: "patterns must be an array of strings"))
        end

        Tools::AllowList.update(@ctx, @sid, patterns)
      end
```

- [ ] **Step 4: Docs**

`docs/protocol.md`: add `set_policy` to the client-frame table (`patterns`, required) and a short section: durable `policy/updated` append, last-wins, effective next call, survives restarts by replay, floor semantics. `docs/lifecycle.md`: new "Hot-reloadable permissions" section after "Agent lifecycle", same content in the primer's voice, plus one sentence in the approvals section noting approvals are an opt-in row and autonomous profiles run policy-as-code instead.

- [ ] **Step 5: Gates and commit**

Both gates foreground, one at a time. HEAD-guard, then stage the touched files (terret.rb, tools.rb, loop_test.rb, frames.rb, connection.rb, protocol_test.rb, docs/protocol.md, docs/lifecycle.md, docs/events.md):

```bash
git commit -m "Make agent permissions hot-reloadable through the log"
```

---
### Task 11: Core — `ctx[:compactor]` on a summarizer seam

The compactor owns the *mechanics* — the budget trigger, the boundary contract, the durable append — and delegates summary *generation* to a sole-provider seam, `ctx[:summarizer]`, exactly like `ctx[:session_store]` has memory/JSONL/SQLite providers. Core ships the no-signup default (`RoleSummarizer`: one model call through the `:compactor` role); Task 12 ships the Morph provider. A summarizer may **decline** (return nil/empty): compaction is an optimization, so a declined or failed compaction warns and the next overweight turn retries. The §12 boundary contract is enforced and tested: **`upto_seq` is always the seq immediately preceding the compaction event itself**, computed at append time (only projection-invisible events can land during summarization — the agent is still mid-turn).

**Files:**
- Create: `gems/terret-core/lib/terret/compactor.rb` (Compactor + RoleSummarizer)
- Modify: `gems/terret-core/lib/terret.rb` (require)
- Test: `gems/terret-core/test/compactor_test.rb`

- [ ] **Step 1: Write the failing tests**

Create `gems/terret-core/test/compactor_test.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret"

class CompactorTest < Minitest::Test
  def boot(script:, budget: nil, summarizer: Terret::RoleSummarizer)
    Hames.reset_events!
    Terret.declare_events!

    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service,
        config: { roles: { main: "fake/scripted", compactor: "fake/scripted" } } },
      { id: "loop",     plugin: Terret::Loop },
      { id: "summarizer", plugin: summarizer },
      { id: "compactor", plugin: Terret::Compactor, config: budget ? { budget: budget } : {} }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))
    [ctx, loader]
  end

  def spawn(ctx)
    session = ctx[:sessions].create
    [ctx[:loop].spawn_agent(session_id: session.id), session]
  end

  # A summarizer that declines every request (Morph-without-a-key shape).
  class DecliningSummarizer < Hames::Service
    service_key :summarizer
    def start(_ctx); end
    def summarize(_history) = nil
  end

  def test_compact_appends_the_boundary_event_with_the_contractual_upto_seq
    # script: one turn step, then the role summarizer's reply (same fake adapter)
    ctx, = boot(script: [{ text: "A long conversation." }, { text: "SUMMARY: we talked." }])
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "hello")

    compacted = ctx[:compactor].compact!(session.id)

    assert_equal "session/compacted", compacted.type
    assert_equal compacted.seq - 1, compacted.payload[:upto_seq],
                 "upto_seq must be the immediately preceding seq (plan §12 M6 note)"
    assert_equal "SUMMARY: we talked.", compacted.payload[:summary]
  end

  def test_the_projection_replaces_the_prefix_and_the_invariant_holds_after
    ctx, = boot(script: [{ text: "First reply." },
                         { text: "SUMMARY: greeted." },
                         { text: "Second reply." }])
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "hello")
    ctx[:compactor].compact!(session.id)

    derived = ctx[:sessions].derive_messages(session.id)
    assert_equal 1, derived.length
    assert_equal "SUMMARY: greeted.", derived.first.text

    # the next turn runs on the compacted projection; the loop asserts the
    # invariant on every request, so completing is the proof
    assert_equal :completed, ctx[:loop].run_turn(agent, "and now?")
    assert_equal ["SUMMARY: greeted.", "and now?", "Second reply."],
                 ctx[:sessions].derive_messages(session.id).map(&:text)
  end

  def test_the_budget_trigger_compacts_after_an_overweight_turn
    heavy = { prompt_tokens: 900, completion_tokens: 5, cost: 0.1 }
    light = { prompt_tokens: 10,  completion_tokens: 5, cost: 0.01 }
    ctx, = boot(script: [{ text: "small", usage: light },
                         { text: "big", usage: heavy },
                         { text: "SUMMARY: big talk." }],
                budget: 500)
    agent, session = spawn(ctx)

    ctx[:loop].run_turn(agent, "one")
    refute session.events.map(&:type).include?("session/compacted"), "light turn must not compact"

    ctx[:loop].run_turn(agent, "two")
    compacted = session.events.select { |e| e.type == "session/compacted" }
    assert_equal 1, compacted.length
    assert_equal compacted.first.seq - 1, compacted.first.payload[:upto_seq]
  end

  def test_the_budget_hot_reloads
    heavy = { prompt_tokens: 900, completion_tokens: 5, cost: 0.1 }
    ctx, loader = boot(script: [{ text: "big", usage: heavy },
                                { text: "big again", usage: heavy },
                                { text: "SUMMARY: later." }])
    agent, session = spawn(ctx)

    ctx[:loop].run_turn(agent, "one") # no budget configured: never compacts
    refute session.events.map(&:type).include?("session/compacted")

    loader.reconfigure!("compactor", { budget: 500 })
    ctx[:loop].run_turn(agent, "two")
    assert session.events.map(&:type).include?("session/compacted"),
           "a hot-set budget must arm the trigger without a remount"
  end

  def test_the_latest_compaction_supersedes_earlier_ones
    ctx, = boot(script: [{ text: "r1" }, { text: "S1" }, { text: "r2" }, { text: "S2" }])
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "a")
    ctx[:compactor].compact!(session.id)
    ctx[:loop].run_turn(agent, "b")
    ctx[:compactor].compact!(session.id)

    assert_equal ["S2"], ctx[:sessions].derive_messages(session.id).map(&:text)
  end

  def test_a_declining_summarizer_skips_the_boundary_and_the_turn_survives
    heavy = { prompt_tokens: 900, completion_tokens: 5, cost: 0.1 }
    ctx, = boot(script: [{ text: "big", usage: heavy }],
                budget: 500, summarizer: DecliningSummarizer)
    agent, session = spawn(ctx)

    assert_equal :completed, ctx[:loop].run_turn(agent, "hello")
    assert session.events.map(&:type).include?("turn/end")
    refute session.events.map(&:type).include?("session/compacted")
    assert_nil ctx[:compactor].compact!(session.id), "manual compact! reports the decline as nil"
  end

  def test_compacting_an_empty_session_refuses
    ctx, = boot(script: [])
    session = ctx[:sessions].create
    assert_raises(ArgumentError) { ctx[:compactor].compact!(session.id) }
  end

  def test_a_raising_summarizer_is_isolated_by_the_trigger
    # No :compactor role on the adapter map -> RoleSummarizer's resolve raises
    # KeyError inside the trigger listener; Task 2's emit isolation keeps the
    # turn/end append (and the turn) alive. Manual compact! raises through.
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
      { id: "summarizer", plugin: Terret::RoleSummarizer },
      { id: "compactor", plugin: Terret::Compactor, config: { budget: 1 } }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(
      [{ text: "hi", usage: { prompt_tokens: 10, completion_tokens: 1, cost: 0.0 } }]
    ))
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)

    assert_equal :completed, ctx[:loop].run_turn(agent, "hello")
    assert session.events.map(&:type).include?("turn/end")
    refute session.events.map(&:type).include?("session/compacted")
    assert_raises(KeyError) { ctx[:compactor].compact!(session.id) }
  end
end
```

- [ ] **Step 2: Run and verify the failure mode**

`mise exec -- ruby gems/terret-core/test/compactor_test.rb` → `NameError: uninitialized constant Terret::Compactor` (then `Terret::RoleSummarizer`).

- [ ] **Step 3: Implement**

Create `gems/terret-core/lib/terret/compactor.rb`:

```ruby
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
```

In `gems/terret-core/lib/terret.rb`, after the approvals require:

```ruby
require_relative "terret/compactor"
```

- [ ] **Step 4: Gates and commit**

Both gates foreground, one at a time. HEAD-guard, stage exactly compactor.rb, terret.rb, compactor_test.rb:

```bash
git commit -m "Compact history behind a durable boundary"
```

---

### Task 12: `terret-morph` — the Morph-backed summarizer

An eighth gem, mirroring the wire of the deployed integration in agora (`Morph::CompactClient`): `POST {base}/compact` with `Authorization: Bearer <key>` and body `{input:, compression_ratio:, preserve_recent: 0}`; a 2xx JSON object with a String `"output"` is success; **everything else declines to nil with a warn** — the Compactor skips the boundary and life goes on. Morph does extractive line-level compression (surviving lines byte-identical), so the "summary" is a compressed transcript. Zero runtime dependencies: stdlib `net/http` (fiber-scheduler-aware, so it cooperates under async). The transport is injectable exactly like terret-openrouter's, so unit tests need no network; an opt-in live lane (`MORPH_LIVE=1` + `MORPH_API_KEY`) proves the real wire.

**Files:**
- Create: `gems/terret-morph/terret-morph.gemspec`
- Create: `gems/terret-morph/lib/terret/morph.rb`
- Create: `gems/terret-morph/lib/terret/morph/summarizer.rb`
- Create: `gems/terret-morph/test/summarizer_test.rb`
- Modify: `Gemfile` (path entry)

- [ ] **Step 1: Scaffold the gem**

Copy the shape of `gems/terret-store-sqlite` (the smallest existing gem): gemspec (name `terret-morph`, version `0.1.0`, summary "Morph-backed context compaction for Terret", zero runtime dependencies), `lib/terret/morph.rb` entry with the monorepo fallback require of terret-core, `Gemfile` gains `gem "terret-morph", path: "gems/terret-morph"`. The Rakefile's `gems/*/test` glob picks the tests up automatically — verify with `mise exec -- rake test` listing the new suite.

- [ ] **Step 2: Write the failing tests**

Create `gems/terret-morph/test/summarizer_test.rb`. The injectable transport is a callable `->(url, headers, body) { [status_integer, response_body_string] }`:

```ruby
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
```

- [ ] **Step 3: Implement**

`gems/terret-morph/lib/terret/morph/summarizer.rb`:

```ruby
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
```

`gems/terret-morph/lib/terret/morph.rb` follows the terret-store-sqlite entry pattern (fallback require of terret-core, then `require_relative "morph/summarizer"`).

- [ ] **Step 4: Wire-shape sanity against agora**

Diff your request body and failure taxonomy against `/Users/obie/projects/agentus/agora/app/services/morph/compact_client.rb` — the shapes must match (input/query/compression_ratio/preserve_recent; nil-on-everything; the timeout-zero floor). `query:` is deliberately omitted in terret v1.

- [ ] **Step 5: Gates and commit**

Both gates foreground (the new suite rides the glob). If `MORPH_API_KEY` is set locally, run the live lane once: `MORPH_LIVE=1 mise exec -- ruby gems/terret-morph/test/summarizer_test.rb -n test_live_lane` — report its result either way. HEAD-guard, stage the new gem files + Gemfile:

```bash
git commit -m "Interface with Morph for extractive compaction"
```

> **Review fallout (P3, accepted):** `Summarizer#summarize`'s `rescue
> StandardError` is broader than agora's narrow Faraday+JSON rescue — a logic
> bug declines instead of raising. Accepted because the injectable-transport
> contract has no common exception ancestor (Net::HTTP spans Errno::*,
> SocketError, OpenSSL, Net::*Timeout) and the decline line carries
> `e.class: e.message`. Ship task: record in §14 as an accepted-deferral
> (revisit when terret grows an error-tracking seam).

---
### Task 13: Core — `ctx[:titler]` and the `session/titled` event

One durable title per session, generated at the first `turn/end` through the `:titler` role (the role machinery is a config row — `LLM::Service#resolve` already takes arbitrary role symbols), falling back to the first user message truncated to 40 chars when no role is configured. Titles are metadata: projection-invisible, exactly like the approval and policy events. Declares a new durable event, so the catalog regenerates **in the same commit**. Titler's only knob (`:role`) is read per call, so it is hot-reload-live by construction — note that in a comment, no `reconfigure` override needed.

**Files:**
- Create: `gems/terret-core/lib/terret/titler.rb`
- Modify: `gems/terret-core/lib/terret.rb` (declare `session/titled`; require)
- Modify: `gems/terret-core/lib/terret/sessions.rb` (`title` reader)
- Modify: `docs/events.md` (regenerated)
- Test: `gems/terret-core/test/titler_test.rb`

- [ ] **Step 1: Write the failing tests**

Create `gems/terret-core/test/titler_test.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret"

class TitlerTest < Minitest::Test
  def boot(script:, titler_role: true)
    Hames.reset_events!
    Terret.declare_events!

    roles = { main: "fake/scripted" }
    roles[:titler] = "fake/scripted" if titler_role
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service, config: { roles: roles } },
      { id: "loop",     plugin: Terret::Loop },
      { id: "titler",   plugin: Terret::Titler }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))
    [ctx, loader]
  end

  def spawn(ctx)
    session = ctx[:sessions].create
    [ctx[:loop].spawn_agent(session_id: session.id), session]
  end

  def test_the_first_turn_end_titles_the_session_through_the_role
    ctx, = boot(script: [{ text: "Sure, tacos it is." }, { text: "Taco night planning" }])
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "help me plan taco night")

    assert_equal "Taco night planning", ctx[:sessions].title(session.id)
    titled = session.events.select { |e| e.type == "session/titled" }
    assert_equal 1, titled.length
    # titles are metadata: projection-invisible
    refute_includes ctx[:sessions].derive_messages(session.id).map(&:text), "Taco night planning"
  end

  def test_titling_happens_once
    ctx, = boot(script: [{ text: "r1" }, { text: "The Title" }, { text: "r2" }])
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "one")
    ctx[:loop].run_turn(agent, "two") # consumes "r2"; no second title call

    assert_equal 1, session.events.count { |e| e.type == "session/titled" }
    assert_equal "The Title", ctx[:sessions].title(session.id)
  end

  def test_without_a_titler_role_the_first_user_line_is_the_title
    ctx, = boot(script: [{ text: "ok" }], titler_role: false)
    agent, session = spawn(ctx)
    ctx[:loop].run_turn(agent, "a very long request about the state of the world and everything else")

    # 40 chars, then title!'s strip: "…state of t"
    assert_equal "a very long request about the state of t", ctx[:sessions].title(session.id)
  end

  def test_title_reader_returns_nil_untitled
    ctx, = boot(script: [])
    session = ctx[:sessions].create
    assert_nil ctx[:sessions].title(session.id)
  end
end
```

- [ ] **Step 2: Run and verify the failure mode**

`mise exec -- ruby gems/terret-core/test/titler_test.rb` → `NameError: uninitialized constant Terret::Titler`.

- [ ] **Step 3: Implement**

Declare the event in `gems/terret-core/lib/terret.rb`, after the `policy/updated` line:

```ruby
    e.("session/titled",   :emit, durable: true, doc: "session titled (metadata; projection-invisible)")
```

Add the reader to `Sessions` (after `usage`):

```ruby
    # The latest session/titled's title, or nil. Metadata, not model history.
    def title(session_id)
      fetch(session_id).events.reverse_each
                       .find { |e| e.type == "session/titled" }
                       &.payload&.[](:title)
    end
```

Create `gems/terret-core/lib/terret/titler.rb`:

```ruby
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
```

In `gems/terret-core/lib/terret.rb`, after the compactor require: `require_relative "terret/titler"`.

- [ ] **Step 4: Catalog, gates, commit**

`mise exec -- rake events:catalog` (one new row), both gates foreground, HEAD-guard, stage titler.rb + terret.rb + sessions.rb + titler_test.rb + docs/events.md:

```bash
git commit -m "Title sessions once, durably"
```

---

### Task 14: WS — wakes that resume, verdicts that validate, races that requeue

Four socket changes for the rescoped story:

1. **Auto-resume on wake** (the autonomous resume trigger): a `wake: true` inject on an idle agent whose session has an open turn in the log resumes that turn — the text rides the resumed turn's next step as `context/injected` — instead of starting a new one.
2. **The wake race requeues**: two wake frames in one read burst both see `:idle` before either turn task runs; the loser's `TurnAlreadyRunning` requeues its text into the inbox instead of dropping it (resolving the M4 comment in `ws/service.rb`).
3. **Approvals stay opt-in**: the WS Service does NOT inject `:approvals`. Where the row is mounted, `approve`/`deny` validate against `pending?` (a miss answers a new `stale_call` error frame, nothing appended), a verdict landing for an idle agent with an open turn triggers the resumer, and `cancel` on a `:waiting_approval` agent denies pending approvals durably then cancels. Where the row is absent, `approve`/`deny` answer a new `unsupported` error frame.
4. `docs/protocol.md` catches up on all of it.

**Files:**
- Modify: `gems/terret-ws/lib/terret/ws/service.rb` (runner requeue, resumer lambda)
- Modify: `gems/terret-ws/lib/terret/ws/connection.rb` (inject/cancel/resolution handlers)
- Modify: `docs/protocol.md`
- Test: `gems/terret-ws/test/protocol_test.rb`

- [ ] **Step 1: Harness updates + failing tests**

`connect` must hand the Connection a real resumer, mirroring `runner`:

```ruby
  def resumer(ctx, root)
    ->(agent) { root.async { ctx[:loop].resume_turn(agent) } }
  end

  def connect(ctx, agent, root, queue_limit: 256)
    sock = FakeSocket.new
    conn = Terret::WS::Connection.new(ctx: ctx, agent: agent, io: sock,
                                      runner: runner(ctx, root), resumer: resumer(ctx, root),
                                      queue_limit: queue_limit)
    conn_task = root.async { conn.run }
    [sock, conn, conn_task]
  end

  APPROVALS_ROW = { id: "approvals", plugin: Terret::Tools::Approvals }.freeze

  DEPLOY_CALL = -> { Terret::LLM::ToolCall.new(id: "tc7", name: "deploy", args: { env: "prod" }) }

  def register_deploy(ctx)
    ctx.with_owner("deploy-plugin") do
      ctx[:tools].register(name: "deploy", description: "Ship it",
                           params: { env: "string" }, mutating: true,
                           approval: :always) { |env:| "deployed to #{env}" }
    end
  end
```

The tests:

```ruby
  def test_a_wake_on_a_resumable_turn_resumes_it_with_the_text_riding_along
    Sync do |task|
      ctx = boot(script: [{ text: "Caught up." }])
      ctx.with_owner("deploy-plugin") do
        ctx[:tools].register(name: "deploy", description: "Ship it",
                             params: { env: "string" }) { |env:| "deployed to #{env}" }
      end
      session = ctx[:sessions].create
      sid = session.id
      ctx[:sessions].append(sid, "turn/start", { agent: "agent-#{sid}" })
      ctx[:sessions].append(sid, "step/start", { n: 1 })
      ctx[:sessions].append(sid, "user/message", { text: "ship it" })
      ctx[:sessions].append(sid, "assistant/message",
                            { parts: [Terret::LLM.encode_part(DEPLOY_CALL.call)] })
      ctx[:sessions].append(sid, "tool/call", { id: "tc7", name: "deploy", args: { env: "prod" } })
      agent = ctx[:loop].spawn_agent(session_id: sid)

      sock, = connect(ctx, agent, task)
      sock.client_send({ type: "inject", text: "you back?", wake: true })
      await { session.events.any? { |e| e.type == "turn/end" } }

      assert_equal 1, session.events.count { |e| e.type == "turn/start" }, "resume, not a new turn"
      assert_equal "deployed to prod",
                   session.events.find { |e| e.type == "tool/result" }.payload[:content]
      injected = session.events.find { |e| e.type == "context/injected" }
      assert_equal "you back?", injected.payload[:text], "the wake text rides the resumed turn"
      sock.client_close
    end
  end

  def test_two_racing_wakes_lose_no_text
    Sync do |task|
      # FakeAdapter never yields, so a plain turn completes before the second
      # wake's task runs — no race. A sleeping tool parks the first turn's
      # fiber mid-step, deterministically forcing the second wake to hit
      # status :running and lose: its rescue must requeue, not drop.
      slow_call = Terret::LLM::ToolCall.new(id: "tcs", name: "slow", args: {})
      ctx = boot(script: [{ text: "Working.", tool_calls: [slow_call] }, { text: "All done." }])
      ctx.with_owner("slow-plugin") do
        ctx[:tools].register(name: "slow", description: "Takes a moment",
                             params: {}) { sleep(0.02) || "done" }
      end
      agent, session = spawn_agent(ctx)
      sock, = connect(ctx, agent, task)

      sock.client_send({ type: "inject", text: "first", wake: true })
      sock.client_send({ type: "inject", text: "second", wake: true })
      await { session.events.any? { |e| e.type == "turn/end" } && agent.status == :idle }

      texts = session.events.select { |e| %w[user/message context/injected].include?(e.type) }
                            .map { |e| [e.type, e.payload[:text]] }
      assert_includes texts, ["user/message", "first"]
      assert_includes texts, ["context/injected", "second"],
                      "the raced wake's text must ride the winner's next step, not drop"
      assert_equal 1, session.events.count { |e| e.type == "turn/start" }
      sock.client_close
    end
  end

  def test_approve_without_the_approvals_row_answers_unsupported
    Sync do |task|
      ctx = boot(script: [])
      agent, session = spawn_agent(ctx)
      sock, = connect(ctx, agent, task)
      sock.client_send({ type: "approve", call_id: "x" })
      await { sock.protocol_frames.any? { |f| f[:code] == "unsupported" } }
      refute session.events.map(&:type).include?("approval/resolved")
      sock.client_close
    end
  end

  def test_an_approve_for_nothing_pending_answers_stale_call_and_appends_nothing
    Sync do |task|
      ctx = boot(script: [], extra_rows: [APPROVALS_ROW])
      agent, session = spawn_agent(ctx)
      sock, = connect(ctx, agent, task)
      sock.client_send({ type: "approve", call_id: "ghost" })
      await { sock.protocol_frames.any? { |f| f[:code] == "stale_call" } }
      refute session.events.map(&:type).include?("approval/resolved")
      sock.client_close
    end
  end

  def test_park_approve_execute_over_the_socket
    Sync do |task|
      ctx = boot(script: [{ text: "Deploying.", tool_calls: [DEPLOY_CALL.call] }, { text: "Done." }],
                 extra_rows: [APPROVALS_ROW])
      register_deploy(ctx)
      agent, session = spawn_agent(ctx)
      sock, = connect(ctx, agent, task)
      sock.client_send({ type: "subscribe", from_seq: 0 })

      sock.client_send({ type: "inject", text: "ship it", wake: true })
      await { agent.status == :waiting_approval }
      await { sock.event_types.include?("approval/requested") }

      sock.client_send({ type: "approve", call_id: "tc7" })
      await { session.events.any? { |e| e.type == "turn/end" } }
      assert_equal "deployed to prod",
                   session.events.find { |e| e.type == "tool/result" }.payload[:content]
      assert_equal :idle, agent.status
      sock.client_close
    end
  end

  def test_cancel_while_parked_denies_durably_and_cancels_the_turn
    Sync do |task|
      ctx = boot(script: [{ text: "Deploying.", tool_calls: [DEPLOY_CALL.call] }, { text: "Done." }],
                 extra_rows: [APPROVALS_ROW])
      register_deploy(ctx)
      agent, session = spawn_agent(ctx)
      sock, = connect(ctx, agent, task)

      sock.client_send({ type: "inject", text: "ship it", wake: true })
      await { agent.status == :waiting_approval }

      sock.client_send({ type: "cancel", reason: "changed my mind" })
      await { session.events.any? { |e| e.type == "turn/end" } }

      resolved = session.events.find { |e| e.type == "approval/resolved" }
      assert_equal "denied", resolved.payload[:verdict]
      turn_end = session.events.find { |e| e.type == "turn/end" }
      assert_equal "cancelled", turn_end.payload[:status]
      assert_equal "changed my mind", turn_end.payload[:reason]
      sock.client_close
    end
  end

  def test_a_verdict_for_an_idle_agent_with_an_open_turn_resumes_it
    Sync do |task|
      ctx = boot(script: [{ text: "Done." }], extra_rows: [APPROVALS_ROW])
      register_deploy(ctx)
      session = ctx[:sessions].create
      sid = session.id
      ctx[:sessions].append(sid, "turn/start", { agent: "agent-#{sid}" })
      ctx[:sessions].append(sid, "step/start", { n: 1 })
      ctx[:sessions].append(sid, "user/message", { text: "ship it" })
      ctx[:sessions].append(sid, "assistant/message",
                            { parts: [Terret::LLM.encode_part(DEPLOY_CALL.call)] })
      ctx[:sessions].append(sid, "tool/call", { id: "tc7", name: "deploy", args: { env: "prod" } })
      ctx[:sessions].append(sid, "approval/requested", { call_id: "tc7", name: "deploy", args: { env: "prod" } })
      agent = ctx[:loop].spawn_agent(session_id: sid)

      sock, = connect(ctx, agent, task)
      sock.client_send({ type: "approve", call_id: "tc7" })
      await { session.events.any? { |e| e.type == "turn/end" } }

      assert_equal "deployed to prod",
                   session.events.find { |e| e.type == "tool/result" }.payload[:content]
      assert_equal 1, session.events.count { |e| e.type == "turn/start" }
      sock.client_close
    end
  end
```

- [ ] **Step 2: Run and verify failure modes**

Auto-resume test fails (a wake starts a NEW turn today → two `turn/start`s or a guard error); race test loses "second"; `unsupported`/`stale_call` tests fail (blind append today); verdict-resume times out.

- [ ] **Step 3: Implement**

**Service** (`gems/terret-ws/lib/terret/ws/service.rb`) — inject list UNCHANGED (`:sessions, :loop, :llm`); replace `runner` (its stale M6 comment resolves as the requeue it anticipated) and add `resumer`; pass both in `attach`:

```ruby
        conn = Connection.new(ctx: @ctx, agent: agent, io: io,
                              runner: runner(runner_task), resumer: resumer(runner_task),
                              queue_limit: @queue_limit)
```

```ruby
      def runner(task)
        lambda do |agent, text|
          task.async do
            @ctx[:loop].run_turn(agent, text)
          rescue TurnAlreadyRunning
            # two wake frames in one read burst both saw :idle before either
            # task ran; the loser's text rides the winner's next step (or the
            # next turn) via the inbox instead of dropping
            agent.inject(text)
          rescue => e
            warn "terret-ws: turn failed for #{agent.id}: #{e.class}: #{e.message}"
          end
        end
      end

      # Re-enter an open turn (a wake or a verdict arrived for an agent with
      # no live fiber — the process restarted mid-turn). Rooted on the server
      # task for the same reason turns are: a dropped client must not kill it.
      def resumer(task)
        lambda do |agent|
          task.async do
            @ctx[:loop].resume_turn(agent)
          rescue TurnAlreadyRunning
            nil # something else got there first; nothing is lost
          rescue => e
            warn "terret-ws: resume failed for #{agent.id}: #{e.class}: #{e.message}"
          end
        end
      end
```

**Connection** (`gems/terret-ws/lib/terret/ws/connection.rb`): take `resumer:` (default `->(_agent) {}`), then:

```ruby
      # A wake on an idle agent whose log holds an open turn resumes that
      # turn — the text rides its next step as context/injected — instead of
      # starting a new one. That is the autonomous restart story: after a
      # deploy, the first stimulus picks the turn back up.
      def handle_inject(text, wake)
        if wake && @agent.status == :idle && @ctx[:loop].resumable?(@sid)
          @agent.inject(text)
          @resumer.call(@agent)
        elsif wake && @agent.status == :idle
          @runner.call(@agent, text)
        else
          @agent.inject(text)
        end
      end

      def handle_cancel(reason)
        case @agent.status
        when :running
          @agent.cancel(reason)
        when :waiting_approval
          # cancel first, THEN deny: the parked fiber unparks into a turn
          # that already knows it is cancelled; each denial is durable
          @agent.cancel(reason)
          @ctx[:approvals].deny_pending!(@sid, reason: reason || "cancelled")
        else
          push_frame(Frames.error(code: "not_running"))
        end
      end

      # Approvals are an opt-in row: without it, approve/deny is unsupported.
      # With it, only a call with a standing approval/requested (and no
      # verdict yet) accepts one — anything else answers stale_call and
      # appends nothing, so a double approve or a typo cannot pollute the
      # log. A verdict landing for an idle agent whose turn is still open in
      # the log means no fiber is parked (the process restarted since it
      # parked) — resume the turn.
      def handle_resolution(call_id, verdict, reason)
        unless @ctx.service?(:approvals)
          return push_frame(Frames.error(code: "unsupported",
                                         message: "no approvals service is mounted"))
        end
        unless @ctx[:approvals].pending?(@sid, call_id)
          return push_frame(Frames.error(code: "stale_call",
                                         message: "#{call_id} has no pending approval"))
        end

        payload = { call_id: call_id, verdict: verdict }
        payload[:reason] = reason if reason
        sessions.append(@sid, "approval/resolved", payload)
        @resumer.call(@agent) if @agent.status == :idle && @ctx[:loop].resumable?(@sid)
      end
```

(`:waiting_approval` is unreachable without the approvals row, so `handle_cancel`'s approvals branch needs no extra guard — but verify `@ctx[:approvals]` is only referenced under statuses/paths the row makes reachable.)

**docs/protocol.md**: error-code table gains `stale_call` and `unsupported`; the approve/deny section drops the M4 "nothing parks yet" caveat and documents: opt-in approvals row, park → durable request → resolution append → unpark, verdict-triggers-resume for a restarted process, cancel-while-parked denies durably. The inject section documents wake-resumes-an-open-turn and the wake-race requeue rule.

- [ ] **Step 4: Sweep, gates, commit**

The pre-existing approve/deny round-trip test asserted the blind append; it needs the approvals row and a staged pending request now — update it as the point of the change. Both gates foreground plus `mise exec -- bundle exec ruby gems/terret-ws/test/protocol_test.rb` and `mise exec -- bundle exec ruby examples/ws_demo.rb` (no approvals row needed there — it must still boot and run). HEAD-guard, stage service.rb + connection.rb + protocol_test.rb + docs/protocol.md:

```bash
git commit -m "Teach the socket to resume on wake and validate verdicts"
```

---
### Task 15: The kill -9 lane — a wedged deploy survives a real process death

The rescoped acceptance's hard half, no simulation shortcuts: a subprocess boots the stack on a JSONL store, gets **wedged mid-tool-execution** (the tool handler sleeps forever — no approvals involved), and dies by SIGKILL: no ensure runs, the log genuinely dangles at `tool/call` with no result. A fresh in-process boot on the same directory resumes the session, and the first **wake over the socket** re-enters the turn (Task 14's auto-resume), re-executes the tool against the new process's working handler, and completes. This also documents the honest semantic: crash recovery is **at-least-once** for tool calls — a call whose result never logged may have partially executed before the crash; idempotency is the tool's concern.

**Files:**
- Create: `gems/terret-ws/test/fixtures/wedged_boot.rb`
- Create: `gems/terret-ws/test/lifecycle_test.rb`
- Modify: `docs/lifecycle.md` (the at-least-once sentence in the resume section)

- [ ] **Step 1: Write the fixture**

`gems/terret-ws/test/fixtures/wedged_boot.rb`:

```ruby
# frozen_string_literal: true

# Boots the core stack on a JSONL store, runs a turn whose tool wedges
# forever mid-execution, prints WEDGED, and holds until killed. Driven by
# lifecycle_test.rb, which kill -9s this process to prove a mid-turn deploy
# leaves a genuinely dangling log (no ensure, no teardown) that a fresh
# process resumes.
#
# Usage: ruby wedged_boot.rb <jsonl_dir> <session_id>

require "async"
require_relative "../../../terret-core/lib/terret"

dir, sid = ARGV
abort "usage: wedged_boot.rb <jsonl_dir> <session_id>" unless dir && sid

Terret.declare_events!

loader = Hames::Loader.new
loader.layer([
  { id: "session_store", plugin: Terret::Store::JSONL, config: { dir: dir } },
  { id: "sessions", plugin: Terret::Sessions },
  { id: "prompt",   plugin: Terret::Prompt },
  { id: "tools",    plugin: Terret::Tools::Registry },
  { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
  { id: "loop",     plugin: Terret::Loop }
])
ctx = loader.boot!
ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(
  [{ text: "Deploying.",
     tool_calls: [Terret::LLM::ToolCall.new(id: "tc-kill", name: "deploy", args: { env: "prod" })] },
   { text: "Done." }]
))
ctx.with_owner("deploy-plugin") do
  ctx[:tools].register(name: "deploy", description: "Ship it",
                       params: { env: "string" }, mutating: true) { |env:| sleep }
end

ctx[:sessions].create(id: sid)
agent = ctx[:loop].spawn_agent(session_id: sid)

Sync do |task|
  task.async { ctx[:loop].run_turn(agent, "ship it") }
  task.async do
    sleep 0.005 until ctx[:sessions].fetch(sid).events.any? { |e| e.type == "tool/call" }
    puts "WEDGED"
    $stdout.flush
    sleep # hold the wedge until the kill
  end.wait
end
```

- [ ] **Step 2: Write the failing test**

`gems/terret-ws/test/lifecycle_test.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "timeout"

ASYNC_AVAILABLE = begin
  require "async"
  require "async/queue"
  true
rescue LoadError
  false
end unless defined?(ASYNC_AVAILABLE)

require_relative "../lib/terret/ws" if ASYNC_AVAILABLE

# The §12 M6 acceptance, hard half: a turn wedged mid-tool survives kill -9
# and completes after a wake in a fresh process.
class LifecycleTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/wedged_boot.rb", __dir__)

  def setup
    skip "async not installed" unless ASYNC_AVAILABLE
  end

  def test_a_wedged_deploy_resumes_after_a_real_process_death
    Dir.mktmpdir("terret-lifecycle") do |dir|
      sid = "s-deploy"

      # --- life before: wedge mid-tool, then die hard ---------------------
      # Mirror how gems/terret-mcp/test/integration_test.rb spawns its ruby
      # subprocess (RbConfig.ruby vs "ruby", env handling) — follow that
      # precedent if it differs from this:
      out = IO.popen([RbConfig.ruby, FIXTURE, dir, sid], err: [:child, :out])
      line = Timeout.timeout(30) { out.gets }
      assert_equal "WEDGED", line&.strip, "fixture never wedged; output: #{line.inspect}"
      Process.kill(:KILL, out.pid)
      Process.wait(out.pid)
      out.close

      # --- life after: fresh boot on the same directory -------------------
      Hames.reset_events!
      Terret.declare_events!
      loader = Hames::Loader.new
      loader.layer([
        { id: "session_store", plugin: Terret::Store::JSONL, config: { dir: dir } },
        { id: "sessions", plugin: Terret::Sessions },
        { id: "prompt",   plugin: Terret::Prompt },
        { id: "tools",    plugin: Terret::Tools::Registry },
        { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
        { id: "loop",     plugin: Terret::Loop }
      ])
      ctx = loader.boot!
      # the model still owes the post-tool step; the fresh process scripts it
      ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new([{ text: "Done." }]))
      ctx.with_owner("deploy-plugin") do
        ctx[:tools].register(name: "deploy", description: "Ship it",
                             params: { env: "string" }, mutating: true) { |env:| "deployed v2 to #{env}" }
      end

      session = ctx[:sessions].resume(sid)
      assert ctx[:loop].resumable?(sid), "the killed process must leave an open turn"
      before = ctx[:sessions].derive_messages(sid)

      agent = ctx[:loop].spawn_agent(session_id: sid)

      Sync do |task|
        sock = FakeIO.new
        conn = Terret::WS::Connection.new(
          ctx: ctx, agent: agent, io: sock,
          runner: ->(a, text) { task.async { ctx[:loop].run_turn(a, text) } },
          resumer: ->(a) { task.async { ctx[:loop].resume_turn(a) } }
        )
        task.async { conn.run }
        # the first stimulus after the deploy picks the turn back up
        sock.client_send({ type: "inject", text: "status?", wake: true })
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        until session.events.any? { |e| e.type == "turn/end" }
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            Async::Task.current.children&.each(&:stop)
            raise "turn never completed after the wake"
          end
          sleep 0.005
        end
        sock.client_close
      end

      result = session.events.find { |e| e.type == "tool/result" }
      assert_equal "deployed v2 to prod", result.payload[:content]
      assert_equal "completed", session.events.reverse_each
                                       .find { |e| e.type == "turn/end" }.payload[:status]
      assert_equal 1, session.events.count { |e| e.type == "turn/start" }
      assert_equal "status?",
                   session.events.find { |e| e.type == "context/injected" }&.payload&.[](:text),
                   "the wake text rode the resumed turn"

      # derived context before the wake is a strict prefix of after: the
      # resume extended history, never rewrote it
      after = ctx[:sessions].derive_messages(sid)
      assert_equal before, after.first(before.length)
    end
  end

  # Minimal io for Connection (protocol_test's FakeSocket, trimmed — or
  # extract that one into a shared helper and use it here; one harness, not
  # two, whichever is cleaner).
  class FakeIO
    def initialize
      @in = Async::Queue.new
      @closed = false
    end

    def client_send(hash) = @in.enqueue(JSON.generate(hash))
    def client_close = @in.enqueue(nil)
    def read = @closed ? nil : @in.dequeue
    def write(_text) = nil

    def close(*)
      return if @closed

      @closed = true
      @in.enqueue(nil)
    end
  end
end
```

- [ ] **Step 3: The at-least-once sentence**

Add to `docs/lifecycle.md`'s "Resuming an open turn" section: a call whose result never logged may have partially executed before the crash; resume re-executes it, so crash recovery is at-least-once for tool calls and idempotency is the tool's concern.

- [ ] **Step 4: Run, gates, commit**

`mise exec -- bundle exec ruby gems/terret-ws/test/lifecycle_test.rb` — green (debug a silent fixture by running it by hand; `err: [:child, :out]` forwards its crashes into the assertion message). Both full gates foreground. HEAD-guard, stage lifecycle_test.rb + fixtures/wedged_boot.rb + docs/lifecycle.md:

```bash
git commit -m "Prove a wedged deploy survives kill -9"
```

---

### Task 16: The in-process acceptance — many wakes, a compaction, a title, a bill, and a live policy flip

The acceptance's other half, over the socket: an agent runs many woken turns; the budget trigger compacts mid-life (role summarizer); derived context stays coherent (the invariant asserts every step); the session titles itself (fallback path — the role path is Task 13's unit turf); the spend rolls up; and **permissions flip mid-session over `set_policy`** — denied before, allowed after, no restart.

**Files:**
- Modify: `gems/terret-ws/test/protocol_test.rb` (or `lifecycle_test.rb` if protocol_test has grown unwieldy — implementer's judgment, one file, stated in the commit)

- [ ] **Step 1: Write the test**

```ruby
  def test_m6_acceptance_wakes_compaction_title_cost_and_hot_policy
    Sync do |task|
      light = { prompt_tokens: 50,  completion_tokens: 10, cost: 0.01 }
      heavy = { prompt_tokens: 800, completion_tokens: 10, cost: 0.05 }
      ping  = -> (id) { Terret::LLM::ToolCall.new(id: id, name: "ping", args: {}) }
      ctx = boot(
        script: [
          { text: "Reply one.", usage: light },
          { text: "Reply two.", usage: heavy },      # over budget -> compaction after this turn
          { text: "COMPACT: the story so far." },     # the role summarizer's call
          { text: "Pinging.", usage: light, tool_calls: [ping.("tp1")] },
          { text: "Denied then.", usage: light },     # model reacts to the veto
          { text: "Pinging.", usage: light, tool_calls: [ping.("tp2")] },
          { text: "Pong received.", usage: light }
        ],
        extra_rows: [
          { id: "summarizer", plugin: Terret::RoleSummarizer },
          { id: "compactor", plugin: Terret::Compactor, config: { budget: 500 } },
          { id: "titler",    plugin: Terret::Titler } # no :titler role -> fallback title
        ]
      )
      ctx[:llm].set_role(:compactor, "fake/scripted")
      ctx.with_owner("ping-plugin") do
        ctx[:tools].register(name: "ping", description: "Pong", params: {}) { "pong" }
      end

      agent, session = spawn_agent(ctx)
      Terret::Tools::AllowList.install(agent.ctx, ["nothing"]) # deny-by-default floor
      sock, = connect(ctx, agent, task)
      sock.client_send({ type: "subscribe", from_seq: 0 })

      # wake one: titled at first turn/end
      sock.client_send({ type: "inject", text: "start the saga", wake: true })
      await { session.events.count { |e| e.type == "turn/end" } == 1 && agent.status == :idle }
      assert_equal "start the saga", ctx[:sessions].title(session.id)

      # wake two: overweight -> compacted after turn/end, boundary contract holds
      sock.client_send({ type: "inject", text: "continue", wake: true })
      await { session.events.any? { |e| e.type == "session/compacted" } }
      compacted = session.events.find { |e| e.type == "session/compacted" }
      assert_equal compacted.seq - 1, compacted.payload[:upto_seq]
      await { sock.event_types.include?("session/compacted") }
      assert_includes sock.event_types, "session/titled"

      # wake three: the floor denies ping; the turn survives on the error result
      sock.client_send({ type: "inject", text: "ping something", wake: true })
      await { session.events.count { |e| e.type == "turn/end" } == 3 && agent.status == :idle }
      denied = session.events.find { |e| e.type == "tool/result" }
      assert_match(/allow list/, denied.payload[:error])

      # the flip: durable, effective next call, no restart
      sock.client_send({ type: "set_policy", patterns: ["ping"] })
      await { session.events.any? { |e| e.type == "policy/updated" } }

      # wake four: allowed now, and it runs on the compacted projection
      sock.client_send({ type: "inject", text: "ping again", wake: true })
      await { session.events.count { |e| e.type == "turn/end" } == 4 && agent.status == :idle }
      results = session.events.select { |e| e.type == "tool/result" }
      assert_equal "pong", results.last.payload[:content]
      assert_equal "COMPACT: the story so far.",
                   ctx[:sessions].derive_messages(session.id).first.text

      # the bill: every step/end summed over the whole life (6 steps)
      usage = ctx[:sessions].usage(session.id)
      assert_equal 6, usage[:steps]
      assert_equal 50 + 800 + 50 + 50 + 50 + 50, usage[:prompt_tokens]
      assert_in_epsilon 0.01 + 0.05 + 0.01 + 0.01 + 0.01 + 0.01, usage[:cost]
      sock.client_close
    end
  end
```

(Count the script consumption carefully at implementation time: turns one and two are single-step; the compactor consumes one entry at turn two's end; turns three and four are two-step tool turns. If the arithmetic drifts, fix the script comments, not the assertions' meaning.)

- [ ] **Step 2: Run, gates, commit**

Both gates foreground. HEAD-guard, stage the test file:

```bash
git commit -m "Prove the M6 acceptance end to end"
```

---

### Task 17: The demo — `examples/lifecycle_demo.rb`, plus web_chat touches

A narrated, deterministic walk through the rescoped M6 surface (FakeAdapter, JSONL under `tmp/`): a policy-denied deploy, a live `set_policy`-style flip (via `AllowList.update`), the allowed deploy running; an overweight turn compacting through the summarizer seam; the title and the bill; then a clean "deploy" — fresh boot, resume on the same directory — proving derived context byte-identical. Morph appears as a commented-out row swap (it needs a key; the demo must run offline). Web_chat gets the M6 touches: sidebar labels prefer `Sessions#title`, the usage badge shows the session rollup, and the titler row mounts.

**Files:**
- Create: `examples/lifecycle_demo.rb`
- Modify: `examples/web_chat.rb`

- [ ] **Step 1: Write the demo**

Follow the voice of `examples/mcp_demo.rb` (read it first). Structure — boot rows include summarizer (RoleSummarizer; a comment shows the one-row swap to `Terret::Morph::Summarizer`), compactor (budget 500), titler (fallback), JSONL store at `tmp/lifecycle_demo` (rm -rf'd at start):

Acts, each narrated with puts:
1. **Policy**: register a `deploy` tool; `AllowList.install(agent.ctx, ["nothing"])`; wake a turn whose script calls deploy → print the veto error result; `Terret::Tools::AllowList.update(ctx, "demo", ["deploy"])`; second turn's deploy runs → print the result. Print the durable `policy/updated` event to show it's in the log.
2. **Compaction**: a heavy-usage turn trips the budget; print the `session/compacted` event's seq/upto_seq and the derived projection after.
3. **Title and bill**: print `ctx[:sessions].title("demo")` and `ctx[:sessions].usage("demo")`.
4. **Clean deploy**: SHA256 the derived messages, fresh `boot` on the same dir, `resume("demo")`, digest again — print "byte-identical" and `raise` if not (a demo that lies is worse than none).

Script bookkeeping: the role summarizer consumes one fake entry at the compacting turn's end; count entries in comments. The demo must exit 0.

- [ ] **Step 2: Run it**

`mise exec -- ruby examples/lifecycle_demo.rb` — all four acts print, exit 0.

- [ ] **Step 3: Web_chat touches**

- Sidebar label: prefer `ctx[:sessions].title(id)`, falling back to the current first-user-message truncation.
- Usage badge: append the session rollup (`ctx[:sessions].usage(sid)` — show at least the summed cost).
- Mount the titler row (no `:titler` role needed — the fallback carries it).
Smoke: `PORT=19292 mise exec -- bundle exec ruby examples/web_chat.rb` boots clean (9292 may be taken by an unrelated process).

- [ ] **Step 4: Run every demo**

headless_demo, ws_demo, mcp_demo, lifecycle_demo — all clean.

- [ ] **Step 5: Commit**

HEAD-guard, stage examples/lifecycle_demo.rb + examples/web_chat.rb:

```bash
git commit -m "Walk the long-lived lifecycle in a demo"
```

---

### Task 18: Ship M6 — docs sync, gates, adversarial review, push

**Files:**
- Modify: `docs/terret-implementation-plan.md` (§12 M6 → SHIPPED; §13 sentence; §14 debts paid; §15 claim adjusted)
- Modify: `CLAUDE.md` (eight gems now; M0–M6; new services; lifecycle_demo command)
- Modify: `README.md` (per CLAUDE.md's Shipping note — same push)
- Verify: `docs/lifecycle.md`, `docs/protocol.md`, `docs/events.md` all current

- [ ] **Step 1: Sync the docs**

§12 M6 → SHIPPED in the house voice, reflecting the rescope: durable approvals landed as an opt-in row (execute-stage gate, AllowList-first ordering, restart-settling verdicts); `resume_turn` from the log proven under kill -9 with the at-least-once caveat stated; wake-triggered auto-resume; the reconfigure contract (`config/updated`, wholesale-replace) with adopted knobs; hot-reloadable per-agent policy as a durable log projection (`policy/updated`, `set_policy`, restart-surviving); the summarizer seam with the role default and the `terret-morph` provider on agora's proven wire; titling; the usage rollup; emit isolation, the UTF-8 boundary, the registry lifecycle (§14 debts 2/3/4 paid); `context/injected` live. *Deferred:* the fuller §6.4 status machine; auto-resume without a stimulus; compaction retention tails; Morph's `query:` param.

§13: one sentence — the human backstop (approvals) is optional per profile; autonomous profiles run deny-by-default hot-reloadable policy instead. §15: "Parked approvals that survive restarts" → hot-reloadable policy that survives restarts by replay; durable approvals available opt-in. §14: mark debts 2, 3, 4 *Paid down during M6*; the ws wake-race comment resolved; add accepted-deferrals from the reviews. `CLAUDE.md`: "Seven gems" → "Eight gems" with a `terret-morph` bullet; terret-core bullet mentions approvals/compactor+summarizer seam/titler/policy; commands gain `ruby examples/lifecycle_demo.rb`. `README.md`: gem list, milestone line, examples — matching.

Also sweep `docs/lifecycle.md` once against the shipped reality (it was written first; Tasks 10/14/15 amended it — make sure the approvals section carries the opt-in framing and nothing contradicts the rescope), and drop the "(Task 3)" parenthetical from the poison-test comment in protocol_test.rb while touching things (noted during Task 3's review).

- [ ] **Step 2: The full gates**

`mise exec -- rake test` AND `mise exec -- bundle exec rake test` (assertion counts differ between lanes — minitest 6 vs 5; runs/failures must not). `mise exec -- rake events:catalog && git diff --exit-code docs/events.md`. All four demos.

- [ ] **Step 3: The adversarial gates**

House process, both, before anything pushes:
1. **Whole-milestone Claude review** — a fresh reviewer over the full M6 diff (`git diff 1376959..HEAD` — note the README commit rides in it) against this plan and docs/lifecycle.md.
2. **Codex challenge** — `/codex` adversarial review of the same diff, verbatim findings, synthesized against the Claude review.

Fix P1/P2s in a final fix batch (TDD each), record accepted-deferrals in §14, append a "Final-gate fallout" section to this plan — never staging the plan itself.

- [ ] **Step 4: Push and watch**

```bash
git log --oneline origin/main..HEAD
git push origin main
gh run watch
```

- [ ] **Step 5: Final report**

What shipped, what the gates caught, what §14 carries into M7 (execution world: fs/subprocess/shell/PTY seams, sandboxing, sqlite/pty soak tests).

---

## Acceptance (M6, rescoped, from plan §12 + user direction)

- [ ] An agent runs across many wakes and a deploy without losing derived context (Task 16 in-process; Task 17's digest across a clean reboot).
- [ ] A turn wedged mid-tool survives kill -9 and completes after the first wake in a fresh process (Task 15) — at-least-once, documented.
- [ ] Per-agent permissions are deny-by-default, hot-reloadable mid-session via durable event (`set_policy` → `policy/updated`), effective next call, and survive restarts by replay (Tasks 10, 16).
- [ ] Everything configurable is hot-reloadable via event: the `reconfigure` contract with `config/updated`, adopted for max_agents/tokens/heartbeat/budget; per-call-read knobs documented as live by construction (Tasks 9, 11, 12, 13).
- [ ] Compaction behind the durable boundary (`upto_seq` = immediately preceding seq), on a summarizer seam: role-based default and the Morph provider on agora's proven wire, both degrading gracefully (Tasks 11, 12).
- [ ] Durable approvals available as an opt-in row: park, resolve over the socket, settle from the log after restart (Tasks 7, 8, 14 — already landed/reviewed).
- [ ] Titling and cost accounting live and durable (Tasks 13, 6, 16).
- [ ] §14 debts 2, 3, 4 paid; both adversarial gates run; events catalog current; README updated in the ship push; no invariant relaxed.

## Final-gate fallout (post-Task-18, before push)

Both gates ran on the full diff (`1376959..HEAD`): a fresh Claude (opus)
whole-milestone reviewer (verdict FIX_FIRST: 1 P1, 2 P2, 8 P3; all gates and
demos green; disposal hygiene, status-machine interleavings, and cross-agent
bleed all probed clean) and the Codex adversarial challenge (14 findings,
1.8M tokens of tracing). Cross-model synthesis:

**Agreement (fixed):** approval correlation was session-global and keyed only
by call_id (Codex 4 ≡ Claude P3-7) — now turn-scoped and bound to name+args.

**Claude-only (fixed):** the P1 — `run_turn` lacked the resumable-guard at the
seam, so the shipped web_chat could double-open a crashed turn and permanently
corrupt the projection (assistant tool_call with no result; the invariant
passes because request and projection agree — both wrong); guarded now via
`TurnOpenInLog` + web_chat routing. And the P2 — nested appends (compactor/
titler inside turn/end fan-out) delivered session events out of seq order on
the wire, breaking the documented reconnect rule; fixed by ordered fan-out (an
emit queue in `Sessions#append`) plus a flush sort. Three doc-vs-code
contradictions corrected.

**Codex-only (fixed):** the per-session append seq race (store writes can
yield under the fiber scheduler); park's check-then-install verdict race
(double-check after waiter install); a transient resume failure closing the
recoverable turn as `failed` (resume now leaves the turn open); the compact!
boundary racing a concurrent wake (CAS guard: model-visible arrivals past the
snapshot skip the boundary); Morph's render dropping all tool semantics; token
hot-rotation not dropping live connections; `LLM::Service` lacking a real
`reconfigure`; unbounded `set_policy` patterns; AllowList failing open on an
unknown session; `attach` raising instead of answering an error frame.

**Recorded, not fixed (deliberate, in §14):** at-least-once ambiguous-commit
window (side effect before `tool/result` — documented contract; idempotency
keys are M7+); resume-after-final-assistant re-requests (documented edge);
logged policy replacing the boot floor (the confirmed replay-survives-restart
design); no park timeout + idle agents never auto-disposed (cap is the honest
backstop; lifecycle policy is M7/M8); `register` recording effects on the root
ctx (pre-existing); `Sessions#@cache` never evicting; cost accounting omitting
utility-call usage; O(events) policy scans; `reconfigure!` non-atomicity on a
raising hook; `set_policy` carrying the connection's full authority.

## Design decisions already made (do not relitigate mid-task)

- **Approvals are an opt-in row.** The gate lives on `tools/execute` (pre_execute vetoes settle first); denial renders as an error `Result`; no timeouts (cancel denies durably). The WS layer guards every approvals reference behind `service?(:approvals)` and answers `unsupported` without the row.
- **Autonomous profiles run policy-as-code**: deny-by-default allow lists, hot-reloadable through durable `policy/updated` events — last one wins, install patterns are only the floor, replay rebuilds policy after a restart. A denied call is an error result the model reacts to.
- **The reconfigure contract**: wholesale config replace (like layering, never a merge); `Service#reconfigure` re-derives captured knobs; the default implementation warns; `config/updated` emits when declared (hames stays app-agnostic). Knobs read per call are live by construction and say so in a comment.
- **Resume triggers on stimulus**: a wake on an idle agent with an open turn resumes it (text rides as `context/injected`); a verdict for an idle agent with an open turn resumes it. No spontaneous resume on boot.
- **Crash recovery is at-least-once** for tool calls; idempotency is the tool's concern. Stated in docs, not hidden.
- **The summarizer is a sole-provider seam** (`ctx[:summarizer]`), like the session store. RoleSummarizer (core, no signup) raises on misconfiguration; Morph (terret-morph, agora's wire verbatim: `/v1/compact`, bearer key, `{input, compression_ratio, preserve_recent: 0}` → `{"output": String}`) declines to nil on every failure. The Compactor treats nil as "skip, warn, retry next overweight turn".
- **Compaction always compacts the whole prefix** (`upto_seq` = immediately preceding seq, computed at append time). Retention is a summarizer concern.
- **`Thread::Queue` is the parking primitive**; the wake race requeues, never drops; one live agent per session, cap 128, dispose only idle.
