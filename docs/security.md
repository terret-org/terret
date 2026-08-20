# Terret Security Posture (v1)

This is plan §13 written out in full, not the four-sentence version. It names
Terret's threat model, the defaults each seam ships with, and what those
defaults do not cover, stated as plainly as the rest of this house tries to
be. Read it alongside docs/exec.md (the seams these defaults sit on),
docs/lifecycle.md (the durable approval and hot-policy machinery the model
below depends on), and docs/protocol.md (the socket's own authority surface,
§13's other concern).

## The threat model

Tool results are data. Whatever a tool returns (a file's contents, a
command's stdout, a fetched web page) enters the session log as an ordinary
payload and rides into the next model request as an ordinary message part.
Terret never executes an instruction found inside a tool result; the model is
the only interpreter of what a tool returns, and the only path from "a tool
result contains something that looks like a command" to "something runs" is
the model choosing to call a tool in response, exactly like any other model
decision. This holds regardless of profile.

Whether a human stands between that model decision and its effect varies by
profile. Two backstops exist, and either, both, or neither can be in place:
durable human approval (`ctx[:approvals]`, docs/lifecycle.md) parks a call
until a human resolves it; the hot-reloadable allow list
(`Terret::Tools::AllowList`, docs/mcp.md, docs/lifecycle.md) vetoes a call
before it runs at all, deny-by-default, driven by policy-as-code with no
person in the loop. Terret's primary workload is autonomous agentic systems,
and that workload mostly skips the human backstop in favor of the allow list.
Approvals are an opt-in row, not the default. An autonomous profile with a
permissive allow list and `sandbox: none` has no backstop between a
prompt-injected instruction and a shell command. The sandbox (below) bounds
the blast radius when that happens; it does not prevent it.

## The tool floor

The deny-by-default allow list is enforced as an *authoritative floor*, a
single predicate the tool registry consults after the `pre_execute`
waterfall has run, on the exact call about to execute, rewrites included.
That is a different thing from one `tools/pre_execute` listener among
peers: no other row's listener can register ahead of the floor and
short-circuit past it, so it stays unbypassable regardless of listener
registration order. The bug that motivated this was real: mounted in a
later loader pass, the floor once sat behind a no-inject row's listener in
the waterfall, and a listener that admitted a call without delegating
never reached it. As the registry gate now, the floor sees every admitted
call, and its veto is final.

The consequence is a one-way valve. A `pre_execute` listener can make policy
*stricter* (a veto there stops the call) but never looser. An admission it
returns cannot resurrect a tool the floor denies, because that admission is
exactly what the floor gate re-checks before execution. A per-agent
`AllowList` (docs/mcp.md, docs/lifecycle.md) rides the agent's forked context
as such a listener, so it can only *narrow* what the gate would already
admit. A veto it adds is honored; an admission it returns cannot lift a
denial the gate makes. Deny-by-default is the ground state, and nothing a row
registers, in any order, can widen it.

`install_floor`, which replaces that gate, is a *privileged plugin
capability*. A mounted plugin can install or replace the floor, consistent
with the rest of this house: a mounted plugin is trusted code the operator
chose to boot (see the consent model below). A model, a tool result, and a
socket frame cannot reach it. A second install replacing an active floor now
warns; a legitimate re-mount or hot reconfigure disposes the old floor first
and stays silent. An unexpected swap of the autonomous safety mechanism
leaves a trace.

The *patterns* the gate enforces are a separate matter from the gate itself.
They are the per-session, hot-reloadable policy: the last durable
`policy/updated` in the session, or the bundle's install-time floor when a
session never updated (docs/lifecycle.md). A bearer token can rewrite them
for its agent over the socket via `set_policy`, which changes what the gate
admits for that one session; it does not, and cannot, replace the gate. That
token authority is the socket's concern, below.

## Sandbox defaults

`docker`, with `network: none`, is the default for untrusted work; `none`
requires explicit per-profile opt-in (plan §13, docs/exec.md §4). The
isolation the container buys is process isolation. It is not filesystem
isolation: the bind-mount design (docs/exec.md §1) means `ctx[:fs]`
operations run host-side against the same bytes in both worlds. A workspace
containment bug (below) is exactly as exploitable inside the container as
outside it. What the container changes is what an escaped or malicious
*process* can reach: no network by default, no view of the host process
table, no access to anything not bind-mounted.

"No network by default" is a claim about *spawned processes*, and the one
tool it does not cover is `WebFetch`: it egresses HOST-side through
Net::HTTP, so `network: none` never touches it. `WebFetch` is governed solely
by its own domain allow list (deny-by-default), plus its own SSRF floor. That
floor resolves each target, on the model's URL and on every redirect hop, and
refuses loopback and link-local addresses, so an allowlisted name cannot
launder a fetch to `127.0.0.1` or the `169.254.169.254` cloud-metadata
endpoint. The floor resolves the bracket-*stripped* hostname, so an IPv6
bracket literal such as `[::1]` is caught the same way `127.0.0.1` always
was. `uri.host` keeps the brackets, which no resolver recognizes; the check
uses `uri.hostname` instead, which strips them. The domain policy
(allow/deny) is a separate, coarser thing: it matches an IPv6 literal only
when the pattern spells it *bracketed* (`[::1]`), because it globs the host
as written and never resolves it. The floor is what stops the IPv6 loopback
reach; the domain policy is IP-as-hostname string matching.

That floor is not full SSRF control on three counts. Private ranges stay
reachable by default: a `block_private_ranges` knob to close them is a
recorded §14 deferral (M9). It is resolve-then-connect; it does not pin the
IP, so it offers no DNS-rebinding protection (also §14). `WebFetch` also has
per-phase timeouts but no total wall-clock deadline, so a slowloris-shaped
server can hold a fiber longer than any single phase allows. In practice
that's bounded by `MAX_REDIRECTS × timeout`, recorded in §14.

`landlock` (Linux) and `seatbelt` (macOS) are named in plan §6.6 as future
providers. They are not built in M7; only `none` and `docker` exist. A
profile that needs OS-native sandboxing without a container has no seam for
it yet.

## Approval defaults

Mutating fs tools (`Write`, `Edit`) default to `:policy`: they ask a human
only where the approvals row is mounted at all, and even then only because
they are mutating. `Read`/`Glob`/`Grep` never ask. Two tools have an approval
that is *not* a static default. `Bash` and `job_start` both derive theirs
from sandbox isolation at registration (docs/exec.md §5): `:always` when the
sandbox is not isolating (`ctx[:sandbox].isolated?` is false), `:policy` when
it is. The reasoning is the same for both. `job_start` runs `bash -lc <cmd>`
in a fresh shell, so outside a sandbox it is arbitrary shell execution
exactly as `Bash` is, and gets asked about every time regardless of policy.
Inside one, the container is already a backstop, so each is governed like any
other mutating tool, with no special case. Both captures are re-derived
through the `config/updated` listener on a hot sandbox swap, so neither is
left at the weaker bar after the isolation underneath it changes.
(`job_collect` reads a buffer and never asks; `job_stop` is a static
`:policy`.) `WebFetch` defaults to `:policy` behind its own domain-allow row
(docs/exec.md §5).

Every one of these is a default a profile can turn off. `:policy` inside a
profile with no approvals row mounted at all reduces to the allow list alone.
Nobody should read `:policy` as a guarantee a human is watching.

## Workspace containment

Every fs path and every workspace-relative glob is realpath-contained to the
granted `workspace:` list (docs/exec.md §3): expand, resolve the deepest
existing prefix's symlinks, require the result inside a granted directory
with a trailing-separator guard. Both traversal (`../..`) and a symlink
planted inside the workspace pointing outside it fail closed through that
same check. There is no separate traversal filter to get out of sync with the
containment logic; both are just paths that resolve somewhere and get checked
the same way everything else does. An empty or unconfigured workspace list
denies every fs op; there is no ungranted-but-permitted state.

Containment is the last line for fs; every op also dispatches an
`fs/authorize` waterfall after containment passes, so a profile can veto
access to a specific path or pattern inside an otherwise-granted workspace
(docs/exec.md §2) without touching the containment logic itself.

## Redaction

Two layers (docs/exec.md §6): a `tools/post_execute` redactor rewriting tool
results before they are logged, and a `Sessions#register_scrubber` backstop
running inside `normalize_payload` at the append boundary. Every event type
gets scrubbed before it becomes durable, tool results included, and the
log-invariant digest sees the same scrubbed bytes on both sides by
construction.

The redactor's patterns are config, regexp source strings, so they catch
known *shapes*. A pattern that doesn't match a secret's actual shape doesn't
catch it. This is detection of known shapes, not a guarantee that no
credential can ever reach the log. What closes that gap for a credential the
harness resolved is `ctx[:credentials]`, below.

`ctx[:credentials]` (plan §6.9) now exists, and its security point is exactly
that loop. It resolves a provider's secret ENV-first by convention
(`<PROVIDER>_API_KEY`), then from an optional AES-256-GCM file store, master
key in `TERRET_CREDENTIALS_KEY`. A store present with no key REFUSES; it
never falls back to anything unprotected. ENV always wins. Every value it
resolves is fed to the append-boundary scrubber
(`Sessions#register_scrubber`) as an exact-string pattern, so a resolved
credential is caught by its literal bytes. A deployment doesn't need to have
named its shape in advance, even if a tool echoes it straight back into a
result. The on-disk store format is documented in `credentials.rb`; a
`trt credentials set` writer CLI and an OS-keychain backend are deferred
(§14), so today a deployment writes the store itself.

Four boundaries belong in any threat model built on this (docs/exec.md §6
carries the mechanism). A log is append-only, so turning a redactor on
protects what is appended afterwards and never what is already stored. A
`tools/pre_execute` veto skips the `post_execute` layer entirely. The append
backstop is the only cover for that result. Ordering among `post_execute`
listeners is unpinned, so middleware registered ahead of the redactor reads
results before they are rewritten. The log's own structural identifiers are
exempt from scrubbing by design. The exemption covers both the identifier
VALUES and the field NAMES that carry them (`Sessions::STRUCTURAL_KEYS`),
because a pattern that rewrote a tool call id, or the `verdict` key the
approvals gate reads back, would break the session, not protect it. A
secret-shaped Hash key deeper in content (an MCP tool's `structured_content`,
say) is scrubbed like any leaf. It is only where a structural identifier
belongs that a credential a model plants there is not caught. Folding keys
has one fail-closed corner: two content keys in the same mapping that redact
to the *same* token would collide. The append raises: it never silently drops
one. The turn fails, no secret leaks, and the cost is a low-grade denial of
service a model would have to engineer against itself.

## The socket's authority model

A connection's bearer token authorizes one agent completely
(docs/protocol.md); there is no per-frame capability split. That token can
`inject`, `cancel`, resolve approvals, and `set_policy`, replacing the very
allow list that is often the only backstop an autonomous profile has. Plan
§14 records this plainly: whoever holds the token for an agent can rewrite
what that agent is allowed to do, a power that reaches well past choosing its
next action. That is a deliberate v1 stance. Splitting per-frame capabilities
from the bearer token is real design work that belongs with the
multi-tenant story below, not with M7. Treat a bearer token as equivalent
to full operator access to that agent, because it is.

Replay is the socket's other authority surface. It is bounded: a reconnect's
`from_seq` cannot make the server read an unbounded history. Two caps enforce
it. `replay_limit` (default 10,000) pulls a from_seq reaching further back
than the window forward to the newest `replay_limit` events, and tells the
client so with a `replay_truncated` frame. `max_concurrent_replays` (default
4) gates how many replays read the log at once, so a burst of reconnects
cannot stampede it. This is the concrete cap plan §9.4 promised; the wire
detail lives in docs/protocol.md.

## The consent model

Config is data; code is consent. A Terret profile is portable configuration
an operator may have downloaded from anywhere, so the two places a profile
could smuggle in code execution are both gated behind an explicit
`--allow-config-ruby` flag (docs/composition.md, §5): a `!ruby` scalar, and a
`plugins:` entry that names a filesystem PATH instead of a load-path feature
name. Requiring a path is code execution with a YAML extension: it reaches
Ruby the operator never installed. It needs the same consent the `!ruby` tag
does. A load-path feature name (`terret/exec`) is different: it resolves only
through gems the operator's Bundler already put on the path, so it requires
no flag.

A bundle's own `requires:` are not gated the same way, and the asymmetry is
deliberate. A bundle ships inside an installed gem: it is the
operator-installed gem's own trusted decision about what to load before its
rows resolve, whereas a profile is config that merely names bundles. Trust
follows installation, not authorship of a YAML file.

`doctor` is safe-by-default: it resolves and reports on a profile's rows
without booting. By default it refuses a path-shaped `plugins:` require; it
does not run it. (It still loads load-path feature names, which are
operator-installed code.) `trt doctor <untrusted profile>` inspects the
profile. It does not execute the code the profile carries.

## Multi-tenancy

Agents inside one process share a reactor and a service tree; the isolation
between them is the forked `Context` (plan §4.1), not the OS. That is
adequate for agents under common ownership: one team's fleet of agents, none
of which has reason to attack another. It is not adequate for mutually
untrusted agents. A forked context is what is supposed to keep one agent's
tool registrations and listeners from leaking into another's, and that
guarantee has a specific gap this milestone closes: `Registry#register`
recorded its effect on the *root* context regardless of who called it, so a
tool an agent registered for itself survived that agent's disposal (plan
§14's recorded bleed). That gap matters more now than it used to, because the
tools an agent can register carry filesystem and subprocess authority
(docs/exec.md), beyond conversational state. Closing it stops one specific
leak; it does not turn a fork into a security boundary. A wedged fiber, a
memory leak, or process-wide resource exhaustion still touches every agent
sharing the process. Where the work is mutually untrusted, the boundary that
matters is a separate process plus the sandbox (docs/exec.md §4), not a fork
and not this seam.

## At-least-once and idempotency

Crash recovery is at-least-once for tool calls (docs/lifecycle.md, "Resuming
an open turn"): a call whose `tool/result` never made it into the log before
the process died may have already run, in whole or in part, and resume runs
it again regardless. `Write` and `Bash` are where this is visible, not
harmless: a repeated shell command is not idempotent by default. Terret's
contract stops at "the harness never loses a call and never invents a fake
result for one that hasn't run"; it does not extend to "a tool never runs
twice." Idempotency is the tool's own concern in v1. Harness-level
idempotency keys, a way to let a tool declare "this call, if seen again with
the same id, is a no-op," are a recorded M7+ candidate (plan §14). This
milestone does not build them.