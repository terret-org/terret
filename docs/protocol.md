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
  `unauthorized` and is closed. Revocation reaches connections already open:
  rotating a token drops every live connection that presented the old one,
  with the same `unauthorized` frame it would have got at the door.
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
- `{"type":"replay_truncated","requested_from_seq":0,"from_seq":5001}` — sent
  when a `subscribe` reached further back than the server's `replay_limit`
  (below). `requested_from_seq` is what the client asked for; `from_seq` is the
  seq its replay actually begins at. The client is missing everything in
  `[requested_from_seq, from_seq)` and must not treat this stream as holding it.
  Sent before that window's first event, so a client that sees it knows its
  first replayed event is not the one it asked for.
- `{"type":"error","code":"...","message":"..."}` — codes:
  - `unauthorized` — bad or missing token; connection closes.
  - `superseded` — a newer connection took over this agent; connection closes.
  - `lagged` — the client read too slowly and its outbound queue overflowed;
    connection closes. Resubscribe from your last durable seq.
  - `bad_frame` — unparseable or invalid client frame; connection stays open.
  - `not_running` — `cancel` arrived while no turn was running; stays open.
  - `stale_call` — `approve`/`deny` named a call with no standing approval
    request (already resolved, never requested, or a typo); nothing is
    appended and the connection stays open.
  - `unsupported` — the frame needs a plugin this deployment does not mount
    (`approve`/`deny` without the approvals row); stays open.
  - `internal` — the server hit an unexpected error serving this connection;
    connection closes. Resubscribe from your last durable seq.

## Client → server

The closed set from plan §9.2. Anything else is answered with `bad_frame`.
Frames larger than 1 MiB are rejected as `bad_frame`.

| Frame | Fields | Lands on |
|---|---|---|
| `subscribe` | `from_seq` (int ≥ 0, required) | `sessions.read(sid, from_seq:)`, then live tail |
| `inject` | `text` (required), `wake` (bool, default false) | `agent.inject` / the loop |
| `cancel` | `reason` (optional) | `agent.cancel`, plus durable denials when parked |
| `approve` | `call_id` (required) | durable `approval/resolved` (validated) |
| `deny` | `call_id` (required), `reason` (optional) | durable `approval/resolved` (validated) |
| `set_model` | `role` (required), `model` ("provider/model", required) | the live model-role table |
| `set_policy` | `patterns` (array of strings, required) | durable `policy/updated` (§6.3 AllowList) |

### subscribe — replay-then-tail

`from_seq` is the first seq the client wants, **inclusive**. A fresh client
sends 0. A reconnecting client sends `<highest seq it has durably recorded> + 1`.
The server replays the log from `from_seq` and then tails live dispatch, with
no gap and no duplicate — exact, not best-effort, because seq is gapless and
the log is append-only. Subscribing again replaces the previous subscription
(the tail is re-established from the new `from_seq`).

Resubscribing mid-stream replaces the subscription server-side, but frames
from the replaced subscription that were already queued or in flight may
still arrive before the new replay's first event — that is inherent to a
full-duplex transport, not a server defect. A client that resubscribes
mid-stream should discard incoming events until it sees `seq == from_seq`
(the first event of its new replay).

**Replay is capped.** A single `subscribe` never triggers an unbounded
history read. The server bounds one reconnect's replay at `replay_limit`
events (config, default 10000): a `from_seq` reaching further back than that
many events behind the tip is pulled forward to the newest `replay_limit`
window, and the server sends a `replay_truncated` frame (above) naming the seq
the replay actually starts at *before* that window's first event. The
replayed window is still gapless and duplicate-free and tails live with no
gap — the cap moves only where the window *starts*, and that move is always
signaled, never silent. A client that needs the skipped history must read it
from a durable store out of band; the socket will not resend it. So a
reconnecting client that has been away a long time should expect its
subscribe to be capped rather than assume it can recover the whole log over
the wire.

**Concurrent replays are capped.** Across all connections the server runs at
most `max_concurrent_replays` replay reads at once (config, default 4). A
reconnect storm — the predictable failure mode after a deploy — therefore
does not become N simultaneous log reads; surplus connections wait their turn
for a replay slot (the connection is held open, not rejected) and proceed as
slots free. Only the log read is gated, not the live tail, so a slow client
draining its replay never holds a slot away from another reconnect. Combined
with jittered client backoff, this keeps a thundering herd off the store.

### inject

`wake: true` on an idle agent starts a turn with `text` as its input. On a
busy agent (or with `wake: false`) the text is queued in the agent's inbox and
rides into the next step of the current or next turn — that is the mid-turn
steer. Injection is acknowledged by the log itself, and the event type records
which of the two it was: the waking text that starts a turn lands as that
turn's own durable `user/message`, while a steer drained from the inbox lands
as durable `context/injected`. Both project into model history as user
messages; the distinction is provenance, kept because the log is the record of
what actually happened.

If the log holds an **open turn** (a `turn/start` with no `turn/end` after it —
the process died mid-turn, or was deployed over), `wake: true` on an idle agent
**resumes that turn** rather than starting a new one: no second `turn/start`,
the tool calls the open step still owes are executed, and the wake text rides
the resumed turn's next step as `context/injected`. Any stimulus resumes; an
approval verdict is not required.

No wake is ever dropped. Two `wake: true` frames arriving in one read burst can
both find the agent idle before either turn starts; the loser's turn refuses,
and its text is requeued into the inbox to ride the winner's next step. A
client therefore never has to detect or retry a lost wake.

### cancel

Requests a cooperative stop of the running turn. The loop honors it at step
boundaries: a cancel that races a tool result loses the race to the log entry
but wins the turn — the `tool/result` is recorded, then the turn closes with
`turn/end {status: "cancelled", reason: ...}`. A cancel with no turn running
is answered `not_running`.

A cancel observed part-way through a step's tool batch truncates the rest of
that batch: every remaining call in it still logs its `tool/call` and a
`tool/result` carrying the error `cancelled before execution`, so nothing runs
but the projection never holds a call without a result.

The M8 tool barrier moves where that truncation can land without changing the
guarantee. Calls declared `concurrency: :parallel` execute in maximal runs
under one barrier (docs/subagents.md §5), and a run is not interruptible from
outside once it starts — so a cancel is observed *between* runs rather than
between individual calls, and a batch cancelled mid-run produces fewer
`cancelled before execution` results than the same batch would have before the
barrier existed. Every call in the batch still ends with a `tool/result`
either way.

`turn/end`'s `status` is one of `completed`, `cancelled`, `rejected`, `empty`,
or `failed` (see docs/lifecycle.md, "The status machine"). A failed *resume*
is the one case that logs no `turn/end` at all: it leaves the turn open so the
next stimulus can pick it up.

A turn parked on an approval also cancels: the turn is marked cancelled first,
then every standing request for the session is denied durably (one
`approval/resolved {verdict: "denied", reason:}` each) so the parked call
unparks into a turn that already knows it is stopping. The `reason` carries
through to both the denials and `turn/end`.

### approve / deny

Resolves a parked tool call. Approvals are an **opt-in plugin row**: where it
is not mounted, nothing ever parks and both frames answer `unsupported`.

Where it is mounted, a tool whose definition demands a decision parks inside
the tools pipeline and the server appends durable `approval/requested`
`{call_id:, name:, args:}`. A verdict appends durable `approval/resolved` with
`{call_id:, verdict: "approved"|"denied", reason?:}`, which unparks the call —
approved runs it, denied returns an error result to the model. `call_id` is the
`id` of the corresponding `tool/call` event; it is named `call_id` rather than
`id` because inside an approval payload a bare `id` would read as the
approval's own identifier, not the call it references.

Verdicts are validated against the log, not taken on faith: only a `call_id`
with a standing request and no verdict yet is accepted. Anything else — an
already-resolved call, a call that never asked, a typo — answers `stale_call`
and appends nothing, so a double approve cannot pollute the log. "Standing"
means within the **open turn**: a request whose turn has since closed is
settled, and a verdict arriving for it answers `stale_call` too. Provider
tool call ids are not contractually unique, so a decision never carries
across a turn boundary.

Both sides being durable is what survives a process death. If the server
restarted while a call was parked, no fiber is waiting when the verdict lands;
the server sees an idle agent with an open turn in the log and resumes the
turn, which re-executes the owed call and finds the recorded verdict instead of
parking again (see docs/lifecycle.md, "Durable approvals" and "Resuming an open
turn").

### set_model

Repoints a model role (`main`, `titler`, ...) at a `provider/model` spec on
the live service. Takes effect at the next step. Invalid specs get `bad_frame`.

### set_policy

Replaces the agent's active tool allow list with `patterns` (a list of
`File.fnmatch` globs). Appends durable `policy/updated {patterns}` — the
last one appended wins, it is effective on the very next tool call with no
reinstall, and it survives a restart because replay rebuilds it (see
docs/lifecycle.md, "Hot-reloadable permissions"). `patterns` must be an
array of strings; anything else gets `bad_frame` and nothing is appended. It
is bounded at 128 patterns of at most 256 characters each — the set is
durable and every later tool call scans it — and a frame over either bound
gets `bad_frame` with nothing appended.

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
