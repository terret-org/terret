# The Terret Long-Lived Agent Lifecycle (v1)

M0–M5 proved a session that runs one turn, or a few, end to end: the log,
the loop, the socket, MCP tools. This document covers what changes when a
session runs for weeks instead of minutes (plan §12): many turns, many
wakes, and a deploy somewhere in between. Everything below — durable
approvals, turn resumption, compaction, titling, cost accounting, and the
agent registry's lifecycle — exists so that derived context survives all
three. None of it is a new execution path; it is the existing log-first
contract (docs/terret-implementation-plan.md §2, "model-visible means
logged") applied to a longer clock.

## What "long-lived" means here

A short-lived session lives inside one process and is done before anyone
asks whether it survives a restart. A long-lived session is measured in
weeks: it accumulates turns past what a model's context window holds, it
sits idle between wakes, and at some point the process serving it dies and
a new one takes over. The mechanisms in this document answer three
questions a short-lived session never has to: what does the model see once
history no longer fits (compaction), what happens to a human approval that
was asked but not yet answered when the process died (durable approvals
plus turn resumption), and what does a session cost and call itself over
that whole span (cost accounting, titling). The agent registry's lifecycle
is the bookkeeping that makes many such sessions livable in one process at
once.

## The status machine

    idle → running → waiting_approval → running → idle

`:waiting_approval` is not a peer of `:running`; it is a sub-state of a
turn. The agent is still mid-turn — a fiber is parked inside the tools
pipeline waiting on a verdict — and a parked agent refuses a new turn
exactly like a running one does. Plan §6.4 also names `waiting_input`,
`stopping`, and `done`/`failed`. Those arrive with M7/M8 work; this
milestone builds only `idle`, `running`, and `waiting_approval`.

## Durable approvals

A tool `Definition`'s `approval:` field (docs/terret-implementation-plan.md
§6.3) is `:never`, `:policy`, or `:always`, default `:never`. `ctx[:approvals]`
is the middleware that consumes it: `:always` always asks; `:policy` asks
when the definition is `mutating:` (plan §13's spirit — mutation is what
needs a human under policy); `:never` passes the call straight through.

The gate lives on `tools/execute`, not `tools/pre_execute`. Waterfalls
dispatch parent-first, so a `tools/pre_execute` veto — the per-agent
`AllowList` (docs/mcp.md) — always settles a call before a human is asked;
putting the approvals gate at `pre_execute` on the root context would have
it run ahead of that per-agent veto instead. Durable approvals are an
opt-in row (a tool's `approval:` field), and Terret's primary workload —
autonomous agentic systems — mostly skips them in favor of the
policy-as-code allow list below.

Parking a call appends durable `approval/requested {call_id, name, args}`.
Resolving one appends durable `approval/resolved {call_id, verdict,
reason?}` — the same event the socket's `approve`/`deny` frames land on
(docs/protocol.md). The parked fiber resumes on the in-process fan-out of
that append; `ctx[:approvals].pending(session_id)` lists the call ids still
awaiting a verdict, which is what a reconnecting client, and `resume_turn`,
need in order to find outstanding asks.

Both sides of an approval are in the log, so a parked call survives a
restart. On resume, the gate re-reads the log: if a verdict is already
recorded it never parks again; if none is recorded yet, the open turn sits
resumable until `Loop#resume_turn` re-enters it the moment a verdict lands.

There is no timeout. A parked approval is parked until a human decides, by
design. `deny_pending!` is the escape hatch: cancelling a turn while
approvals are parked denies every one of them durably first, then cancels
the turn — a cancelled turn never leaves an approval dangling for a future
resume to trip over.

## Resuming an open turn

`Loop#resumable?(session_id)` is true when the log has a `turn/start` with
no `turn/end` after it — the signature of a turn a process died in the
middle of. `resume_turn` does not append a second `turn/start`: it treats
the existing turn as still open.

It first closes the open step: any tool call owed by the last assistant
message that has no matching `tool/result` yet gets re-executed (reading
approval verdicts from the log rather than re-asking), then the step's
`step/end` is appended — without a `usage:` field, because the original
process's usage figure died with it. From there the turn continues
stepping normally and closes with an ordinary `turn/end`.

That re-execution is why crash recovery is **at-least-once** for tool calls:
a call whose `tool/result` never logged may still have run, in whole or in
part, before the process died, and resume runs it again. Idempotency is the
tool's concern — a tool that cannot be safely repeated needs its own guard.
`gems/terret-ws/test/lifecycle_test.rb` holds that lane honest: a subprocess
wedges mid-tool, dies by `kill -9` so no `ensure` runs, and a fresh process
completes the turn on the first wake.

Three edges are left visible rather than papered over:

- An unclosed `step/start` from a mid-step crash stays unclosed; step
  numbering continues past the gap rather than backfilling it.
- A turn that crashed right after a final, tool-free assistant message
  resumes by making one extra model request — the model sees its own
  prior message in its history and is asked to continue, which in practice
  means wrapping up.
- A turn that crashed before its first step logged anything closes as
  `:empty` on resume: the input that triggered it was never durably logged,
  so there is nothing to recover.

## Compaction

`session/compacted {upto_seq, summary}` is a durable, model-visible event
(plan §2.5). `Sessions#derive_messages` (gems/terret-core/lib/terret/sessions.rb)
projects it by replacing every event at or before `upto_seq` with the
summary as a single user message; if more than one compaction exists in
the log, only the latest is applied — superseded ones simply drop out of
the projection.

**The boundary contract:** `upto_seq` is always the seq immediately
preceding the `session/compacted` event itself, computed at append time —
after the summarizer has already returned. Only projection-invisible
events (a raced `approval/resolved`, say) can land during summarization at
all, because the agent is still mid-turn while it summarizes and nothing
model-visible can interleave with an open turn. An invisible event that
falls below the boundary loses nothing, since it was never part of the
projection the summary stands in for.

Triggering is automatic and manual both. `ctx[:compactor]`, configured
with `config[:budget]`, compacts a session after any turn whose last
`step/end` carried `usage.prompt_tokens >= budget`. `compact!(session_id)`
is the same operation invoked directly. Either way, generating the summary
itself is a seam, `ctx[:summarizer]` — sole-provider, like the session
store — rather than something the compactor does inline. `RoleSummarizer`,
the no-signup default, issues one utility request through `ctx[:llm].stream`
derived from the log — not a session request the loop's invariant assert
ever sees (docs/terret-implementation-plan.md §2). `terret-morph` is the
other provider: it calls out to Morph's Compact API on the wire proven in
the deployed agora integration, extractive-compressing the rendered
history instead of asking a model to write a summary. Either provider may
decline (return nil/empty) on any failure, which is non-fatal: the listener
is isolated, the turn that triggered it already closed successfully, and
the next overweight turn simply retries compaction.

## Titling

Every session gets exactly one durable `session/titled {title}` event,
appended by `ctx[:titler]` at the first `turn/end` it sees. Titling uses
the `:titler` model role when one is configured in `config[:roles]`; absent
that, it falls back to the session's first user message truncated to 40
characters. Like an approval event, a title is metadata: it never enters
`derive_messages`'s projection. `Sessions#title(session_id)` reads the
latest one recorded.

## Cost accounting

Usage figures arrive on `step/end` events — the adapter yields them, and
for OpenRouter that means every final SSE chunk carries usage automatically,
with no separate accounting call. `Sessions#usage(session_id)` sums every
`step/end`'s usage across the whole log into `{prompt_tokens:,
completion_tokens:, cost:, steps:}`. A session's lifetime spend is a pure
projection of the log, which is exactly why it stays correct across a
restart: nothing about it depends on any one process having been alive for
the whole session.

## Agent lifecycle

At most one live agent exists per session at a time. `spawn_agent` refuses
both an agent-id collision and a session already spawned under a different
agent, raising `AgentExists` either way, and enforces `config[:max_agents]`
(default 128), raising `AgentCapExceeded` once the registry is full — the
blast-radius cap from plan §14's debt list.

`dispose_agent(id)` disposes the agent's forked `Context` — every listener
and effect it registered dies with it — and frees its slot in the
registry. Only an idle agent can be disposed; disposing a running or
parked one would tear down the fiber a turn is depending on. `agent_for_session(session_id)`
is the session-to-agent index: the approvals service uses it to find the
right agent to flip to `:waiting_approval` and back.

## Hot-reloadable permissions

`Terret::Tools::AllowList` (plan §6.3) is a per-agent `tools/pre_execute`
listener installed on the agent's forked context, but the pattern set it
enforces is not frozen in that listener's closure. The **active** set is a
log projection: the patterns from the last durable `policy/updated` event
in the call's session, falling back to the patterns `install` was called
with — the install-time set is a floor, not a ceiling, and it only governs
sessions that have never hot-updated.

`AllowList.update(ctx, session_id, patterns)` is an ordinary durable
append. It takes effect on the very next tool call — no reinstall, no
listener churn — and because it is only a log projection, replaying the
session on a fresh process rebuilds it exactly: a hot-reloaded policy
survives a restart for free, the same way compaction and titling do. The
last `policy/updated` event in the log always wins; superseded ones simply
stop being the one `current_patterns` finds.

The socket drives it with the `set_policy` frame (docs/protocol.md), which
appends `policy/updated` the same way `set_model` repoints a model role —
seam-first, no bespoke wiring. Deny-by-default is unchanged: a call that
matches no active pattern is a `Veto`, which surfaces to the model as an
ordinary tool-result error rather than stopping the turn. Like an approval
or a title, `policy/updated` is metadata — `derive_messages` never projects
it into what the model sees.

## Wake-on-stimulus

`inject(text, wake: false)` queues `text` in the agent's inbox; it rides
into a step the next time one runs, whether that step belongs to a turn
already underway or one that has not started yet. `wake: true` on an idle
agent is what actually starts a turn, with the injected text as its input.

Two `wake: true` injections racing on the same idle agent in one read
burst produce a winner and a loser: the loser's attempt to start a turn
raises `TurnAlreadyRunning`, and rather than dropping its text, that text
is requeued into the inbox — it rides the winner's very next step, or the
next turn if the winner's turn ends first. The wake race requeues; it
never drops.
