# Terret over ACP (v1)

> **This document matches ACP v1.** `protocolVersion` is the integer `1`,
> schema-verified against `agentclientprotocol/agent-client-protocol`
> `schema/v1`, whose last edit at the time of writing was 2026-07-27. A
> `schema/v2` exists and is explicitly **draft**: it moves prompt
> completion into notifications, removes the client-side fs and terminal
> methods, and renames `authenticate` to `auth/login`. Terret builds
> against v1 and does not implement v2. The implementer of the
> `terret-acp` gem re-verifies every name and shape against the live spec
> at build time and corrects this document in the same commit if anything
> has moved. This document's own claim, not borrowed from the spec, is
> the mapping: which Terret seam each operation lands on, and what is
> deliberately not implemented.
>
> **M8 verification (2026-08-19).** Re-checked against `schema/v1/schema.json`
> and agentclientprotocol.com: every wire fact below matched the digest, so
> nothing needed correcting. The server reports `protocolVersion` **1** (an
> integer). `schema/v2` exists and is draft; it is not built.

## What ACP is

The Agent Client Protocol is **Zed's**. Zed introduced it as the contract
between an editor and a coding agent, and it is now stewarded in its own
`agentclientprotocol` organization since the repository moved out of
`zed-industries`. The wire is **JSON-RPC 2.0 over stdio**,
newline-delimited: the **client spawns the agent as a subprocess** and
speaks to it over that process's stdin and stdout. An editor that speaks
ACP can drive any agent that speaks it, and an agent that speaks it gets
every such editor for free.

Terret now sits on both sides of an interop story that uses similar words
for opposite things, so the direction matters (plan §6.8):

- **MCP** makes tools available **to** an agent. Terret is the *client*;
  a server's tools mount as `mcp__<server>__<tool>` behind `ctx[:tools]`
  (docs/mcp.md).
- **ACP** makes an agent available **to** an editor. Terret is the
  *server*; an editor drives `ctx[:loop]`, the agent registry.

`terret-acp` is the second one only. The ACP *client* direction (Terret
delegating a turn to some other agent over ACP) is a subagent provider
and is deferred (below).

## Why it is a gem, and what it proves

`terret-acp` is an interface plugin, exactly like `terret-ws`: it consumes
`session/event` and drives the agent registry, and it holds no session
vocabulary of its own. That is the point of building it at all beyond the
editors it unlocks. The claim in plan §1 is that everything is a plugin
and the interface is not privileged; the standing proof of that claim was
one interface (plan §9.1). A second interface, on a completely different
transport, built out of the same two seams with no change to core, is what
turns a claim into evidence.

The consumption pattern is copied from
`gems/terret-ws/lib/terret/ws/connection.rb` (docs/protocol.md). The
transport is the only new thing.

## Requests, notifications, and the mapping

ACP distinguishes requests (carry an `id`, expect a response) from
notifications (no `id`, no response), and getting that wrong is the
classic way to hang an editor. The baseline an agent must implement is
`session/new`, `session/prompt`, `session/cancel`, and sending
`session/update`.

| ACP operation | Kind | Terret |
|---|---|---|
| `initialize` | request | capabilities handshake against the booted context |
| `session/new` | request | `spawn_agent` on a fresh durable session; answers `{sessionId}` |
| `session/prompt` | request | `run_turn`, streaming `session/update`; **stays pending for the whole turn** and answers `{stopReason}` |
| `session/cancel` | notification (client → agent) | `Agent#cancel`, the same method the socket's `cancel` frame calls; the pending prompt then answers `cancelled` |
| `session/update` | notification (agent → client) | projected from `session/event` |
| `authenticate` | request, optional | never reached (below) |
| `session/load` | request, optional, capability-gated | not advertised in v1 (below) |

### `initialize`

```json
// params
{"protocolVersion": 1,
 "clientCapabilities": {"fs": {"readTextFile": true, "writeTextFile": true}, "terminal": true},
 "clientInfo": {"name": "…", "version": "…"}}
// result
{"protocolVersion": 1, "agentCapabilities": {…}, "authMethods": []}
```

`protocolVersion` is the only required field on either side, and it is an
**integer**, not a version string. `authMethods: []` is how a no-auth
agent says so, and it is what Terret answers (see "deliberately absent").

The handshake reports **what this boot mounts**, not what the gems can
do. A Terret boot is a profile (docs/composition.md), so two deployments
of the same code report different capabilities depending on which rows
are mounted, such as approvals or sandboxing. The idiom for "unsupported"
is to **omit an optional capability group entirely**. Sending it with
every field false is the wrong shape, and it suits a report derived from
a row list: a group is present because a row is.

### `session/new`

Params require `cwd` and `mcpServers` (the latter may be `[]`); the result
is `{sessionId}`. Terret spawns a real agent with the ordinary lifecycle.
The registry's cap applies (`AgentCapExceeded` at 128, docs/lifecycle.md),
and the session is durable, titled, and cost-accounted like every other
session. An editor session is not a lightweight second-class thing. It is
the same object the socket would have connected to.

Both required parameters are places where a protocol field meets a Terret
invariant, and neither resolves in the protocol's favor:

- **`cwd` is a request, not an authority.** Filesystem reach is the
  `workspace:` config row, realpath-contained, deny-by-default, with an
  empty list denying everything (docs/exec.md §3). A client-supplied
  directory does not widen it. Whether the server then *uses* `cwd` as a
  working directory inside an already-granted workspace or ignores it
  entirely is deferred to the implementer (open item 2 below), but it
  cannot grant reach the profile did not.
- **`mcpServers` is accepted and not mounted in v1.** Honoring an empty
  list is trivial; mounting servers the editor names would let a client
  extend the agent's tool roster past the profile's floor, which is the
  same escalation `ctx[:subagents]` refuses by construction
  (docs/subagents.md §3). If it lands later it lands as policy (the
  allow list and per-server approval that docs/mcp.md already defines),
  not as an unconditional mount.

### `session/prompt`

Params are `{sessionId, prompt: ContentBlock[]}`; the baseline blocks to
accept are `{"type": "text", …}` and `{"type": "resource_link", …}`.
`ContentBlock` discriminates on `type` while a session update
discriminates on `sessionUpdate`. The two are easy to conflate, and the
spec uses both.

The request **stays pending for the entire turn** and answers
`{stopReason}` when the turn closes. That is a natural fit for the loop:
one `run_turn` call, one response.

It branches on resumability. A session whose log holds a `turn/start` with
no `turn/end` is resumable, and `run_turn` on it raises `TurnOpenInLog` by
design (docs/lifecycle.md, "Resuming an open turn"). Every caller that can
meet a session someone else was driving has to branch (inject then
`resume_turn`, or `run_turn`), and the socket already does. ACP is exactly
such a caller: an editor reopening a project is the canonical way to meet
a turn that a killed process left open.

### `session/cancel`

A **notification**, so there is no response to it. On receipt Terret calls
`Agent#cancel`, the existing method that also drives the socket's `cancel`
frame (docs/protocol.md); no ACP-specific cancel entry point is minted.
Terret then flushes pending `session/update` notifications and answers the
still-pending `session/prompt` with `stopReason: "cancelled"`.

Cancellation is cooperative and lands at the next step boundary. It does
not tear a fiber out of a running tool call; a barrier of parallel calls
settles first (docs/subagents.md §5). The `:stopping` status exists to
make that interval observable. Without it, a cancelled agent would
report `:running` while it winds down, and the turn closes with the
ordinary durable `turn/end {status: "cancelled"}`.

## `session/update`: a projection of the log

The same rule that governs the socket governs this: **nothing reaches a
client that is not in the log first**. Notifications are derived from
`session/event` and from nothing else, so the ACP server invents no
vocabulary and adds no second source of truth.

Params are `{sessionId, update}`, and the update discriminates on the
field **`sessionUpdate`**, not `type`.

| durable event | `sessionUpdate` | note |
|---|---|---|
| `assistant/chunk` | `agent_message_chunk` | `{content: {type: "text", …}}` |
| `tool/call` | `tool_call` | `toolCallId`, `title`, `kind`, `status: "pending"` |
| `tool/result` | `tool_call_update` | same `toolCallId`, terminal `status`, content |

`tool_call`'s `kind` is an enum (`read`, `edit`, `delete`, `move`,
`search`, `execute`, `think`, `fetch`, `switch_mode`, `other`), and the
std roster maps onto it cleanly enough that the table is mechanical:
`Read` is `read`, `Glob` and `Grep` are `search`, `Write` and `Edit` are
`edit`, `Bash`/`job_*`/`terminal_*` are `execute`, `WebFetch` is `fetch`.
`Task` and MCP tools have no obvious member and fall to `other`. The
`status` enum is `pending | in_progress | completed | failed`, which is why
one Terret event opens the call and a second closes it. No single event
carries both.

Those three are the whole of what v1 emits. Eight further variants exist
in the schema and none of them are sent:

`agent_thought_chunk` has no source to project from, and that gap runs
deeper than a missing event: **Terret has no thinking part at all.** The
LLM vocabulary is `Text`, `ToolCall`, and `ToolResult` (plan §6.5 lists a
`Thinking` part; the code does not have one), so reasoning content is
neither logged nor projected anywhere today. If it ever is (a part, then an
event), this is where it would surface. `plan` carries a full entry list
that it **replaces on every update**, which happens to be exactly
`TodoWrite`'s contract (docs/subagents.md §7) and makes that tool its
natural future source. Mapping the two is a later idea. M8 does not owe
it. The remaining six (`user_message_chunk`,
`available_commands_update`, `current_mode_update`, `config_option_update`,
`session_info_update`, and `usage_update`) have no Terret consumer.

There is one honest difference from the socket. `terret-ws` serializes the
durable envelope **as-is**, so a client can reconstruct the session exactly
and replay-then-tail is byte-exact (docs/protocol.md). ACP notifications
are a **lossy view**: the protocol has shapes for the things an editor
renders, and Terret has durable events with no ACP shape at all:
`approval/requested`, `policy/updated`, `session/titled`,
`session/compacted`, every `step/*` and `turn/*` bookend. Those simply do
not project. An ACP client therefore cannot rebuild a session from what it
received, and it is not supposed to; the socket is what that is for, and
both can be mounted against the same agent.

Chunk fidelity carries one inherited caveat: with a redactor mounted, the
loop coalesces each run of assistant text into a single `assistant/chunk`
at run end. It does not stream delta-by-delta (docs/exec.md §6). An ACP
client of a redacting deployment sees text arrive in bursts. That is the
redaction trade, not the transport's.

## Stop reasons

ACP defines exactly five: `end_turn`, `max_tokens`, `max_turn_requests`,
`refusal`, `cancelled`. Terret closes every turn with one of five statuses
of its own (docs/lifecycle.md): `completed`, `cancelled`, `rejected`,
`empty`, `failed`. The two sets differ in size, with no one-to-one
correspondence between them. That is a mapping question. It is not a
bug in either:

The mapping Task 7 pins (`Server#stop_reason`):

- `completed` → `end_turn`, and `cancelled` → `cancelled`. These are the
  two that carry almost all the traffic.
- `empty` → `end_turn`. An empty turn spent no step because there was
  nothing to send; it closed cleanly, so the honest answer to the editor
  is an ordinary end of turn, not an error.
- `rejected` → `refusal`. A rejected turn is a `agent/pre_step` veto
  (policy declined to run the work), and `refusal` is the one ACP stop
  reason that means "the agent chose not to act." It is a successful
  JSON-RPC *result*, because nothing errored: the agent refused, on
  purpose, and said so.
- `failed` → a JSON-RPC **error** response (`-32603`) to the pending
  prompt, not a stop reason. A turn that raises answers as a request that
  could not be completed, and the transport already has a shape for that.
- `max_turn_requests` is the semantic peer of `Loop::MAX_STEPS` (a turn
  that would log a 26th step), but it is not what Terret produces today. A
  step-ceiling overflow raises inside the turn body, which the turn's own
  rescue path closes as `turn/end {status: "failed"}` *and* re-raises. So
  a runaway turn lands in the `failed` → `-32603` branch above, and this
  server does **not** answer `max_turn_requests`. Doing so would be a
  deliberate change, not a projection of something that already exists.
- `max_tokens` and `refusal` (the *model's* refusal, as opposed to a
  policy `rejected`) have no Terret producer. Neither the adapter's finish
  reason nor a model refusal is projected into `turn/end`, so neither stop
  reason is ever the answer.

## Framing, concurrency, and failure

- **Newline-delimited JSON-RPC 2.0 over stdio.** No `Content-Length`
  headers. This is where ACP diverges from LSP, and it is why an
  LSP-shaped implementation fails silently. Messages are UTF-8 and must
  not contain embedded newlines.
- **stdout carries only ACP messages; stderr is free for logs.** That is a
  real constraint on a harness with plugins in it: anything that prints to
  stdout corrupts the stream. Ruby's `warn` and `Logger` default to stderr,
  which is the right side, but a `puts` anywhere in a mounted plugin is a
  protocol violation. It is not a stray line.
- **One reactor.** The read loop parks the fiber, never the thread (plan
  §8). A stdio server that blocks the thread on a read would stall every
  other agent in the process, which is the one mistake this codebase
  cannot afford to make twice.
- **A bounded outbound queue, drained by one writer fiber.** This is the
  decoupling terret-ws makes (ws/connection.rb), and for the same reason.
  `session/update` is projected inside `Sessions#fan_out`'s *synchronous*
  drainer. A write straight to a slow editor's pipe would park that
  drainer and stall every agent's `session/event` dispatch in the process
  (co-mounted sockets, the titler, the compactor), and the emit queue
  would grow unbounded. Instead every producer (the projection, the read
  loop, a turn task) enqueues a frame non-blockingly, and one writer
  fiber is the only thing that ever parks on the pipe. That single writer
  is also the one serialization point, so a streaming turn's notifications
  and a request's response never interleave without a mutex. A queue that
  fills means the editor stopped reading. Its output is dropped. The bus
  never blocks, and a lagging editor never wedges another session.
- **Errors are JSON-RPC standard plus three.** `-32700` parse, `-32600`
  invalid request, `-32601` method not found (the answer to any method
  this server does not implement, including every v2 name), `-32602`
  invalid params, `-32603` internal; ACP adds `-32800` request cancelled,
  `-32000` auth required, and `-32002` resource not found. A malformed
  request answers an error object and keeps the loop alive. An editor
  that sends garbage gets a reply, not a dead agent. Be lenient about
  malformed *optional* fields; the schema itself defaults them on error.
- **`$/cancel_request`** is a protocol-level notification either side may
  send for any pending request, carrying `{requestId}`. The response is
  either a partial result or `-32800`.
- **EOF disposes the connection, not the agent.** When the editor closes
  the pipe, the server tears down its own state; the session is durable
  and the agent parks per the M6 lifecycle. Closing a window is not a
  reason to lose a week-long session, and re-attaching is a
  `session/prompt` against the same session id going through the resumable
  branch above.

## What is deliberately absent

**Authentication.** `authMethods: []`, so `authenticate` is never reached.
That is a decision. It is not an omission: stdio inherits the editor's
process boundary. The client spawned this process, the pipes are private to
the pair, and the OS has already decided who may speak on them. The
socket's bearer token exists because a listening TCP port has no such
boundary (docs/security.md, "The socket's authority model"); duplicating it
over a private pipe would be ceremony. The corollary belongs in the threat
model: **an ACP client is exactly as trusted as the editor that spawned
it**. It holds full operator authority over the agents it creates. The
things that still bound what tools do are the sandbox and the allow list,
not the transport.

**Every client-side method.** ACP lets an agent call *back* into the
client: `fs/read_text_file` and `fs/write_text_file`, `terminal/*`,
`elicitation/*`, and `session/request_permission`. Terret calls none of
them, and no opt-out declaration exists or is needed. An agent that never
sends them has nothing to advertise.

For the two filesystem methods that is a containment decision, not a
preference: Terret has its own fs seam with realpath containment against a
granted workspace and an `fs/authorize` waterfall on every operation
(docs/exec.md §2–3), and routing file access through the editor instead
would put an uncontained path outside every guarantee M7 built, on the
exact seam where containment matters most. If editor-mediated file access
ever lands, it lands as a provider **behind `ctx[:fs]`**, subject to the
same containment as every other provider, not as a path around it.

`session/request_permission` is refused on the same grounds. The reasoning
belongs to this whole harness, not to anything specific about ACP:
**Terret's permission gate is its own.** A tool verdict comes from
`ctx[:approvals]` and from hot-reloadable deny-by-default policy
(docs/lifecycle.md, docs/security.md). Both are durable, survive the client
disconnecting, and stay the same whichever interface is attached.
Delegating that verdict to an editor's permission UI would move the most
security-relevant decision in the system out of the log and into a process
Terret does not control. Nothing in the protocol blocks the mapping (the
method is not capability-gated, so an agent simply chooses whether to send
it), and projecting `approval/requested` onto it someday is a plan §14
ledger idea. The M8 verdict is that it is not called.

**`session/load`.** Optional and gated behind `agentCapabilities.loadSession`,
which v1 does not advertise. Terret is unusually well placed to support it
later. A session *is* a durable log and replay is already exact
(docs/lifecycle.md), so this is a scope decision, not a missing
capability. Until it is advertised, re-attaching to a session goes through
`session/prompt` and the resumable branch.

**The ACP client direction.** Plan §6.8 describes a subagent provider that
delegates a turn to an external agent over ACP. It is recorded in plan §14 as
deferred, alongside the pooled-worker provider. `ctx[:subagents]` ships
with one provider, the fork (docs/subagents.md §2), and the seam is
where that second provider will land when it does, with no change to the
`Task` tool.

## Resolved in Task 7

The three decisions the wire left to the implementer, now pinned in code:

1. **The `turn/end` statuses with no stop reason.** Recorded in "Stop
   reasons" above: `empty` → `end_turn`, `rejected` → `refusal`, `failed`
   → a `-32603` error response. `MAX_STEPS` does **not** answer
   `max_turn_requests`. A runaway raises and lands in the `failed`
   branch.

2. **`cwd` and `mcpServers` from `session/new`.** Both are required by the
   schema, so a request missing either answers `-32602`; `cwd` must be a
   non-empty string. Neither widens the agent's reach: `cwd` does not
   grant filesystem access the `workspace:` row did not (docs/exec.md §3)
   and is not used as a working directory in v1, and `mcpServers` is
   accepted but not mounted (the same escalation `ctx[:subagents]` refuses
   by construction). Honoring either as authority would let a client
   extend the agent past the profile's floor.

3. **The `ToolKind` table** (`Server#tool_kind`). `Read` → `read`; `Glob`
   and `Grep` → `search`; `Write` and `Edit` → `edit`;
   `Bash`/`job_*`/`terminal_*` → `execute`; `WebFetch` → `fetch`. `Task`,
   every `mcp__<server>__<tool>` (names arrive at runtime), and any tool
   not in the std roster fall to `other`, the enum's own catch-all.

`$/cancel_request` (the protocol-level cancel in "Framing" below) is
implemented as a thin alias: a `{requestId}` naming the pending prompt of
some session lands on the same `Agent#cancel` path as `session/cancel`, so
the prompt then answers `stopReason: "cancelled"`. A `requestId` matching
no pending prompt is ignored, which is what a notification for
already-finished work should do.

## Running it

```
trt acp --profile zed
```

Boots a profile (docs/composition.md) and serves ACP on stdio. That is the
command an editor is configured to spawn. Driving it from Zed — the
profile, the launcher, and the behaviors that actually cost time — is
docs/zed.md.
