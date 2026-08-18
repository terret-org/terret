# Turbo Web Chat: Design

**Status:** Approved 2026-08-17
**Type:** Dogfooding tool, demo-grade
**Artifact:** `examples/web_chat.rb`, one file

## Purpose

An interactive browser session against a Terret agent: type a message, watch the reply
stream in, see tool calls and cost as they happen. This is a dogfooding tool, not the
real web console. The plan (§9.5) defers a production web console until it can ride the
`terret-ws` socket; this demo consumes `session/event` in-process instead, which the
plan sanctions ("a second consumer of the same event stream"). It can be discarded or
rebuilt on the socket later without ceremony.

## Goals

- Chat with an agent through a real model (OpenRouter adapter) from a browser.
- Render tool calls, tool results, and per-step usage/cost inline in the transcript.
- Prove two architectural claims incidentally:
  1. Replay-then-tail (§9.3): a page refresh reconstructs the entire transcript from
     the session log alone, then tails live. No UI-side state survives a refresh.
  2. The adapter's `Sync{}` reuses a running reactor: turns run inside Async tasks on
     the server's reactor, exercising the in-reactor path for the first time.

## Non-Goals

- Not the production web console; no gem, no plugin packaging, no auth.
- No mid-turn steering, cancellation, approvals, or multi-session UI.
- No queueing of messages while a turn runs (input disables instead).
- No test suite (examples convention); verified live in a browser before done.

## Stack

- **Server:** `Async::HTTP::Server` from `async-http` — already a dependency of
  `terret-openrouter`, so zero new gems. This is the agreed refinement within the
  "Falcon + async" direction: Falcon is the same socketry stack plus Rack packaging,
  which a four-route demo does not need.
- **Client:** turbo.js ES module from CDN (`@hotwired/turbo@8`). One
  `Turbo.connectStreamSource(new EventSource("/events"))` call plus a minimal inline
  fetch handler for the form. Inline CSS. No build step.
- **Boot:** same plugin layering as `examples/openrouter_demo.rb` (sessions, prompt,
  tools, llm, loop, openrouter plugin), demo weather tool, identity prompt section,
  model from `TERRET_MODEL` (default `openai/gpt-5-mini`), aborts without
  `OPENROUTER_API_KEY`. Binds `http://localhost:9292` (override with `PORT`).

## Architecture

```
browser ──GET /──────────► static page (empty transcript, turbo.js, EventSource)
browser ──GET /events────► SSE: render every event in the log, then tail live
browser ──POST /messages─► 409 if busy, else Async task: loop.run_turn(agent, text)
browser ──POST /session──► fresh session+agent, broadcast transcript clear
```

Components, all in the one file:

- **AgentHost** — owns the current session and agent; `reset!` swaps in fresh ones
  (new-session button); a busy flag serializes turns (single reactor, no locks needed:
  flag set/checked without intervening awaits).
- **Renderer** — turns a `SessionEvent` into `<turbo-stream>` HTML (or nil for events
  with no visual). Holds exactly one piece of state: the current step's DOM id,
  derived from the `step/start` event's seq, so `assistant/chunk` appends target the
  right bubble. Replaying the log through a fresh renderer reproduces the transcript.
  All text passes through `CGI.escapeHTML`.
- **Hub** — fan-out of rendered HTML to per-connection `Async::Queue`s. A `session/event`
  listener renders and pushes. SSE handlers snapshot the log and subscribe atomically
  (no await between the two, so no gap and no duplicate), replay the snapshot through
  the renderer, then drain the queue.

## Event rendering map

| Durable event | Turbo action |
|---|---|
| `session/created` | clear the transcript container |
| `user/message` | append user bubble |
| `step/start` | append empty assistant bubble (id from seq) |
| `assistant/chunk` | append text into current assistant bubble |
| `assistant/message` | nothing (chunks already rendered) |
| `tool/call` | append tool invocation line |
| `tool/result` | append result line, error-styled when `error` present |
| `step/end` | append usage badge (tokens + cost) when usage present |
| `turn/start` | disable the input (replace form state) |
| `turn/end` | re-enable the input, show turn status |

SSE framing: rendered HTML is multi-line; each line must be written as its own
`data:` line within one SSE event (the spec rejoins them with `\n`).

## Error handling

- A turn that raises (e.g. `AdapterError` after retries) is rescued in its Async task;
  an ephemeral error line is broadcast to connected pages and the input re-enables.
  Deliberately **not** appended to the session log — the log holds model-visible truth
  only.
- `POST /messages` while busy → 409 with a plain message (belt and braces; the input
  is disabled anyway).
- A closed SSE connection is dropped from the hub on write failure.

## Verification

Run against a real key; confirm in a browser: streaming text, tool call/result lines,
usage badge, input disable/re-enable, page refresh reproducing the full transcript,
two tabs receiving the same stream, and the new-session button clearing both tabs.
