# Terret Subagents, Jobs, and the Tool Barrier (v1)

M7 gave an agent hands (docs/exec.md). M8 gives it help: children it can
delegate a whole conversation to, work that outlives the turn that started
it, a plan it can write down, and — finally — the ability to do more than
one thing at a time. This is that primer, written before any of it is
code, the way docs/exec.md and docs/security.md were.

Four mechanisms, one theme. Every one of them adds a way for work to
happen somewhere other than inline in the current step, and every one of
them stays inside the contract that made the first seven milestones
tractable: model-visible means logged, deny-by-default fails closed,
registration is reversible, and the log's order is the same on every
replay.

## 1. The `ctx[:subagents]` seam

`ctx[:subagents]` is a **sole-provider** seam — the shape
`ctx[:session_store]` and `ctx[:summarizer]` already use (docs/lifecycle.md,
"Compaction"). Exactly one provider may claim the key; a second
registration raises rather than quietly winning — though that much is true
of every service key in the kernel, which answers a duplicate claim with a
`ContractError`. What is a design choice here is that **nothing sits behind
the key dispatching between providers**. "What is a subagent in this
deployment" is one answer for the whole process, decided in a config row,
rather than a roster the `Task` tool picks from per call.

The seam is small:

```ruby
ctx[:subagents].run(prompt:, ctx:)   # => Result(text:, session_id:, usage:)
```

`prompt:` is the child's instruction. `ctx:` is the **calling agent's**
context, not the root — which is the whole of §3 below, and the reason the
argument is explicit rather than reached for from a service ivar.

Plan §6.4 names three providers for this seam. M8 builds one: the fork
provider. The other two — a delegated turn to an external agent over ACP
(docs/acp.md), and a pooled worker — are recorded in plan §14 as deferred, not
sketched here. A seam with one provider is still a seam; what makes it one
is that the `Task` tool talks to `run` and knows nothing else.

## 2. The fork provider's lifecycle

The default provider spawns a fresh child agent inside a fork of the
calling agent's context and runs it to completion. Exactly:

1. **Fork the calling agent's context** (`ctx.fork`, plan §4.1). Every
   registration the child makes is recorded on that fork.
2. **Spawn a child agent** on it with a **fresh session id** — a new
   durable session, not a copy of the parent's. This is the one M8 change
   to the registry: `spawn_agent` gains a `parent:` keyword whose default
   is the loop service's own `@ctx`, so it forks from the root exactly as
   it does today and every existing caller — the socket, ACP, a test
   harness — is untouched. The subagent provider is the caller that passes
   something else: the calling agent's context.
3. **Append the prompt** as a `user/message` on the child's session, the
   same append every other input goes through.
4. **Run the turn to completion** through the ordinary `Loop`: same steps,
   same MAX_STEPS ceiling, same pipeline, same approvals gate, same allow
   list.
5. **Read the result** off the log — the final assistant text from the
   child session's projection, and `Sessions#usage(child_session_id)` for
   what it cost.
6. **Dispose the child agent**, unconditionally, including when the turn
   raised. The fork is disposed with it, so every tool, listener, and
   effect the child installed dies at the same moment.

The value that comes back is
`Subagents::Result = Data.define(:text, :session_id, :usage)`.

Two properties of that sequence are load-bearing rather than incidental.

**The child's session is fresh, not forked.** `Sessions#fork` exists — it
copies events up to a boundary under a new id and records `session/forked`
lineage (plan §6.1) — and this is deliberately not that. A subagent
inherits its parent's *capabilities*, not its parent's *transcript*. The
child sees the prompt it was given and nothing else, which is most of why
delegating is worth doing at all: the point of a subagent is that a long,
expensive parent context does not have to be re-read to answer a bounded
question.

**The parent's log gains no new durable event.** No `subagent/started`, no
lineage record — just the ordinary `tool/call` and `tool/result` bookends
every tool call already writes. That keeps "model-visible means logged"
exactly true with nothing added: the only thing the parent's model ever
sees of the child is the tool result, and the tool result is in the log.
It costs something, and the cost is worth naming rather than discovering:
**nothing in the parent's log links it to the child's session except the
ledger line inside that tool result** (§4). That is why the ledger line
names the session id and why it is not cosmetic — it is the only thread
from a parent transcript to a child's.

A cost rollup inherits the same shape. `Sessions#usage(session_id)` is a
pure projection of one log (docs/lifecycle.md, "Cost accounting"), so a
parent's rollup is the parent's own steps and nothing more. What a turn
truly spent is the parent's rollup plus one per child session it named. The
seam returns `usage:` so a caller that wants to account for a child inline
can, and the number stays recoverable from the child's log forever anyway,
which is why the `Task` tool spends its ledger line on the session id
rather than on tokens the model does not need in its context.

**Failure inside the child** renders to the parent as an ordinary
`Terret::Tools::Failure` naming the child's session id. The message never
embeds the child's stack. A stack trace in a tool result is context the
parent's model cannot act on and pays for on every subsequent request; the
session id is the pointer to where the whole story actually is.

**An approval that would park inside a child is denied instead.** This is the
one place the child's pipeline does not behave exactly like its parent's, and
it is a deadlock that has to be answered rather than a rule anybody wanted.
Nothing can reach a child's session to decide anything: the parent's log never
names it (that is the paragraph above), so no socket is bound to it and no
operator can answer a request they were never shown. A parked call there waits
on a verdict that cannot arrive, and it waits holding the fiber that runs the
parent's turn — one delegated call would take the parent down with it. So the
approvals gate refuses: the call comes back as an ordinary denial reading
`no approver can reach a subagent session`, the child's model sees it in a
tool result and can say so, and no `approval/requested` is ever written,
because nobody is going to be asked.

The order inside the gate is what keeps this from swallowing real decisions. A
verdict **already in the log** settles a call however it got there, so a child
that crashed and resumed still honors the answer a human really gave; only a
call with no recorded answer at all reaches this refusal. The allow list still
runs first, as it does everywhere. And a top-level agent is untouched — the
flag is set by the subagent provider on the children it spawns, so an
interface-driven agent parks exactly as it always did.

What this costs is real and worth stating: **a subagent cannot do anything
that needs a human's consent.** A deployment that wants a child to run `Bash`
in a profile where `Bash` demands approval has to grant that at the policy
level rather than at the moment of the call. Routing a child's request to the
parent's operator — a delegated approval — is the design that would lift this,
and it is a plan §14 item rather than something to bolt on: it needs a link
from a parent transcript to a child's request that §2 deliberately does not
create.

Two limits fall straight out of the existing machinery. The registry's
agent cap (`config[:max_agents]`, default 128, docs/lifecycle.md) counts
children like anything else, and a child holds its slot for the length of
its run — so a wide parallel fan-out of `Task` calls is bounded by the same
cap as the fleet, and `AgentCapExceeded` is what a caller sees when it is
not. And a child that itself calls `Task` nests: nothing forbids it, the
cap is the only ceiling, and a deployment that does not want recursive
delegation expresses that in its allow list rather than in this seam.

## 3. Why the child inherits the parent's roster and policy floor

The provider forks the **calling agent's** context, so the child starts
with the tools that agent can see and the `tools/pre_execute` listeners
that govern it — including its `Terret::Tools::AllowList`. Deny-by-default
carries down. **A subagent is not an escalation path**, and the design
says so structurally rather than by a check someone has to remember to
write: `run` takes the caller's `ctx` as an argument and passes it as
`parent:`, so **no path the subagent provider can take builds a child from
the root context**. (The registry's own default is still a root fork —
that is what an interface spawning a top-level agent wants, and §2's
`parent:` keyword is what keeps the two cases from having to share one
answer.)

Where the caller's context comes from is worth naming, because the whole
guarantee rests on it. `Task` is a std tool registered on the **root**
context like the rest of the roster, so its handler's closure captures the
root and not any agent. What it does at call time is look the caller up:
the handler receives the session it is running in (M7's merge-ordered
`session_id`, which a model-forged argument cannot override), and
`ctx[:loop].agent_for_session(session_id).ctx` is the calling agent's
forked context. That lookup is the load-bearing line in the tool.

That matters because the alternative is a familiar hole. If a child were
forked from the root, an agent restricted to `Read` and `Grep` could ask a
child to run `Bash`, and the restriction would be worth nothing —
delegation would be a privilege-escalation primitive dressed as a
convenience.

One consequence of the AllowList's own design deserves stating plainly
rather than being left for someone to trip over. The active pattern set is
a projection of **the call's session**: the last `policy/updated` event in
that session, falling back to the patterns `install` was called with
(docs/lifecycle.md, "Hot-reloadable permissions"). A child's session is
fresh, so it holds no `policy/updated` — which means the child runs at the
**install-time floor**, not at whatever the parent's live, hot-updated set
happens to be. In the direction that matters that is safe: the floor is a
ceiling the child can never exceed, so a hot update that *widened* a
parent does not widen its children. In the other direction it is a real
edge: a policy hot-*narrowed* mid-session does not narrow the children
spawned after it. A deployment that needs a live narrowing to propagate
should narrow the floor (a config row) rather than only the running
session.

## 4. The `Task` tool

| Tool | mutating | approval | concurrency |
|---|---|---|---|
| `Task` | `false` | `:never` | `:parallel` |

Claude Code's name verbatim, per the M7 rule (docs/exec.md §5): allow
lists in the wild are already written against `Task`, and inventing a
Terret-native name would buy a translation layer that does nothing but
rename, forever.

Parameters are two strings:

- `description` — a short label for the delegation, the kind of thing that
  reads well in a log or a UI line.
- `prompt` — the child's instruction, the whole of what the child will
  see.

The result is the child's final text followed by the ledger:

```
<the child's final assistant message>
--- terret ---
child session <session id>
```

`--- terret ---` is the same literal `Bash` and `WebFetch` separate their
output with, and it carries the same caveats those tools already document:
it is a readability device rather than a security boundary — a child could
print the line itself — and what it actually delivers is that the genuine
remarks are always last and always advisory data that nothing downstream
acts on.

**`approval: :never` on a tool that can obviously mutate the world** is the
one entry here that looks wrong and is not. The metadata describes what
*this* call does directly, and this call starts a conversation. Everything
the child then does passes the child's own pipeline: its own allow list,
its own approvals gate, one decision per actual effect. Gating `Task`
itself would ask a human to approve a call whose effects are not knowable
until after the approval is granted — the worst possible moment to ask —
and would then ask again, correctly, for each real effect inside. The
calls that need a human get one where the human can see what they are —
and where no human can see them at all, §2's fail-closed rule denies them
rather than parking a turn nobody can unstick.

**`concurrency: :parallel`** because a `Task` call is a whole turn of
latency, which is exactly the case the barrier was declared for.

## 5. The tool barrier

M7 declared `concurrency:` on every tool `Definition` and honored it
nowhere: the loop executed a step's tool calls one after another and the
field was documented as metadata waiting for a consumer (docs/exec.md §5,
§8). M8 is the consumer.

Within one assistant message, the loop partitions the calls into **maximal
runs** of `:parallel`-declared definitions. Each run executes under an
`Async` barrier on the one reactor (plan §8); a `:serial` call — the
default — runs alone, exactly as every call did through M7. Partitioning
into maximal runs rather than gathering all parallel calls together is
what preserves a serial call's meaning: a `:serial` call is a barrier of
one, and nothing reorders across it.

**Results append in call order regardless of completion order.** This is
not negotiable and it is not a nicety. `derive_messages` projects the
model's history from the log, and `assert_log_invariant!` digests each
outbound request against that projection (CLAUDE.md); a log whose result
order depended on which child finished first would be a log that replays
differently than it ran, and resume — which re-executes exactly the calls
the last assistant message still owes (docs/lifecycle.md, "Resuming an
open turn") — would rebuild a different history than the one that was
live. Concurrency is allowed to change *when* work happens. It is not
allowed to change what the log says happened.

Three consequences worth being explicit about:

- **A failing call does not abandon its siblings.** Each call's result is
  its own `Result`, error or not, and the barrier waits for the run. A
  tool error has always surfaced to the model as an ordinary tool result
  rather than ending a turn, and that does not change here.
- **`Loop::MAX_STEPS` still bounds the turn.** Twenty-five steps is
  twenty-five steps; parallelism makes a step wider, never longer.
- **Cancellation still lands at step boundaries, and now between runs
  rather than between calls.** A barrier is not interruptible from outside
  once it starts, so a cancel requested while five calls are in flight
  settles after that run rather than tearing fibers out of the middle of
  it. That visibly changes one behavior the socket documents: a cancelled
  batch truncates the calls that have not started, each getting a
  `tool/result` carrying `cancelled before execution` (docs/protocol.md),
  and with maximal runs there are **fewer** such results than before,
  because a run already in flight finishes. Every call in the batch still
  ends with a result either way — the projection never holds a call
  without one. The `:stopping` status (§8) exists to make that window
  visible instead of leaving a cancelled-but-still-working agent looking
  `:running`.

## 6. `ctx[:jobs]` and the `job_*` tools

A job is a subprocess that outlives the tool call that started it. The
seam lives in `terret-exec`, because it needs `ctx[:subprocess]` and
therefore `ctx[:sandbox]`: a job's argv goes through
`ctx[:sandbox].wrap` on the way to `Process.spawn` like every other spawn
in the system (docs/exec.md §2), so a job in a sandboxed profile runs
inside the container with everything else. There is no spawn path in
Terret that skips the sandbox seam, and jobs do not become the first one.

The seam a job does **not** use is `ctx[:shell]`. A shell command from
`job_start` becomes a fresh `bash -lc <command>` argv handed to
`ctx[:subprocess]`, not a `run` against the agent's persistent bash. The
two would be actively wrong together: `ctx[:shell]` is one long-lived
process per agent driven by a sentinel protocol that reads until it sees
its marker (docs/exec.md §2), so a job parked in it would hold that shell
for its entire lifetime and every subsequent `Bash` call in the session
would block behind it. The comparison to draw with `Bash` is therefore
about *wrapping*, not about the seam: `Bash` wraps once when its session
opens, while a job wraps per spawn.

```ruby
ctx[:jobs].start(argv, session:, cwd: nil)  # => opaque job id
ctx[:jobs].collect(id, session:)            # => {status:, exit_status:, output:, truncated:}
ctx[:jobs].stop(id, session:)               # SIGTERM, escalating to SIGKILL
```

`collect` drains the buffer: what it returns is what has accumulated since
the last call, with `status:` either `:running` or `:exited`. Buffers are
**byte-capped**, the same cap discipline M7 applied to command output, and
`truncated:` says so rather than quietly handing back a lie. A per-session
job cap (config, default 8) refuses the next `start` instead of letting an
agent fill the process table. An unknown id, or an id belonging to another
session, fails closed.

Jobs are **reaped on `agent/disposed`**, the event M7 declared for exactly
this class of state — per-agent runtime that no registration owns and
reversibility alone cannot collect (docs/exec.md §2, shells and
terminals). An agent's jobs go down with the agent, the same way its
shells and its terminals do.

| Tool | mutating | approval | concurrency |
|---|---|---|---|
| `job_start` | `true` | `:policy` | `:serial` |
| `job_collect` | `false` | `:never` | `:parallel` |
| `job_stop` | `true` | `:policy` | `:serial` |

`job_start` takes a `command` string, matching `Bash`'s parameter
convention rather than inventing a second one; the seam turns it into the
`bash -lc` argv above. Job tools are
snake_case because they have no Claude Code equivalent to be verbatim
with — the same rule that produced `terminal_open` in M7.

`job_start` and `job_stop` are `:policy` on a mutating tool, which means a
**subagent cannot start or stop a job** in a profile where approvals are
mounted: §2's fail-closed rule denies the call rather than parking it. A child
can still `job_collect` — that one asks nobody. Delegating "run this long
thing and watch it" therefore means the parent starts the job and the child
reads it, which is the shape that was going to be wanted anyway: the job
outlives the child, and a buffer nobody collects is the failure mode the other
arrangement produces.

### Session-scoped, and not durable

A job is a live pid plus a buffer in one process's memory. **Nothing in
the log says it exists.** It survives its turn, and it does not survive a
restart: the process that held the pid is gone, and the log — the only
thing that crosses a restart — was never told. Restart-surviving jobs are
a recorded non-goal for 0.1, not an oversight; making them durable means
answering what a job id means after the process that owned it died, and
that is a design, not a patch.

### Where at-least-once bites

Crash recovery is at-least-once for tool calls (docs/lifecycle.md,
docs/security.md): a call whose `tool/result` never reached the log may
have already run, and resume runs it again, because the log cannot tell
"ran and didn't log" from "never ran."

For `Write` that is harmlessly idempotent. For `Bash` it means a command
runs twice. For `job_start` it means something slightly worse, and it is
worth spelling out: **resume starts a second job**. The first one may
still be running, holding the first process's buffer that nobody will ever
collect; the second gets a new id and is the one the model is told about.
The harness does not detect this and does not claim to — the honest
contract is that Terret never loses a call and never invents a result for
one that has not run, and it stops there. `job_collect` is how the model
finds out: two ids where it expected one, or output that does not match
what it thinks it started. Harness-level idempotency keys remain a plan §14
item.

One inherited limit from the Docker provider applies here more than
anywhere. Signals go to the host-side `docker exec` CLI, not to the
process inside the container (docs/exec.md §4), so `job_stop` in a
sandboxed profile abandons the CLI and leaves the job running behind the
container boundary. Stopping the container is what ends it. That is a
property of the `docker exec` model rather than of this seam, and a job —
the longest-lived thing that model ever wraps — is where it shows.

## 7. `TodoWrite`

| Tool | mutating | approval | concurrency |
|---|---|---|---|
| `TodoWrite` | `false` | `:never` | `:serial` |

Parameters match Claude Code's shape exactly:

```json
{"todos": [{"content": "…", "status": "pending|in_progress|completed", "activeForm": "…"}]}
```

The handler validates the statuses, renders the list back as the tool
result, and holds **no state at all**. That echo is its only storage.

This is the smallest illustration in the codebase of what "model-visible
means logged" actually buys. The list is durable because the tool result
is durable; `derive_messages` projects it into the next request the same
way it projects every other result; a restart replays it for free; and
`resume_turn` re-derives it with no special case, because there is no
special case. A todo *service* would have been a second source of truth
that has to be reconciled with the log after every crash — and would
disagree with it eventually. There is no new event to declare, nothing to
migrate, and nothing that can drift.

One honest limit: compaction can erase it. A `session/compacted` boundary
that swallows the last `TodoWrite` result replaces it with a summary
(docs/lifecycle.md), and whether the plan survives depends on whether the
summarizer kept it. The model writes a new list; nothing is corrupted.
Say it rather than implying the list is permanent.

`concurrency: :serial` because the semantics are order-dependent — two
writes in one message mean the last one wins, and "last" should be a
property of the message rather than of which fiber returned first. An
invalid status fails closed naming the offending value, rather than
coercing it to something plausible.

## 8. Two new statuses, and one that stays reserved

Plan §6.4 specifies `idle → running → waiting_approval | waiting_input →
stopping → done/failed`. M6 built the first three and said so
(docs/lifecycle.md, "The status machine"). M8 adds two more — and not the
sixth: **`failed` is a turn status, not an agent status.** It is what
`turn/end {status}` carries when an exception left the turn, alongside
`completed`, `cancelled`, `rejected`, and `empty`; the agent that ran that
turn goes back to `:idle` and takes the next one. There is nothing for an
agent-side `:failed` slot to mean, so none is minted.

- **`:stopping`** — set when a cancel is requested, cleared when the turn
  ends. Cancellation is cooperative and honored at step boundaries (plan
  §8), so between the request and the boundary there is a real interval
  where the agent is still working and is no longer going to finish.
  Through M7 that interval was indistinguishable from `:running`. It is a
  status because that window is observable and lying about it costs an
  operator real time; the turn that closes inside it still appends the
  ordinary durable `turn/end {status: "cancelled"}`, and the agent returns
  to `:idle`.

  It interacts with `:waiting_approval`, which is the one other sub-state
  of a running turn, and the interaction is decided rather than left to
  whichever assignment runs last. The approvals gate flips an agent to
  `:waiting_approval` while a call is parked and restores it when a
  verdict lands (docs/lifecycle.md, "Durable approvals"). **That restore
  returns the agent to `:stopping` when a cancel is standing**, not to
  `:running` — a cancel requested while a call was parked has not stopped
  being true just because the human answered. Cancelling a parked turn
  denies every standing request durably (`deny_pending!`), so the parked
  fiber unparks into a turn that already knows it is stopping, and the
  status now says the same thing the turn does.
- **`:done`** — set by `dispose_agent`, terminal. A disposed agent's
  context is gone along with every effect it owned, so a later `run_turn`
  against that handle refuses rather than half-working against a dead
  fork.

**`:waiting_input` stays vocabulary and nothing more.** Plan §6.4 names
it, no consumer exists for it, and a status nothing ever sets is worse
than an absent one — it invites a client to write a branch that never
runs. It is recorded in plan §14 as reserved. The day something parks a turn on
human input rather than human approval, it gets implemented then.
