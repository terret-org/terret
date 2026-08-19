# The Terret Execution World (v1)

M7 gives an agent hands: a workspace-scoped filesystem, a subprocess and
shell seam, long-lived terminals, and a sandbox boundary in front of all of
it (plan §6.6/§6.7). This is that primer, written before any of it is code.

## 1. One execution world

Two seams that could have been unrelated — file access and subprocess spawn
— share one execution world in Terret, and that sharing is the entire
reason M7's acceptance is a single patch row instead of four coordinated
ones. `ctx[:fs]` and `ctx[:subprocess]` both resolve against the same
workspace; when a config row on the sandbox seam swaps `none` for the
Docker provider (§4), every tool built on either seam moves into the
container automatically, tool code untouched (plan §12's acceptance,
literally: Read, Write, Edit, Bash, and PTY move together).

The Docker provider's design is a bind mount, and it is worth stating
plainly rather than letting a reader assume something friendlier: each
granted workspace directory is mounted into the container at the same
absolute path it has on the host. `ctx[:fs]` operations run host-side,
against that mount — the bytes Read and Write touch are literally the
host's filesystem, not a copy inside the container. What runs inside the
container is *processes*: `ctx[:subprocess]`, the shell, and the terminal
seams wrap their argv into `docker exec`, and everything a spawned process
does — reading environment variables, opening a socket, forking a child,
walking `/proc` — happens behind the container boundary. That split is not
an implementation shortcut; it is exactly where §13's threat lives. The
risk M7 defends against is untrusted *code execution*, not untrusted file
access from a trusted harness, so the container's isolation is spent where
the threat actually is. Path containment (§3) is enforced identically in
both worlds, because it never depended on which side of the sandbox
boundary the syscall runs on. `examples/exec_demo.rb` walks the concrete
proof: the demo edits a file host-side through `ctx[:fs]`, then reads it
back with `Bash` from inside the container — one file, one path, both
worlds.

## 2. The seams

Four services, one dependency chain: `ctx[:terminals]` and `ctx[:shell]`
both sit on `ctx[:subprocess]`, and `ctx[:subprocess]` sits on
`ctx[:sandbox]` (§4). `ctx[:fs]` stands alone, contained by the workspace
list (§3) rather than by the sandbox.

**`ctx[:fs]`** — `read(path)`, `write(path, content)`,
`edit(path, old, new)`, `stat(path)`, `glob(pattern)`. Every path is
realpath-contained to the granted workspace list before the op runs (§3),
and every op that passes containment also dispatches an `fs/authorize`
waterfall (`{op:, path:}`) that any plugin can veto; a `Tools::Veto` there
renders as a `Terret::Exec::Denied` tool error, the same shape containment
failures use. A listener may veto or admit only — a rewritten `:path` in a
listener's return value is ignored, so containment is never delegated to a
listener. `edit` is a uniqueness-checked string replace: it raises
`Terret::Exec::EditAmbiguous` rather than guessing when the target string
appears zero times or more than once in the file — an ambiguous edit is a
bug in the caller's plan, not something to resolve by picking the first
match. `fs.watch` is not part of v1; it stays out until a consumer needs
it.

**`ctx[:subprocess]`** — `spawn(argv, cwd:, env:, stdin:, timeout:)` and
`pty_spawn(argv)`. Every argv passes `ctx[:sandbox].wrap(argv, cwd:, tty:)`
before it reaches `Process.spawn` or `PTY.spawn` — there is no spawn path
in Terret that bypasses the sandbox seam, by construction, because nothing
else is allowed to build the final argv. Timeout is cooperative
cancellation: a deadline loop backed by `Process.wait(pid,
Process::WNOHANG)`, escalating from SIGTERM to SIGKILL after a grace
period if the child ignores the first signal. Both spawn and PTY reads
park the calling fiber rather than the thread — verified empirically on
this Ruby under `Async` (§8) — so a slow child never stalls another
agent's turn.

**`ctx[:shell]`** — one persistent bash process per key (ordinarily an
agent id), built on `pty_spawn`. `run(cmd)` drives it with a sentinel
protocol: the command is written followed by a marker that echoes the exit
status, and the shell reads until it sees the marker. Because the same
bash process serves every call for a key, `cd` and `export` from one call
are visible to the next — state persists the way a human's terminal
session would, which is the entire point of the seam existing separately
from a one-shot `spawn`. A command that times out is killed and the bash
session restarts rather than trying to recover a shell that may be in an
unknown state; the next `run` gets a fresh session, stated honestly rather
than pretended away.

**`ctx[:terminals]`** — named, long-lived PTYs, capped at `max_terminals`
(default 8). `open(name, argv)` registers a handle; `input(name, text)`
and `read(name)` round-trip against it; `close(name)` reaps the process and
is idempotent. Terminals outlive a single tool call by design — they are
how a long-running interactive process (a REPL, a dev server) stays
addressable across a turn — and an agent's disposal closes every terminal
it opened.

## 3. Workspace scoping

An agent is granted one or more directories through the `workspace:`
config row — the same list `ctx[:fs]` authorizes against and, in the
Docker world, the same list bind-mounted into the container (§1).
Containment is realpath-based, not string-based: a path is expanded, its
deepest existing prefix is resolved with `File.realpath` (so a symlink is
followed to what it actually points at), and the result must fall inside
one of the granted directories — with a trailing-separator guard, so a
workspace at `/ws` never accidentally admits `/ws-evil`.

Two escapes fail closed through that same check rather than needing
special cases: a `../` traversal resolves to wherever it actually points
before containment is checked, and a symlink created inside the workspace
that points outside it is followed to its real target before the check
runs, so both land outside the granted list and both raise
`Terret::Exec::Denied`. An empty workspace list denies everything — there
is no "no restriction configured" state that fails open.

## 4. The sandbox seam

`ctx[:sandbox]` is the seam every argv passes through before it becomes a
real process (§2). Its contract is small on purpose: `wrap(argv, cwd:,
tty:)` returns the argv actually spawned, `isolated?` reports whether that
argv runs inside a process boundary, and `workspace_ready!` is the hook a
provider uses to make sure its execution world exists before the first
spawn (a no-op for `none`; for Docker, it starts the long-lived container
if one is not already running).

`tty:` is how the calling path declares what it is. `pty_spawn` passes
`true` and `spawn` never does, because a provider that puts a terminal on
the far side of the seam has to be told when one is wanted and cannot
guess: `docker exec -i -t` against pipe stdin fails outright, so the flag
cannot simply be always-on. `none` accepts and ignores it — the host pty
the caller already holds is the terminal.

**`none`** is the identity provider: `wrap` returns its argument
unchanged, `isolated?` is `false`. It is the explicit, opt-in-only trusted
mode (§13) — a profile that wants it says so.

**`docker`** is the default-isolation provider (§13): a long-lived
container per boot, `--network none` unless config overrides it, each
workspace directory bind-mounted at the same absolute path (§1) — the
*realpath*, the same resolution `ctx[:fs]` applies to its own roots, so
both services agree on what a workspace directory is called. It runs as
the host's uid:gid by default, so files the container creates in that
read-write mount stay editable by `ctx[:fs]`; `user: nil` opts back into
root. `wrap(argv, cwd:, tty:)` turns `argv` into

```
["docker", "exec", "-i", ("-t" when tty:), "-w", cwd, container_id, *argv]
```

`-i` is always present, because without it `docker exec` does not attach
stdin at all and neither a written `stdin:` nor `ctx[:shell]`'s protocol
would reach the command. `-t` rides the PTY path only, and it is not
cosmetic: without a terminal inside the container `stty -echo` has nothing
to quiet while the host pty keeps echoing, so the echoed request line —
session sentinel and all — lands in what `ctx[:shell]` reads back as the
command's output. A `cwd` outside the granted workspace is refused rather
than relocated, because it does not exist inside the container.
`isolated?` is `true`.

Two limits are inherent to the `docker exec` model rather than to this
implementation. Environment does not cross: `spawn(env:)` configures the
docker CLI on the host, not the process inside. And neither does
cancellation — every kill signals the host-side CLI, so a timed-out
command is abandoned but keeps running inside the container, and
`ctx[:shell]`'s process-group sweep does not reach it. Stopping the
container is what ends it.

Swapping one for the other is a single patch row (plan §7) — the
mechanism M7's acceptance stands on:

```yaml
- id: sandbox
  plugin: Terret::Sandbox::Docker
  config: { image: "...", network: "none", workspace: [...] }
```

Because every tool built on `ctx[:fs]`/`ctx[:subprocess]` reaches a real
process only through this row, that one row moves Bash, Read, Write,
Edit, and PTY into the container together. No tool file changes.

## 5. The std tools and their names

Terret's std tools carry Claude Code's tool names verbatim: `Read`,
`Write`, `Edit`, `Glob`, `Grep`, `Bash`, `WebFetch`, plus four with no CC
equivalent — `terminal_open`, `terminal_input`, `terminal_read`,
`terminal_close`. There is no alias map.

That decision (plan §6.7) is not cosmetic. Orchestrator allow lists — the
`AllowList` patterns a deployment ships — are already written against CC's
names, and the pattern format they're written in (`File.fnmatch`,
case-sensitive) has already hardened around those exact strings.
`set_policy` (docs/protocol.md) ships CC-shaped patterns over the wire
today. Inventing Terret-native names would mean every existing allow list
needs a translation layer that does nothing but rename, forever. The
`mcp__server__tool` double-underscore namespace (docs/mcp.md) is untouched
by this — it names a different kind of tool source, and MCP tools keep
their own convention.

| Tool | mutating | approval | concurrency |
|---|---|---|---|
| `Read` | `false` | `:never` | `:parallel` |
| `Glob` | `false` | `:never` | `:parallel` |
| `Grep` | `false` | `:never` | `:parallel` |
| `Write` | `true` | `:policy` | `:serial` |
| `Edit` | `true` | `:policy` | `:serial` |
| `Bash` | `true` | `:always` unsandboxed / `:policy` sandboxed | `:serial` |
| `WebFetch` | `false` | `:policy` | `:serial` |
| `terminal_open`/`input`/`read`/`close` | `true` | `:policy` | `:serial` |

`WebFetch` is the one tool in this roster that does **not** move into the
container with the others: it egresses host-side through Net::HTTP, so a
sandbox row's `network:` mode does not govern it. It is bounded instead by
its own deny-by-default domain allow list and an SSRF floor that refuses
loopback and link-local targets (docs/security.md); everything else here
runs behind `ctx[:sandbox]`.

`Bash`'s approval is the one entry in this table that is not a static
value: it is derived from `ctx[:sandbox].isolated?` **at registration
time** (§13 — outside a sandbox, an agent that can run arbitrary shell
commands needs a human every time; inside one, the container is already a
backstop, so `Bash` is declared like any other mutating tool instead of
specially). That derivation is captured once, at registration, not read
live on every call — which matters when the sandbox changes hot: the
std-tools service listens for `config/updated`, re-derives the verdict,
and re-registers `Bash` when it has moved, rather than leaving a stale
value in place after a live sandbox swap.

What that derivation changes today is what the Definition **declares**,
not what a caller experiences. The only consumer is the approvals gate,
whose rule is `always || (policy && mutating)` — and `Bash` is mutating in
both states, so `:policy` and `:always` park it identically. The
distinction is real metadata that a future consumer can act on (an M8
candidate: a gate that treats `:policy` as "ask once per session" or
defers to per-agent policy while `:always` keeps asking every time), and
`gems/terret-core/test/approvals_test.rb` pins the present collapse so
that the day the two stop behaving alike is a deliberate one. Until then,
do not read this row as "a sandbox makes `Bash` stop asking".

`concurrency:` is declared metadata, not yet enforced. The loop keeps
executing every call in a step sequentially in M7; the field exists so
M8's tool barrier has something honest to read when it starts letting
`:parallel`-declared calls actually run concurrently. `task`, `job_*`, and
`todo` are M8 tools (they need `ctx[:jobs]` and the subagent seam) and are
not in this roster.

## 6. Redaction

Two layers, doing different jobs. `tools/post_execute` is a waterfall
every tool result already passes through
(docs/terret-implementation-plan.md §6.3); a redactor listening there
rewrites a `Result`'s content and error before either becomes the durable
`tool/result` payload, catching the common case — a tool that happened to return a
credential — before it is ever logged.

That is not sufficient on its own, because a secret can enter the log
through a path that never touches a tool result at all — a `user/message`,
a `context/injected` steer, a plugin event. The backstop is
`Sessions#register_scrubber(callable)`, an effect (like a prompt section —
disposing unregisters it) that runs over every String value inside
`normalize_payload`, the append boundary every event of every type passes
through. Because the scrubber runs there rather than downstream of it,
both sides of the log invariant see identical, already-scrubbed bytes: the
stored event and every projection derived from it (`derive_messages`, the
digest `assert_log_invariant!` checks a request against) agree by
construction, not by two independent redaction passes that could drift
apart. This is deliberate: putting the scrubber inside `normalize_payload`,
rather than as a read-time filter over the projection, is what keeps
CLAUDE.md's "model-visible means logged" invariant honest — a filtered
*read* would mean the log itself still held the secret.

The scrubber does not reach two kinds of value, both deliberately. It
skips the log's own structural identifiers — tool call ids, the part tag
`decode_part` dispatches on, lineage, verdicts, the live allow list
(`Sessions::STRUCTURAL_KEYS`) — because a pattern generic enough to match
a credential matches a hex id too, and collapsing two tool call ids into
one replacement token is a request every provider rejects, permanently, in
an append-only log. That exemption is positional rather than by name: it
holds at the top of a payload and inside an `assistant/message`'s encoded
parts, and stops the moment anything content-bearing is entered, so the
`args[:content]` a `Write` call carries is scrubbed like any other text.
A tool NAME is deliberately not on that list: the model chooses it, so it
is content, and redacting one fails safe — the name stops resolving and
the call comes back as a not-found error, where a collapsed id would
instead poison the session for good.

Streamed text is the other adjustment, and it costs something worth
naming. A provider's deltas break at token boundaries, so a secret split
across two of them defeats a pattern that matches it perfectly — and a
scrubber can only be trusted with text it sees whole. So whenever any
scrubber is registered, the loop holds an entire run of assistant text and
appends it as ONE `assistant/chunk` event when the run ends (a tool call,
the message stop, or the end of the stream). Mount a redactor and the
chunk log stops carrying live token-by-token progress for that agent;
that is the trade, and it is affordable only because chunks are
replay/UI fidelity — `derive_messages` never projects them, so the digest
is untouched, and only their concatenation is contractual. With no
scrubber registered nothing changes: chunks stay delta-for-delta what the
provider sent. A stream that raises mid-run loses that run's chunks
entirely; `run_turn` closes the failed turn, so no `assistant/message`
lands for that step either and the two logs agree.

One split survives that: a secret straddling a RUN boundary, where a model
emits a tool call partway through a credential, still reassembles from the
two chunks either side of it. What that costs is bounded — the
authoritative `assistant/message` is scrubbed whole, so the model's own
context never carries the secret, and only a reader concatenating raw
chunk events can recover it. It is a far narrower hole than the
token-boundary split it replaced, which leaked on every stream long enough
to have one.

Four more limits worth stating plainly. Enabling a redactor does not
redact history already in the log — the log is append-only, so the
scrubber governs what is appended from that moment on and nothing before
it. A `tools/pre_execute` veto short-circuits `tools/post_execute`
entirely, so a vetoed call's result is covered by the append backstop
alone. Ordering among `post_execute` listeners is not pinned: middleware
registered ahead of the redactor sees unredacted results, and a contract
for that ordering is an M8 note rather than something to assume. And
resume refuses to replay an owed tool call whose stored name OR arguments
carry the replacement token, because re-running a command with a
substituted literal is a different command (§7) — and a redacted name
would otherwise come back as "no such tool", telling a model its roster is
broken when the log simply rewrote its own record. Only the redactor's own
token is recognized, so a scrubber registered directly with some other
replacement does not trigger that refusal.

Patterns are config — regexp source strings, compiled by the redactor
plugin — until `ctx[:credentials]` (plan §6.9) lands in M8 and can drive
them from something more structured. State that limit rather than
implying the redaction is comprehensive: it catches known shapes, not
unknown ones.

Pick the replacement token with tool names in mind. A deployment whose
patterns could plausibly match a tool name wants a token matching
`[A-Za-z0-9_-]+` rather than the default `[REDACTED]`, because a redacted
name travels into the function names of projected assistant history —
permanently, the log being append-only — and a provider may reject a
function name carrying brackets. An over-broad pattern also rewrites words
inside the refusal message resume appends, which is merely cosmetic and
has the same cure: patterns narrow enough to match credentials and not
prose.

## 7. Destructive tools and at-least-once

The M6 resume contract (docs/lifecycle.md, "Resuming an open turn") is
at-least-once for tool calls: a crash between a tool's side effect and its
logged `tool/result` means resume re-executes the call, because the log
cannot tell the difference between "ran and didn't log" and "never ran."
That contract has real teeth here. `Write` and `Bash` are exactly the
tools where "ran twice" is observable — a re-run `Write` overwrites its
own prior output (harmlessly idempotent, as it happens), while a re-run
`Bash` command re-executes whatever shell command the model asked for,
verbatim, a second time. Terret does not paper over this: idempotency is
the tool's own concern, not something the harness guarantees.
Harness-level idempotency keys remain a recorded M7+ item (plan §14), not
built here.

## 8. Concurrency

One reactor, no user-facing threads (plan §8): every agent's turn, every
tool call, and every subprocess spawn or PTY read runs as an `Async` task
on the same Fiber scheduler. That only works if a blocking call actually
yields the fiber rather than the thread, and that is not something Ruby
guarantees for free — it was verified empirically on this Ruby rather than
assumed: `PTY.spawn`'s IO reads and `Process.wait` park only the calling
fiber under `Async` (a ticker fiber kept ticking through a blocking read in
the probe), the same way `Thread::Queue#pop` already did for M6's parking
primitive. A tool seam that turned out not to cooperate would stall every
agent in the process on the first slow child, which is why this was proven
rather than trusted.

`concurrency:` metadata (§5) is declared now and honored by nobody yet —
the loop executes a step's tool calls sequentially through M7, and M8's
tool barrier is what will let `:parallel`-declared calls (`Read`, `Glob`,
`Grep`) actually run at once. `Loop::MAX_STEPS` (docs/lifecycle.md) still
bounds a turn the same way it always has; a tool-heavy turn that leans on
Bash and terminals in a loop is bounded by the same 25-step ceiling as any
other.
</content>
