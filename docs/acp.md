# Terret over ACP (v1)

> **Status: this document records the mapping, not the wire.** The method
> and notification names below are drafted from the Agent Client Protocol
> as understood when the M8 primers were written, ahead of the server
> itself. The implementer of the `terret-acp` gem verifies every name,
> parameter, and result shape against the published spec
> (agentclientprotocol.com) and corrects this document **in the same
> commit**, recording the protocol version string the server reports.
> Where a name here disagrees with the spec, the spec is right and this
> file is wrong. What is not provisional is the mapping: which Terret seam
> each protocol operation lands on, and what is deliberately not
> implemented.

## What ACP is

The Agent Client Protocol is Zed's contract between an editor and a coding
agent: **JSON-RPC 2.0 over stdio**. The editor spawns the agent as a
subprocess and speaks to it over that process's stdin and stdout — the
same shape as the Language Server Protocol, and for the same reason. An
editor that speaks ACP can drive any agent that speaks it, and an agent
that speaks it gets every such editor for free.

It is worth being precise about the direction, because Terret now sits on
both sides of an interop story that uses similar words for opposite
things (plan §6.8):

- **MCP** makes tools available **to** an agent. Terret is the *client*;
  a server's tools mount as `mcp__<server>__<tool>` behind `ctx[:tools]`
  (docs/mcp.md).
- **ACP** makes an agent available **to** an editor. Terret is the
  *server*; an editor drives `ctx[:agents]`.

`terret-acp` is the second one only. The ACP *client* direction — Terret
delegating a turn to some other agent over ACP — is a subagent provider
and is deferred (below).

## Why it is a gem, and what it proves

`terret-acp` is an interface plugin, exactly like `terret-ws`: it consumes
`session/event` and drives the agent registry, and it holds no session
vocabulary of its own. That is the point of building it at all beyond the
editors it unlocks. The claim in plan §1 is that everything is a plugin
and the interface is not privileged; the standing proof of that claim was
one interface (§9.1). A second interface, on a completely different
transport, built out of the same two seams with no change to core, is what
turns a claim into evidence.

The consumption pattern is copied from
`gems/terret-ws/lib/terret/ws/connection.rb` (docs/protocol.md). The
transport is the only new thing.

## The mapping

| ACP operation | Terret |
|---|---|
| `initialize` | capabilities handshake: protocol version, plus what this boot actually mounts |
| `session/new` | `spawn_agent` on a fresh durable session; answers the session id |
| `session/prompt` | `run_turn`, with `session/update` notifications projected from `session/event`; answers when the turn closes |
| `session/cancel` | the cancel path: cooperative, honored at a step boundary, closing a durable `turn/end {status: "cancelled"}` |

Four notes on that table, each of which is a real constraint rather than a
restatement.

**`initialize` reports what is mounted, not what the code can do.** A
Terret boot is a profile (docs/composition.md), so two deployments of the
same gems have different capabilities: one has the approvals row, one does
not; one sandboxes, one does not. The handshake answers from the booted
context.

**`session/new` spawns a real agent** with the ordinary lifecycle — the
registry's cap applies (`AgentCapExceeded` at 128, docs/lifecycle.md), and
the session is durable, titled, and cost-accounted like every other
session. An editor session is not a lightweight second-class thing; it is
the same object the socket would have connected to.

**`session/prompt` branches on resumability.** A session whose log holds a
`turn/start` with no `turn/end` is resumable, and `run_turn` on it raises
`TurnOpenInLog` by design (docs/lifecycle.md, "Resuming an open turn").
Every caller that can meet a session someone else was driving has to
branch — inject then `resume_turn`, or `run_turn` — and the socket already
does. ACP is exactly such a caller: an editor reopening a project is the
canonical way to meet a turn that a killed process left open.

**`session/cancel` is cooperative.** It requests a stop that lands at the
next step boundary rather than tearing a fiber out of a tool call; a
barrier of parallel calls settles first (docs/subagents.md §5). The
`:stopping` status exists to make that interval observable instead of
leaving a cancelled agent reporting `:running`.

## `session/update`: a projection of the log

The same rule that governs the socket governs this: **nothing reaches a
client that is not in the log first**. Notifications are derived from
`session/event` and from nothing else, so the ACP server invents no
vocabulary and adds no second source of truth.

The draft projection:

| durable event | notification |
|---|---|
| `assistant/chunk` | agent message chunk |
| `tool/call` | tool call begin |
| `tool/result` | tool call end |

There is one honest difference from the socket, and it should be stated
rather than left for someone to infer. `terret-ws` serializes the durable
envelope **as-is**, so a client can reconstruct the session exactly and
replay-then-tail is byte-exact (docs/protocol.md). ACP notifications are a
**lossy view**: the protocol has shapes for the things an editor renders,
and Terret has durable events with no ACP shape at all —
`approval/requested`, `policy/updated`, `session/titled`, `session/compacted`.
Those simply do not project. An ACP client therefore cannot rebuild a
session from what it received, and it is not supposed to; the socket is
what that is for, and both can be mounted against the same agent.

Chunk fidelity carries one inherited caveat worth knowing before debugging
it: with a redactor mounted, the loop coalesces each run of assistant text
into a single `assistant/chunk` at run end rather than streaming
delta-by-delta (docs/exec.md §6). An ACP client of a redacting deployment
sees text arrive in bursts. That is the redaction trade, not the
transport's.

## Framing, concurrency, and failure

- **One reactor.** The read loop parks the fiber, never the thread (plan
  §8) — a stdio server that blocks the thread on `gets` would stall every
  other agent in the process, which is the one mistake this codebase
  cannot afford to make twice.
- **One write mutex.** A streaming turn emits notifications while a
  request/response pair is in flight. Frames must not interleave, so every
  write goes through one serialization point.
- **A malformed request answers a JSON-RPC error and keeps the loop
  alive.** An editor that sends garbage gets an error object, not a dead
  agent.
- **EOF disposes the connection, not the agent.** When the editor closes
  the pipe, the server tears down its own state; the session is durable
  and the agent parks per the M6 lifecycle. Closing a window is not a
  reason to lose a week-long session, and re-attaching is a `session/prompt`
  against the same session id going through the resumable branch above.

The exact framing — newline-delimited JSON versus LSP-style
`Content-Length` headers — is a spec question, listed below rather than
guessed here.

## What is deliberately absent

**Authentication.** There is none, and that is a decision rather than an
omission. Stdio inherits the editor's process boundary: the editor spawned
this process, the pipes are private to the pair, and the OS has already
decided who may speak on them. The socket's bearer token exists because a
listening TCP port has no such boundary (docs/security.md, "The socket's
authority model"); duplicating it over a private pipe would be ceremony.
The corollary belongs in the threat model rather than in a footnote: **an
ACP agent is exactly as trusted as the editor that spawned it**, an ACP
client holds full operator authority over the agents it creates, and the
thing that still bounds what tools do is the sandbox and the allow list,
not the transport.

**The ACP client direction.** Plan §6.8 describes a subagent provider that
delegates a turn to an external agent over ACP. It is recorded in §14 as
deferred, alongside the pooled-worker provider. `ctx[:subagents]` ships
with one provider — the fork (docs/subagents.md §2) — and the seam is
where that second provider will land when it does, with no change to the
`Task` tool.

**Client-side filesystem round-trips beyond the protocol minimum.** ACP
gives an agent a way to reach files through the client rather than
directly. Terret has its own filesystem seam, with realpath containment
against a granted workspace and an `fs/authorize` waterfall on every
operation (docs/exec.md §2–3, docs/security.md). Routing file access
through the editor instead would put an uncontained path outside every
guarantee M7 built, and would do it on the exact seam where containment
matters most. If editor-mediated file access lands later, it lands as a
provider **behind `ctx[:fs]`**, subject to the same containment as every
other provider — not as a path around it.

**A permission/approval UI direction**, pending the spec check below. If
ACP carries a client-prompts-the-human operation, the natural landing is
the durable approvals seam — `approval/requested` out, the resolution
appending `approval/resolved` exactly as the socket's `approve`/`deny`
frames do (docs/lifecycle.md), with no new state anywhere. Whether that
lands in M8 or is recorded in §14 is the implementer's call once the spec
is read.

## Open for the Task-7 implementer

Verify against the spec and correct this document in the same commit:

1. Exact method and notification names, and the `initialize` params/result
   shapes.
2. The `session/update` payload variants, and which durable events project
   onto which.
3. The stop-reason vocabulary a cancelled or completed prompt answers
   with, and how it lines up with Terret's five `turn/end` statuses
   (`completed`, `cancelled`, `rejected`, `empty`, `failed`).
4. Framing: newline-delimited JSON or `Content-Length` headers.
5. Error codes beyond the JSON-RPC standard set.
6. Whether a client-side permission request exists, and therefore whether
   the approvals mapping above ships or is deferred.

## Running it

```
trt acp --profile headless
```

Boots a profile (docs/composition.md) and serves ACP on stdio. That is the
command an editor is configured to spawn.
