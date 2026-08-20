# The Terret Long-Lived Agent Lifecycle (v1)

M0–M5 proved a session that runs one turn, or a few, end to end: the log, the
loop, the socket, MCP tools. This document covers what changes when a session
runs for weeks instead of minutes (plan §12): many turns, many wakes, and a
deploy somewhere in between. Everything below exists so that derived context
survives all three: durable approvals, turn resumption, compaction, titling,
cost accounting, and the agent registry's lifecycle. It applies the existing
log-first contract (docs/terret-implementation-plan.md §2, "model-visible
means logged") to a longer clock. None of it is a new execution path.

## What "long-lived" means here

A short-lived session lives inside one process and is done before anyone asks
whether it survives a restart. A long-lived session is measured in weeks: it
accumulates turns past what a model's context window holds, it sits idle
between wakes, and at some point the process serving it dies and a new one
takes over. The mechanisms in this document answer three questions a
short-lived session never has to: what does the model see once history no
longer fits (compaction), what happens to a human approval that was asked but
not yet answered when the process died (durable approvals plus turn
resumption), and what does a session cost and call itself over that whole
span (cost accounting, titling). The agent registry's lifecycle is the
bookkeeping that makes many such sessions livable in one process at once.

## The status machine

    idle → running → waiting_approval → running → idle

`:waiting_approval` is a sub-state of a turn. It is not a peer of `:running`.
The agent is still mid-turn: a fiber is parked inside the tools pipeline
waiting on a verdict. A parked agent refuses a new turn exactly like a
running one does. Plan §6.4 also names `waiting_input`, `stopping`, and
`done`/`failed`. Those arrive with M7/M8 work; this milestone builds only
`idle`, `running`, and `waiting_approval`.

A turn is a bounded number of steps: `Loop::MAX_STEPS` is 25. A turn that
would log a 26th raises. Without the cap, a model that never stops calling
tools would loop forever. Every turn closes with a durable `turn/end
{status}`, and the status is one of five: `completed` (nothing more is owed),
`cancelled` (a cancel was honored at a step boundary), `rejected` (an
`agent/pre_step` listener refused the claim), `empty` (the turn had nothing
to say: no input, no steer, no owed call), or `failed` (an exception left the
turn). The one case with no `turn/end` at all is a failed **resume**, which
deliberately leaves its turn open; see "Resuming an open turn".

## Appends and fan-out

Everything below hangs off `session/event` listeners, several of which append
while handling an event. The compactor and the titler both react to
`turn/end` by writing to the same log. Seq assignment, the durable write, and
the in-memory push are one critical section per session, so two appenders (a
connection's frame and a turn, say) can never claim the same seq even though
the store write yields. Fan-out is queued, not nested: an event a listener
appends is delivered after the event it reacted to, never before, so a
subscriber sees the log in the order it was written. The price is that a
listener's own append returns before that event has fanned out.

## Durable approvals

A tool `Definition`'s `approval:` field (docs/terret-implementation-plan.md
§6.3) is `:never`, `:policy`, or `:always`, default `:never`.
`ctx[:approvals]` is the middleware that consumes it: `:always` always asks;
`:policy` asks when the definition is `mutating:` (plan §13's spirit:
mutation is what needs a human under policy); `:never` passes the call
straight through.

The gate lives on `tools/execute`, not `tools/pre_execute`. Waterfalls
dispatch parent-first, so a `tools/pre_execute` veto, the per-agent
`AllowList` (docs/mcp.md), always settles a call before a human is asked.
Putting the approvals gate at `pre_execute` on the root context would have it
run ahead of that per-agent veto instead. Durable approvals are an opt-in row
(a tool's `approval:` field). Terret's primary workload, autonomous agentic
systems, mostly skips them in favor of the policy-as-code allow list below.

Parking a call appends durable `approval/requested {call_id, name, args}`.
Resolving one appends durable `approval/resolved {call_id, verdict,
reason?}`, the same event the socket's `approve`/`deny` frames land on
(docs/protocol.md). The parked fiber resumes on the in-process fan-out of
that append; `ctx[:approvals].pending(session_id)` lists the call ids still
awaiting a verdict, which is what a reconnecting client, and `resume_turn`,
need in order to find outstanding asks.

**An approval belongs to the turn that asked for it.** `pending` and the
gate's verdict lookup both read only the open turn: the events after the last
`turn/start`, and nothing at all once a `turn/end` follows it. The lookup is
bound to content as well as to the id: a verdict must follow a request in
that turn naming the same call id, tool, and arguments. Provider tool call
ids are not contractually unique, so without both scopings an id reused in a
later turn would silently inherit a decision a human made about something
else. A closed turn's approvals settle with the turn; a call that comes back
afterwards is asked about again.

Both sides of an approval are in the log, so a parked call survives a
restart. On resume, the gate re-reads the log: if a verdict is already
recorded it never parks again; if none is recorded yet, the open turn sits
resumable until `Loop#resume_turn` re-enters it the moment a verdict lands.

There is no timeout. A parked approval is parked until a human decides, by
design. `deny_pending!` is the escape hatch: cancelling a turn while
approvals are parked marks the turn cancelled first and only then denies
every standing request durably. The parked call unparks into a turn that
already knows it is stopping. A cancelled turn never leaves an approval
dangling for a future resume to trip over.

## Resuming an open turn

`Loop#resumable?(session_id)` is true when the log has a `turn/start` with no
`turn/end` after it: the signature of a turn a process died in the middle of.
`resume_turn` does not append a second `turn/start`: it treats the existing
turn as still open.

Resuming is the only way back into such a session. `run_turn` on an idle
agent whose log holds an open turn raises `TurnOpenInLog` and appends
nothing. A second `turn/start` would strand whatever the open turn owes
(`resumable?` reads from the *last* `turn/start`) and leave the projection
carrying an assistant tool call with no result. A real provider rejects that
outright, on every request, forever. Every caller that can meet a resumed
session therefore branches: resumable means `inject` the new text and
`resume_turn`; otherwise `run_turn`. The socket does this on a waking
`inject` (docs/protocol.md), and so does `examples/web_chat.rb`. An agent
that is already mid-turn is a different matter and still raises the older
`TurnAlreadyRunning`. That open turn is its own, and the wake race below
depends on that distinction.

It first closes the open step: any tool call owed by the last assistant
message that has no matching `tool/result` yet gets re-executed (reading
approval verdicts from the log, not re-asking), then the step's `step/end` is
appended without a `usage:` field, because the original process's usage
figure died with it. From there the turn continues stepping normally and
closes with an ordinary `turn/end`.

That re-execution is why crash recovery is **at-least-once** for tool calls:
a call whose `tool/result` never logged may still have run, in whole or in
part, before the process died, and resume runs it again. Idempotency is the
tool's concern: a tool that cannot be safely repeated needs its own guard.
`gems/terret-ws/test/lifecycle_test.rb` holds that lane honest: a subprocess
wedges mid-tool, dies by `kill -9` so no `ensure` runs, and a fresh process
completes the turn on the first wake.

Three edges stay visible:

- An unclosed `step/start` from a mid-step crash stays unclosed. Step
  numbering continues past the gap; it is not backfilled.
- A turn that crashed right after a final, tool-free assistant message
  resumes by making one extra model request: the model sees its own prior
  message in its history and is asked to continue, which in practice means
  wrapping up.
- A turn that crashed before its first step logged anything closes as
  `:empty` on resume: the input that triggered it was never durably logged,
  so there is nothing to recover.

A resume that *fails* (the model provider is down, say) leaves the turn open.
It never closes that turn `failed`. That is the deliberate difference from
`run_turn`, where a failure is terminal for the turn and the log says so. A
resumed turn still owes a tool call; closing it would strand that call
permanently for what is usually a transient outage, so the turn stays
resumable and the next stimulus picks it up again.

## Compaction

`session/compacted {upto_seq, summary}` is a durable, model-visible event
(plan §2.5). `Sessions#derive_messages`
(gems/terret-core/lib/terret/sessions.rb) projects it by replacing every
event at or before `upto_seq` with the summary as a single user message; if
more than one compaction exists in the log, only the latest is applied.
Superseded ones simply drop out of the projection.

**The boundary contract:** `upto_seq` is always the seq immediately preceding
the `session/compacted` event itself, computed at append time, after the
summarizer has already returned. Summarizing is a round trip, so the
compactor records the last seq before it starts and checks again after: if
anything **model-visible** landed meanwhile (`user/message`,
`context/injected`, `assistant/message`, `tool/result`, `session/compacted`),
it declines and appends no boundary, because that history would otherwise be
swept under a summary that never read it. Projection-invisible arrivals (a
raced `approval/resolved`, a `policy/updated`) still fall under the boundary
and lose nothing, since they were never part of the projection the summary
stands in for.

**Compaction is a between-turns operation.** The trigger owns the safe
window: it fires on `turn/end`, when the agent is idle and no step is
mid-flight. `compact!` called by hand mid-turn is not safe in the same way.
The running turn's own next `assistant/message` is exactly the kind of
model-visible event the check above will refuse on, so a manual compaction
racing a live turn declines and corrupts nothing. It also does not
accomplish what the caller asked for.

Triggering is automatic and manual both. `ctx[:compactor]`, configured with
`config[:budget]`, compacts a session after any turn whose last `step/end`
carried `usage.prompt_tokens >= budget`. `compact!(session_id)` is the same
operation invoked directly. Either way, generating the summary itself is a
seam: `ctx[:summarizer]`, sole-provider like the session store. The compactor
does not do that inline. `RoleSummarizer`, the no-signup default, issues one
utility request through `ctx[:llm].stream` derived from the log. It is not a
session request the loop's invariant assert ever sees
(docs/terret-implementation-plan.md §2). `terret-morph` is the other
provider: it calls out to Morph's Compact API on the wire proven in the
deployed agora integration, extractive-compressing the rendered history
instead of asking a model to write a summary. Every message part goes on its
own role-tagged line, tool calls and results included, so a compacted session
keeps the deploy ids and errors its transcript earned.

The two providers fail differently. Morph declines to `nil` on every failure,
warning as it goes: no key, an HTTP error, a torn response. `RoleSummarizer`
raises instead when its `:compactor` role is unconfigured. Inside the budget
trigger that is isolated by `emit` dispatch and the turn survives untouched,
but a manual `compact!` raises it through to the caller. Either way a decline
is non-fatal: the turn that triggered it already closed successfully, and the
next overweight turn simply retries compaction.

## Titling

Every session gets exactly one durable `session/titled {title}` event,
appended by `ctx[:titler]` at the first `turn/end` it sees. Titling uses the
`:titler` model role when one is configured in `config[:roles]`; absent that,
it falls back to the session's first user message truncated to 40 characters.
Whichever produced it, the stored title is capped at 80 characters. A model
asked for six words can always answer with sixty. Like an approval event, a
title is metadata: it never enters `derive_messages`'s projection.
`Sessions#title(session_id)` reads the latest one recorded.

## Cost accounting

Usage figures arrive on `step/end` events: the adapter yields them, and for
OpenRouter that means every final SSE chunk carries usage automatically, with
no separate accounting call. `Sessions#usage(session_id)` sums every
`step/end`'s usage across the whole log into `{prompt_tokens:,
completion_tokens:, cost:, steps:}`. A session's lifetime spend is a pure
projection of the log, which is exactly why it stays correct across a
restart: nothing about it depends on any one process having been alive for
the whole session.

## Agent lifecycle

At most one live agent exists per session at a time. `spawn_agent` refuses
both an agent-id collision and a session already spawned under a different
agent, raising `AgentExists` either way, and enforces `config[:max_agents]`
(default 128), raising `AgentCapExceeded` once the registry is full. That is
the blast-radius cap from plan §14's debt list.

`dispose_agent(id)` disposes the agent's forked `Context`: every listener and
effect it registered dies with it. It also frees its slot in the registry.
Only an idle agent can be disposed; disposing a running or parked one would
tear down the fiber a turn is depending on. `agent_for_session(session_id)`
is the session-to-agent index: the approvals service uses it to find the
right agent to flip to `:waiting_approval` and back.

## Hot-reloadable permissions

`Terret::Tools::AllowList` (plan §6.3) is a per-agent `tools/pre_execute`
listener installed on the agent's forked context, but the pattern set it
enforces is not frozen in that listener's closure. The **active** set is a
log projection: the patterns from the last durable `policy/updated` event in
the call's session, falling back to the patterns `install` was called with.
The install-time set is a floor, not a ceiling, and it only governs sessions
that have never hot-updated. A session this context cannot read at all is a
third case, and it fails closed: no policy is readable, so nothing is
permitted and every call is vetoed with a warning. Falling back to the floor
there would hand an unknown session more authority than the floor was ever
meant to grant.

`AllowList.update(ctx, session_id, patterns)` is an ordinary durable append.
It takes effect on the very next tool call: no reinstall, no listener churn.
Because it is only a log projection, replaying the session on a fresh process
rebuilds it exactly. A hot-reloaded policy survives a restart for free, the
same way compaction and titling do. The last `policy/updated` event in the
log always wins; superseded ones simply stop being the one `current_patterns`
finds.

That derivation is a reverse scan of the whole session log, and it runs on
every tool call, so the active set is memoised per session in a read-through
cache the install owns. A cache miss derives from the log exactly as above; a
`session/event` listener refreshes the entry the moment a `policy/updated`
lands. Invalidation therefore stays a function of the durable log and never
becomes a second source of truth. An unknown session is never cached, so its
deny-all can never ossify into an allow. The cache is a closure local of one
install: a forked agent's own AllowList caches on its own, so nothing leaks a
policy across agents.

The socket drives it with the `set_policy` frame (docs/protocol.md), which
appends `policy/updated` the same way `set_model` repoints a model role:
seam-first, no bespoke wiring. Deny-by-default is unchanged: a call that
matches no active pattern is a `Veto`, which surfaces to the model as an
ordinary tool-result error. It does not stop the turn. Like an approval or a
title, `policy/updated` is metadata: `derive_messages` never projects it into
what the model sees.

## Wake-on-stimulus

`inject(text, wake: false)` queues `text` in the agent's inbox; it rides into
a step the next time one runs, whether that step belongs to a turn already
underway or one that has not started yet. `wake: true` on an idle agent is
what starts a turn, with the injected text as its input.

Two `wake: true` injections racing on the same idle agent in one read burst
produce a winner and a loser. The loser's attempt to start a turn raises
`TurnAlreadyRunning`. Its text is not dropped: it is requeued into the inbox
and rides the winner's very next step, or the next turn if the winner's turn
ends first.
