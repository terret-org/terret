# The Terret Socket Protocol (v1)

The v1 interface to a Terret agent is one WebSocket per agent (plan §9). This
document is the wire contract for `terret-ws`. The protocol invents no session
vocabulary: everything the server sends about a session IS the durable session
log, event by event. If it isn't in the log, it doesn't reach a client.

## Connection

- URL: `GET /agents/{agent_id}/ws` (WebSocket upgrade).
- Auth: `Authorization: Bearer <token>`, checked before the agent is resolved.
  Tokens are scoped per agent id; a token for one agent cannot open another's
  stream. An unauthorized connection receives one `error` frame with code
  `unauthorized` and is closed.
- In v1 the agent id names the session: connecting to `{agent_id}` resumes the
  session with that id, or creates it on first connect.
- One connection per agent. A second authorized connection for the same agent
  supersedes the first, which receives `error` code `superseded` and is closed.
  (A half-open connection after a network blip must not block reconnection.)
- Heartbeat: the server sends WebSocket ping frames on an interval (default
  20s, configurable) so load-balancer idle timeouts do not reap healthy
  connections. Clients need not act; WebSocket libraries answer pongs.

All frames in both directions are JSON text frames, one object per frame.

## Server → client

Two frame families, distinguished by the `seq` key: session events have it,
protocol frames never do.

**Session events** — the durable envelope serialized as-is:

    {"id":"5f2c...","session_id":"s1","seq":7,"at":"2026-08-18T04:10:11.123456Z",
     "type":"assistant/chunk","payload":{"text":"22C"}}

`seq` is a per-session monotonic integer starting at 0, gapless. `at` is UTC
ISO8601 with microseconds. Event types and payloads are the durable set in
`docs/events.md`; new durable events flow through automatically.

**Protocol frames:**

- `{"type":"hello","proto":1,"session_id":"s1","last_seq":41}` — sent once on
  connect, before anything else. `last_seq` is the highest seq in the log at
  that moment (`session/created` guarantees at least 0). Nothing streams until
  the client subscribes.
- `{"type":"error","code":"...","message":"..."}` — codes:
  - `unauthorized` — bad or missing token; connection closes.
  - `superseded` — a newer connection took over this agent; connection closes.
  - `lagged` — the client read too slowly and its outbound queue overflowed;
    connection closes. Resubscribe from your last durable seq.
  - `bad_frame` — unparseable or invalid client frame; connection stays open.
  - `not_running` — `cancel` arrived while no turn was running; stays open.
  - `internal` — the server hit an unexpected error serving this connection;
    connection closes. Resubscribe from your last durable seq.

## Client → server

The closed set from plan §9.2. Anything else is answered with `bad_frame`.
Frames larger than 1 MiB are rejected as `bad_frame`.

| Frame | Fields | Lands on |
|---|---|---|
| `subscribe` | `from_seq` (int ≥ 0, required) | `sessions.read(sid, from_seq:)`, then live tail |
| `inject` | `text` (required), `wake` (bool, default false) | `agent.inject` / the loop |
| `cancel` | `reason` (optional) | `agent.cancel` |
| `approve` | `call_id` (required) | durable `approval/resolved` |
| `deny` | `call_id` (required), `reason` (optional) | durable `approval/resolved` |
| `set_model` | `role` (required), `model` ("provider/model", required) | the live model-role table |

### subscribe — replay-then-tail

`from_seq` is the first seq the client wants, **inclusive**. A fresh client
sends 0. A reconnecting client sends `<highest seq it has durably recorded> + 1`.
The server replays the log from `from_seq` and then tails live dispatch, with
no gap and no duplicate — exact, not best-effort, because seq is gapless and
the log is append-only. Subscribing again replaces the previous subscription
(the tail is re-established from the new `from_seq`).

### inject

`wake: true` on an idle agent starts a turn with `text` as its input. On a
busy agent (or with `wake: false`) the text is queued in the agent's inbox and
rides into the next step of the current or next turn — that is the mid-turn
steer. Injection is acknowledged by the log itself: the text appears as a
durable `user/message` when it lands in a step.

### cancel

Requests a cooperative stop of the running turn. The loop honors it at step
boundaries: a cancel that races a tool result loses the race to the log entry
but wins the turn — the `tool/result` is recorded, then the turn closes with
`turn/end {status: "cancelled", reason: ...}`. A cancel with no turn running
is answered `not_running`.

### approve / deny

Appends durable `approval/resolved` with
`{call_id:, verdict: "approved"|"denied", reason?:}`. `call_id` is the `id`
of the corresponding `tool/call` event — it is named `call_id` rather than
`id` because inside an approval payload a bare `id` would read as the
approval's own identifier, not the call it references. In M4 nothing parks
on it yet — the resolution machinery is M6 — but the event is contract now,
and subscribers see it like any other durable event.

### set_model

Repoints a model role (`main`, `titler`, ...) at a `provider/model` spec on
the live service. Takes effect at the next step. Invalid specs get `bad_frame`.

## Liveness

The agent's life is independent of the socket. A dropped connection never
cancels a turn: work continues, events accumulate in the log, and a
reconnecting client catches up via `subscribe`. Only an explicit `cancel`
frame stops a turn.

## Backpressure

Outbound events go through a bounded per-connection queue. Session dispatch
never blocks on a slow socket: when the queue overflows, the client is dropped
with `lagged` rather than allowed to stall the loop. Reconnect-then-replay and
snapshot-then-tail are the same mechanism, so recovery is one `subscribe`.
Replay is flow-controlled: the server waits for the client while replaying
history, so a long log never looks like a slow reader. Only the live tail is
drop-eligible.

## Versioning

`hello.proto` is 1. Additive changes (new durable event types, new optional
fields) do not bump it; changes to frame semantics do.
