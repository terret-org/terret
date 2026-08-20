# Terret Security Posture (v1)

This is plan §13 written out as the real thing rather than four sentences.
It names Terret's threat model, the defaults each seam ships with, and —
as plainly as the rest of this house tries to be — what those defaults do
not cover. Read it alongside docs/exec.md (the seams these defaults sit
on), docs/lifecycle.md (the durable approval and hot-policy machinery the
model below depends on), and docs/protocol.md (the socket's own authority
surface, §13's other concern).

## The threat model

Tool results are data. Whatever a tool returns — a file's contents, a
command's stdout, a fetched web page — enters the session log as an
ordinary payload and rides into the next model request as an ordinary
message part. Terret never executes an instruction found inside a tool
result; the model is the only interpreter of what a tool returns, and the
only path from "a tool result contains something that looks like a
command" to "something runs" is the model choosing to call a tool in
response, exactly like any other model decision. This holds regardless of
profile.

What is not universal is whether a human stands between that model
decision and its effect. Two backstops exist, and either, both, or
neither can be in place for a given profile: durable human approval
(`ctx[:approvals]`, docs/lifecycle.md) parks a call until a human resolves
it; the hot-reloadable allow list (`Terret::Tools::AllowList`,
docs/mcp.md, docs/lifecycle.md) vetoes a call before it runs at all,
deny-by-default, driven by policy-as-code rather than a person. Terret's
primary workload is autonomous agentic systems, and that workload mostly
skips the human backstop in favor of the allow list — approvals are an
opt-in row, not the default. Say the quiet part: an autonomous profile
with a permissive allow list and `sandbox: none` has no backstop between a
prompt-injected instruction and a shell command. The sandbox (below)
bounds the blast radius when that happens; it does not prevent it.

## Sandbox defaults

`docker`, with `network: none`, is the default for untrusted work; `none`
requires explicit per-profile opt-in (plan §13, docs/exec.md §4). The
isolation the container buys is process isolation, not filesystem
isolation — the bind-mount design (docs/exec.md §1) means `ctx[:fs]`
operations run host-side against the same bytes in both worlds. A
workspace containment bug (below) is exactly as exploitable inside the
container as outside it; what the container changes is what an escaped or
malicious *process* can reach — no network by default, no view of the
host process table, no access to anything not bind-mounted.

"No network by default" is a claim about *spawned processes*, and the one
tool it does not cover is `WebFetch`: it egresses HOST-side through
Net::HTTP, so `network: none` never touches it. `WebFetch` is governed
solely by its own domain allow list (deny-by-default), plus its own SSRF
floor — it resolves each target, on the model's URL and on every redirect
hop, and refuses loopback and link-local addresses so an allowlisted name
cannot launder a fetch to `127.0.0.1` or the `169.254.169.254`
cloud-metadata endpoint. That floor is not full SSRF control: private
ranges stay reachable by default (an M8 config knob), and it is resolve-
then-connect rather than IP-pinned, so it is not DNS-rebinding protection.

`landlock` (Linux) and `seatbelt` (macOS) are named in plan §6.6 as future
providers and are not built in M7 — only `none` and `docker` exist. A
profile that needs OS-native sandboxing without a container has no seam
for it yet.

## Approval defaults

Mutating fs tools (`Write`, `Edit`) default to `:policy` — they ask a
human only where the approvals row is mounted at all, and even then only
because they are mutating; `Read`/`Glob`/`Grep` never ask. `Bash` is the
one tool whose approval is not a static default: it derives from sandbox
isolation at registration (docs/exec.md §5) — `:always` when the sandbox
is not isolating (`ctx[:sandbox].isolated?` is false), `:policy` when it
is. The reasoning is direct: outside a sandbox, arbitrary shell execution
is the least contained thing in the system and gets asked about every
single time regardless of policy; inside one, the container is already a
backstop, so `Bash` is governed like any other mutating tool instead of
specially. `WebFetch` defaults to `:policy` behind its own domain-allow
row (docs/exec.md §5).

Every one of these is a default a profile can turn off. `:policy` inside
a profile with no approvals row mounted at all reduces to the allow list
alone — stated so nobody reads "`:policy`" as a guarantee a human is
watching.

## Workspace containment

Every fs path and every workspace-relative glob is realpath-contained to
the granted `workspace:` list (docs/exec.md §3): expand, resolve the
deepest existing prefix's symlinks, require the result inside a granted
directory with a trailing-separator guard. Both traversal (`../..`) and a
symlink planted inside the workspace pointing outside it fail closed
through that same check — there is no separate traversal filter to get
out of sync with the containment logic, because both are just paths that
resolve somewhere and get checked the same way everything else does. An
empty or unconfigured workspace list denies every fs op; there is no
ungranted-but-permitted state.

Containment is the last line for fs, not the only one: every op also
dispatches an `fs/authorize` waterfall after containment passes, so a
profile can veto access to a specific path or pattern inside an
otherwise-granted workspace (docs/exec.md §2) without touching the
containment logic itself.

## Redaction

Two layers (docs/exec.md §6): a `tools/post_execute` redactor rewriting
tool results before they are logged, and a `Sessions#register_scrubber`
backstop running inside `normalize_payload` at the append boundary, so
every event type — not just tool results — gets scrubbed before it
becomes durable, and the log-invariant digest sees the same scrubbed
bytes on both sides by construction. Patterns are config (regexp sources)
until `ctx[:credentials]` (plan §6.9) lands in M8; a pattern that doesn't
match a secret's actual shape doesn't catch it. This is detection of
known shapes, not a guarantee that no credential can ever reach the log.

Four boundaries belong in any threat model built on this (docs/exec.md §6
carries the mechanism). A log is append-only, so turning a redactor on
protects what is appended afterwards and never what is already stored. A
`tools/pre_execute` veto skips the `post_execute` layer entirely, leaving
the append backstop as the only cover for that result. Ordering among
`post_execute` listeners is unpinned, so middleware registered ahead of
the redactor reads results before they are rewritten. And the log's own
structural identifiers are exempt from scrubbing by design — the exemption
covers both the identifier VALUES and the field NAMES that carry them
(`Sessions::STRUCTURAL_KEYS`), because a pattern that rewrote a tool call
id, or the `verdict` key the approvals gate reads back, would break the
session rather than protect it. A secret-shaped Hash key deeper in content
— an MCP tool's `structured_content`, say — is scrubbed like any leaf; it
is only where a structural identifier belongs that a credential a model
plants there is not caught.

## The socket's authority model

A connection's bearer token authorizes one agent completely
(docs/protocol.md) — there is no per-frame capability split. That token
can `inject`, `cancel`, resolve approvals, and — critically — `set_policy`,
replacing the very allow list that is often the only backstop an
autonomous profile has. Plan §14 records this plainly: whoever holds the
token for an agent can rewrite what that agent is allowed to do, not just
what it does next. That is a deliberate v1 stance, not an oversight left
implicit — splitting per-frame capabilities from the bearer token is real
design work that belongs with the multi-tenant story below, not with M7.
Treat a bearer token as equivalent to full operator access to that agent,
because it is.

## Multi-tenancy

Agents inside one process share a reactor and a service tree; the
isolation between them is the forked `Context` (plan §4.1), not the OS.
That is adequate for agents under common ownership — one team's fleet of
agents, none of which has reason to attack another — and it is not
adequate for mutually untrusted agents. A forked context is what is
supposed to keep one agent's tool registrations and listeners from
leaking into another's, and that guarantee has a specific gap this
milestone closes: `Registry#register` recorded its effect on the *root*
context regardless of who called it, so a tool an agent registered for
itself survived that agent's disposal (plan §14's recorded bleed). That
gap matters more now than it used to, because the tools an agent can
register carry filesystem and subprocess authority (docs/exec.md), not
just conversational state. Closing it stops one specific leak; it does
not turn a fork into a security boundary. A wedged fiber, a memory leak,
or process-wide resource exhaustion still touches every agent sharing the
process regardless. Where the work is actually mutually untrusted, the
boundary that matters is a separate process plus the sandbox
(docs/exec.md §4) — not a fork, and not this seam.

## At-least-once and idempotency

Crash recovery is at-least-once for tool calls (docs/lifecycle.md,
"Resuming an open turn"): a call whose `tool/result` never made it into
the log before the process died may have already run, in whole or in
part, and resume runs it again regardless. `Write` and `Bash` are where
this is visible rather than harmless — a repeated shell command is not
idempotent by default. Terret's contract stops at "the harness never
loses a call and never invents a fake result for one that hasn't run"; it
does not extend to "a tool never runs twice." Idempotency is the tool's
own concern in v1. Harness-level idempotency keys — a way to let a tool
declare "this call, if seen again with the same id, is a no-op" — are a
recorded M7+ candidate (plan §14), not something this milestone builds.
