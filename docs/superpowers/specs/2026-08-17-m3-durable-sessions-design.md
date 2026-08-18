# M3 Durable Sessions: Design

**Status:** Approved 2026-08-17
**Milestone:** Plan §12 M3 — SQLite store, `read(session_id, from_seq:)`, load-and-replay
resume, session fork. Plus the compaction event decision (§16 item 1) and a session
sidebar in the web chat as the visible payoff.

## Goal

The append-only log survives the process, exactly. Acceptance (plan §12): a session
survives a restart and resumes with a byte-identical `derive_messages` digest, and a
replay from an arbitrary `seq` yields the same events as a live tail from that point.

## Non-Goals

- Per-session `stream()` queues (M4 owns the consumer).
- The per-session writer-task pattern from §8 (throughput optimization; appends are
  synchronous in M3).
- The compactor itself (M6). M3 ships only the `session/compacted` event declaration,
  its projection, and tests.
- Per-browser-tab sessions in the web chat (real-console territory; the demo keeps one
  globally active session).

## 1. The primitives contract

`Sessions#append` becomes an enforcement point. Payload values may be: String, Integer,
Float, true/false, nil, Array of allowed values, Hash with Symbol keys of allowed
values. Symbols in value position are coerced to strings at append (callers keep
writing `status: :failed`; the log stores `"failed"`). Hash keys that are strings are
coerced to symbols; a key collision after coercion raises. Any other object raises
`Terret::NonPrimitivePayload`.

Consequence: `JSON.parse(JSON.generate(payload), symbolize_names: true) == payload`
holds for every stored payload — the property the restart digest rests on. Existing
tests asserting symbol statuses (`:failed`, `:rejected`) update to strings.

## 2. Typed parts at the edges

A part codec in `Terret::LLM` (module functions):

| Data type | Stored form |
|---|---|
| `Text` | `{type: "text", text:}` |
| `ToolCall` | `{type: "tool_call", id:, name:, args:}` |
| `ToolResult` | `{type: "tool_result", id:, content:, error:}` |

`LLM.encode_part(part)` / `LLM.decode_part(hash)`; decode raises on unknown type.
Storage names are deliberately not Ruby class names, so a class rename never
invalidates stored logs. The loop appends `assistant/message` with encoded parts;
`derive_messages` decodes them back to `Data` objects for adapters. The log-invariant
digest stays consistent because both sides project through the same decode.

## 3. The store seam

New service key `ctx[:session_store]`; `Sessions` declares `inject :session_store`,
which makes the row REQUIRED: every existing boot (both demos, both test harnesses,
the web chat) gains an explicit `{ id: "session_store", plugin: Terret::Store::Memory }`
row rather than Sessions hiding a default — declaring `inject` accurately is the
repo's stated convention, and the visible row is what makes the swap story real.
Provider API (all take/return `SessionEvent` with primitive payloads):

- `append(event)` — durably record one event
- `read(session_id, from_seq: 0)` — events with `seq >= from_seq`, in order
- `session_ids` — every known session id

Providers:

- **`Terret::Store::Memory`** (terret-core) — Hash of arrays; the test default.
- **`Terret::Store::JSONL`** (terret-core) — one `{session_id}.jsonl` per session in a
  configured directory; envelope serialized as one JSON object per line (`at` as
  ISO8601 with microseconds, `iso8601(6)`, so Time round-trips exactly; payload as
  JSON). Replaces the current broken `payload.inspect` side-write, which is removed.
  SQLite stores `at` the same way.
- **`Terret::Store::SQLite`** (new gem `gems/terret-store-sqlite`, dependency
  `sqlite3` ~> 2.9 — verified working on Ruby 4.0.6) — WAL mode, `busy_timeout`,
  table `events(session_id TEXT, seq INTEGER, id TEXT, at TEXT, type TEXT,
  payload TEXT, PRIMARY KEY (session_id, seq))`. Synchronous appends.

`Sessions` keeps in-memory `Session` structs as the working set and writes through, so
`session.events` callers don't churn. Sessions API additions: `read(session_id,
from_seq:)` (public replay primitive, delegates to the store), `resume(session_id)`
(load events from the store, rebuild the in-memory session, continue appending after
the last seq), `session_ids`. `fork` stays in Sessions, implemented once as
read-copy-append — no per-provider fork.

## 4. The compaction event (decided now, built in M6)

Declared durable: `session/compacted`, payload `{upto_seq:, summary:}`. Projection in
`derive_messages`: events with `seq <= upto_seq` drop out of the projection; the
summary renders as a user message in their place. When multiple compaction events
exist, the latest one wins (its `upto_seq` governs; earlier compaction events are
themselves dropped like any other superseded history). Compacted history is still
model-visible, so it lives in the log (§2.5). The event is declared and projected in
M3 so the durable vocabulary is closed before stored bytes harden; nothing emits it
until M6.

## 5. Web chat: session sidebar

The demo grows a ChatGPT-style left nav and gains real persistence:

- **Store row:** the sessions boot layering gains
  `{ id: "session_store", plugin: Terret::Store::SQLite, config: { path: "tmp/web_chat.sqlite3" } }`
  (directory created at boot if missing).
- **Sidebar:** a fixed-width left nav (`#sessions`) listing every session, most recent
  activity first, active session highlighted. Label: the session's first
  `user/message` text truncated to ~40 chars, else the short session id. Each entry is
  a `data-turbo="false"` form (`POST /session/select`, hidden `id` input) — the
  existing delegated submit handler covers it with zero new JS.
- **Selection:** `POST /session/select` — 409 while a turn runs; otherwise
  `AgentHost#select!(id)` resumes that session (fresh agent bound to it) and
  broadcasts to ALL connections: transcript clear, full replay of the selected
  session through a fresh Renderer, a sidebar update, and an authoritative composer
  frame reflecting actual `busy?` state. The composer frame also covers logs that end
  mid-turn (killed process): replay would leave the composer disabled; the
  authoritative frame corrects it.
- **New session** (existing button) now also broadcasts a sidebar update; old sessions
  remain on disk and reappear in the list.
- **SSE connect replay** sends: active session's rendered events, then one sidebar
  frame, then one authoritative composer frame.
- Restarting the server now reattaches to the most recently active stored session
  (or creates one if the store is empty) — conversations survive restarts.

Sidebar rendering is a separate helper (cross-session state derived from store
queries), not part of the per-session Renderer, which stays replay-pure.

## 6. Testing

- **Restart digest (the acceptance):** write a multi-step tool session through a
  SQLite store on a real file; open a FRESH store instance + Sessions on the same
  file; `resume`; assert the `derive_messages` digest is byte-identical, and a new
  turn appends after the last seq.
- **Replay-vs-tail equivalence:** collect `session/event` live from seq n while also
  calling `read(session_id, from_seq: n)`; the sequences must be identical.
- **Codec:** round-trip every part type; unknown type raises; append rejects
  non-primitive payloads; symbol-value coercion verified.
- **JSONL:** full envelope round-trip through a file.
- **Fork:** lineage and boundary copy through a durable store.
- **Compaction projection:** a hand-appended `session/compacted` drops prior events
  from the projection and injects the summary; digest stable across store reload.
- Store providers share one behavioral test module run against all three.
- Web chat verification (live, browser): restart-resume, sidebar list/labels/order,
  click-to-load in two tabs, 409 while busy, new-session still works.

## 7. Sequencing note

Core work lands first (codec → append contract → seam + providers → resume/fork →
compaction projection), each green against the full suite; the web chat sidebar comes
last, consuming only public Sessions API. CLAUDE.md, plan §12 status, and the events
catalog (new durable event) update at the end.
