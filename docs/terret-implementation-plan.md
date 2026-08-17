# Terret: Implementation Plan

**A Ruby-native, model-agnostic agent harness, informed by DeepSeek Harness (`dsh`)**

Version 0.3, August 2026
Status: Design document. M0 and M1 are shipped; see §12 for what is actually built.

---

## 1. Executive Summary

DeepSeek Harness (`dsh`) demonstrated that an agent harness can be built where *everything is a plugin*: the model adapter, the tool registry, the session log, and the agent loop itself are replaceable plugins mounted into a shared context, powered by the Cordis framework. Nothing in that architecture is TypeScript-specific. Its essential ideas translate cleanly to Ruby, and in several places Ruby's strengths (blocks, open modules, Zeitwerk autoloading, Fiber-based structured concurrency) make the design simpler than the original.

**Terret** is that translation: a modular harness for driving any LLM through a plugin kernel called **Hames**. The name comes from harness tack. A *terret* is the ring on a harness through which the driving reins pass, the small load-bearing component that lets one driver guide any horse. *Hames* are the rigid curved pieces that transfer the pulling force. The metaphor holds: the kernel bears the load, the harness guides any model.

This document covers research findings on `dsh`, the architecture mapped to Ruby, the gem layout, each core subsystem's interface design, the event vocabulary and turn flow, the configuration system, the concurrency model, testing strategy, tooling, a phased milestone plan with acceptance criteria, and open questions.

### Naming

Primary: **Terret**. The `terret`, `terret-core`, and `hames` names are registered on RubyGems and the project lives at `github.com/terret-org/terret` with `terret.org` as its home. Alternates held in reserve, all from harness tack: **Crupper**, **Surcingle**, **Breeching**. **Martingale** was rejected for a finance collision. A trademark search (USPTO TESS and EUIPO) is still outstanding, since "Terret" is also a wine grape variety, which carries low collision risk for software.

### Goals

1. **Model-agnostic by construction.** No provider is privileged. v1 reaches every model through a single OpenRouter adapter, and the seam it sits behind is the same one native adapters will use later.
2. **Everything is a plugin.** The agent loop, tool registry, session store, sandbox policy, prompt assembly, and every interface are plugins mounted in a Hames context. There is no privileged core to patch.
3. **Replayable truth.** Anything the model saw must be reconstructable from the append-only session log, enforced by a runtime invariant.
4. **Ruby-idiomatic.** Zeitwerk, `Data` value objects, keyword args, blocks for effects, Fiber-based structured concurrency via the `async` ecosystem. It should feel like good Ruby rather than transliterated TypeScript.
5. **Built for long-lived agents.** The first workload is a session that stays open indefinitely, wakes on external stimulus, and is steered while running. Terret's primary interface is a bidirectional event stream over a WebSocket, one connection per agent, shipped as a plugin. See §9.
6. **Embeddable.** Terret must run as a long-lived multi-agent process and as a library inside an existing Rails app.

### Non-Goals (v1)

- Training, fine-tuning, or eval benchmarking. That is a different kind of "harness"; see §17 on the naming collision with EleutherAI's lm-evaluation-harness.
- **An interactive text CLI.** Explicitly deferred. A human-facing TUI is not on the roadmap and should not be built speculatively.
- **Command-line compatibility with any other harness.** Terret does not implement Claude Code's `-p` streaming-JSON contract or anyone else's. Terret is the harness, so serializing NDJSON over a pipe to reach it would be ceremony rather than architecture. Consumers connect over the socket in §9. This costs a side-by-side comparison against an incumbent on live traffic; §14 records how to recover some of that confidence.
- Native adapters for individual providers. OpenRouter covers the model space for v1; see §6.5.
- A native desktop app.
- Windows support beyond WSL2. Sandbox seams assume POSIX; revisit post-1.0.
- Multi-tenant SaaS concerns beyond a bearer token on the local server.

---

## 2. Research Summary: What `dsh` Actually Is

Findings from the repository (README, `docs/architecture.md`, `docs/cordis-primer.md`), distilled to what matters for a port.

### 2.1 Cordis, the substrate

Cordis is a plugin framework built on five ideas, each of which Terret must reproduce or consciously replace:

1. **A plugin is an object implementing a service lifecycle**, either a function with `inject` plus `apply(ctx)`, or a Service subclass mounted into a context.
2. **A context is a repository of services.** A service claims a stable key (`ctx.tools`, `ctx.llm`, `ctx.sessions`); consumers find capabilities by key and never by importing a concrete class.
3. **Dependencies are declared via `inject`.** A plugin naming required services waits until they exist, so boot order emerges from the dependency graph rather than a manual sequence.
4. **Typed events with four dispatch modes:** `emit` (fire-and-forget, ordered), `waterfall` (around-middleware with `next()`, return values propagate), `parallel` (awaited, concurrent fan-out), `serial` (awaited, ordered, returns a value). The mode is part of each event's public contract.
5. **Registrations are reversible effects.** Every registration installs through an effect that returns a disposer, so plugin reload and unload unwind cleanly and hot-reload is safe.

### 2.2 Composition: profiles, bundles, patches

A running `dsh` is a plugin tree composed at boot from ordered layers. A **profile** names a composition and lists **bundles**, which are distribution formats for config rows plus the code they mount. Layers apply in order: each bundle, then the profile's patch file, then the home-level patch, then any `--patch` overlay. A patch targets a config row by id and replaces its config wholesale or inserts rows. `dsh --dump-config` prints the fully resolved tree. The base bundle carries model adapters, tools, persistence, sandbox and approval policy, settings, credentials, and telemetry.

### 2.3 Core packages and their `ctx` keys

| dsh package | Owns | ctx key |
|---|---|---|
| core/session | Append-only SessionEvent log + in-memory store | `ctx.sessions` |
| core/system-prompt | Prompt-section and tool-schema assembly | `ctx.systemPrompt` |
| core/tools | Scoped tool registry + guarded execution pipeline | `ctx.tools` |
| core/agent | Agent interface, live registry, `agent/*` events | `ctx.agents` |
| core/agent-loop | Default driver implementing the Agent interface | `ctx.agentLoop` |
| core/scope | Per-agent scoped-registration primitive | (library) |
| llm/llm | Message/stream vocabulary + adapter seam | `ctx.llm` |

### 2.4 The turn flow

A **step** is one model request plus the tool calls it makes. A **turn** is zero or more steps: it opens before the first input is claimed and closes when nothing is owed. The canonical flow:

```
turn/start
  claim next-step input + one queued message
  assemble prompt sections + tool schemas
  -> agent/pre-step            (waterfall: reject | enter(messages))
     step/start
     append entered messages as user/message
     derive model history from the log
     agent/request -> llm/stream -> assistant/chunk* -> assistant/message
     tool/call* -> tools/pre-execute -> tools/execute -> tools/post-execute -> tool/result*
     step/end
     (tools owe another request, or new input arrived) -> next step
  -> agent/turn-stopping       (serial, no next())
turn/end
```

`turn/*`, `step/*`, `user/message`, `assistant/*`, and `tool/*` are **durable session events**; the rest are live extension points. `agent/pre-step`, `agent/request`, `llm/stream`, and the three `tools/*` events are waterfalls. Input reaches the driver through one inbox, and injected context waits in the inbox until a waking message arrives.

### 2.5 The session log invariant

The log is the source of the model's context. `deriveMessages()` projects model history from it, while raw `assistant/chunk` events preserve replay and UI fidelity. Fork, resume, transcripts, telemetry, and persistence all derive from this stream. **Model-visible means logged.** A runtime invariant asserts that anything reaching a model request is reconstructable from the log, which is why new model-visible input requires a new session event type.

### 2.6 Capability seams

A **seam** is a Service Definition (interface) plus a Service Provider (implementation) plus a Consumer (usually a model-facing tool). One provider swap changes the whole product: filesystem and subprocess providers share one execution world, so pointing them at a remote sandbox moves Bash, PTY, and LSP together with no forks. Documented seams include `ctx.llm` (adapters), `ctx.tools`, `ctx.shell`, `ctx.subprocess`, `ctx.terminals`, `ctx.fs`, `ctx.sandbox`, `ctx.commands`, `ctx.jobs`, `ctx.goals`, `ctx.sessionTitle`, and subagent providers, plus `ctx.sessions.fork` for live forking, `agent.inject()` for context injection, and per-agent scoped registration via `agent.ctx`.

### 2.7 What we deliberately do differently

- **Language substrate.** There is no Cordis to vendor, so we build **Hames**, a small kernel purpose-built for Ruby, rather than porting Cordis's TypeScript declaration-merging type system. Ruby gives up compile-time event typing; we recover safety with runtime event contracts (§4.4) and RBS signatures.
- **Monorepo tooling.** pnpm workspaces become a Bundler monorepo of path-referenced gems with a shared Rakefile.
- **Provider strategy.** dsh ships native adapters per provider. Terret v1 ships one OpenRouter adapter instead, which reaches the same model space for a fraction of the surface area (§6.5).
- **First interface.** dsh ships a TUI and a browser app. Terret ships neither at first. Its first interface is a WebSocket event stream (§9), because the immediate consumer is an orchestrator driving long-lived agents rather than a human at a terminal.
- **Concurrency.** Node's event loop becomes Ruby's Fiber scheduler via `async`. Every agent runs in its own Async task tree, and cancellation is structured (§8).

---

## 3. Architecture at a Glance

```
                        ┌─────────────────────────────────────────┐
                        │              Interfaces                 │
                        │  terret-ws: bidirectional event stream, │
                        │  one socket per agent (plugin)          │
                        │  Rails engine · ACP · web console       │
                        └───────────────┬─────────────────────────┘
                                        │ drives ctx.agents, renders session/event
        ┌───────────────────────────────┼────────────────────────────────┐
        │                        Hames Context Tree                      │
        │                                                                │
        │  ctx.sessions   ctx.prompt    ctx.tools     ctx.agents         │
        │  (event log)    (assembly)    (registry+    (registry+         │
        │                                pipeline)     lifecycle)        │
        │                                                                │
        │  ctx.llm        ctx.loop      ctx.fs        ctx.subprocess     │
        │  (OpenRouter)   (default      ctx.shell     ctx.sandbox        │
        │                  driver)      ctx.terminals ctx.jobs           │
        │                                                                │
        │  ctx.commands   ctx.goals     ctx.subagents ctx.credentials    │
        │  ctx.settings   ctx.telemetry ctx.titler    ctx.approvals      │
        └────────────────────────────────────────────────────────────────┘
                                        │
                    composed at boot from ordered layers:
          base bundle → interface bundle(s) → profile patch → home patch → --patch
```

---

## 4. Hames: The Kernel

Hames is Terret's Cordis. It is a standalone gem with zero knowledge of LLMs, reusable for any plugin-composed Ruby application. Keeping it ignorant of the domain is what keeps "everything is a plugin" honest.

### 4.1 Context and Services

A `Hames::Context` is a repository of services and an event bus. Services claim stable keys; consumers resolve by key.

```ruby
class Terret::Tools::Registry < Hames::Service
  service_key :tools                 # claims ctx.tools
  inject :sessions, :prompt          # waits until these exist

  def start(ctx)
    @definitions = {}
    ctx.effect { install_builtin_events }   # returns disposer
  end
end
```

Design decisions:

- `Hames::Service` is a class with lifecycle hooks (`start`, `stop`), a claimed key, and declared injections. A bare plugin can also be any object responding to `apply(ctx)`, the functional form, with optional `inject`. Both mount into the tree identically.
- `ctx.tools` resolution uses `method_missing` backed by a registry with `respond_to_missing?`, plus an RBS interface file generated per release so editors and type checkers see real methods. A `ctx[:tools]` indexer is the canonical metaprogramming-free form.
- **Fork semantics.** `ctx.fork` produces a child context inheriting parent services with copy-on-write registration scopes. Per-agent isolation (`agent.ctx`) is a fork whose registrations dispose when the agent ends. This is the port of dsh's `core/scope`.
- **Isolation realms.** A service row in config may declare `isolate: [:tools]`, giving a subtree its own instance of that service. That is how an agent preset gets a different capability set.

### 4.2 Plugins as reversible effects

Every registration flows through `ctx.effect`, which takes a block performing side effects and returning a disposer:

```ruby
ctx.effect do
  ctx.tools.register(schema)
  -> { ctx.tools.unregister(schema.name) }
end

ctx.on("tools/pre_execute") { |call, next_| ... }   # auto-disposed listener
```

Unloading a plugin disposes its effects in reverse order. This single rule is what makes hot-reload and runtime config patching safe. Rule of thumb ported directly from Cordis: if teardown order matters, keep the related work in one effect.

### 4.3 Events and dispatch modes

Hames reproduces all four Cordis dispatch modes with identical semantics:

| Mode | Ruby dispatch | Awaited | Return value | Use for |
|---|---|---|---|---|
| `emit` | `ctx.emit(name, *args)` | No | No | Notifications (`session/event`) |
| `waterfall` | `ctx.waterfall(name, *args)` | No | Yes | Around-middleware (`agent/request`, `tools/execute`) |
| `parallel` | `ctx.parallel(name, *args)` | Yes (Async barrier) | No | Fan-out hooks |
| `serial` | `ctx.serial(name, *args)` | Yes | Yes | Ordered decisions (`agent/turn_stopping`) |

Waterfall semantics are the load-bearing subtlety and must match Cordis exactly. A listener receives `(*args, next_)`. Calling `next_.()` delegates, possibly with rewritten args, and its return value propagates. Returning without calling `next_` short-circuits, which is the design for single-decision policy events. `prepend: true` is supported but discouraged. In Ruby the natural spelling is a block whose last parameter is the continuation:

```ruby
ctx.on("agent/pre_step", mode: :waterfall) do |claim, next_|
  return Claim.reject(reason: "budget exceeded") if over_budget?(claim)
  next_.(claim.with(messages: redact(claim.messages)))
end
```

### 4.4 Runtime event contracts (replacing declaration merging)

Cordis gets event typing from TypeScript declaration merging; Ruby needs a different mechanism. Every event is declared once with its mode and payload shape:

```ruby
Hames.event "tools/pre_execute", mode: :waterfall,
  payload: Terret::Tools::Call    # a Data class
```

The bus rejects dispatch of undeclared events and dispatch via the wrong mode. Dev and test raise; production logs. A `rake events:catalog` task generates `docs/events.md` listing every event, its mode, and its description, and CI diffs it so the contract cannot drift silently. Payload shapes are `Data` classes with RBS signatures.

### 4.5 Dependency-driven boot

The loader mounts plugins in dependency order derived from `inject` declarations. Missing services park the plugin until the service appears, which is what lets a patch insert a provider later in the layer stack than its consumers. Cycles are a boot error with the cycle printed. `--dump-config` prints the fully resolved, layer-annotated tree.

---

## 5. Repository and Gem Layout

One monorepo, many gems, versioned in lockstep. Bundler workspace via path sources during development.

```
terret/
├── Gemfile / Gemfile.lock          # workspace: path-sourced gems
├── Rakefile                        # build, test-all, events:catalog, release
├── .ruby-version / mise.toml       # latest Ruby 4
├── CLAUDE.md                       # agent-facing dev guide
├── docs/
│   ├── terret-implementation-plan.md  # this document, maintained
│   ├── hames-primer.md
│   ├── events.md                   # generated catalog
│   ├── protocol.md                 # the headless wire contract (§9)
│   ├── config-catalog.md           # generated from settings schemas
│   └── cookbook/                   # adding-a-tool, adding-a-provider, ...
├── gems/
│   ├── hames/                      # the kernel (no LLM knowledge)
│   ├── terret-core/                # sessions, prompt, tools, agents, loop, llm seam
│   ├── terret-openrouter/          # the one v1 adapter
│   ├── terret-ws/                  # bidirectional event stream over WebSocket
│   ├── terret-exec/                # fs, subprocess, shell, terminals seams
│   ├── terret-sandbox-docker/
│   ├── terret-sandbox-landlock/    # Linux; macOS seatbelt variant
│   ├── terret-tools-std/           # read/write/edit/bash/grep/glob/fetch...
│   ├── terret-mcp/                 # MCP client (stdio + HTTP) as tool source
│   ├── terret-acp/                 # Agent Client Protocol server (editors)
│   ├── terret-store-sqlite/        # session persistence provider
│   └── terret/                     # meta-gem: profiles, boot
├── bundles/                        # config rows shipped by each bundle
└── examples/
```

Gem dependency direction is strictly downward. Interface gems depend on core; core depends on `hames`; `hames` depends on `async` and stdlib only. Each gem declares its Terret contribution in gemspec metadata (`metadata["terret"] = { "bundle" => "config/bundle.yml" }`), the port of dsh's `package.json` `dsh` field. That is how third-party gems become discoverable bundles.

Note the departures from the v0.1 layout. The per-provider adapter gems are gone, collapsed into `terret-openrouter`. The `terret-llm` vocabulary gem is gone, folded into `terret-core` where it already lives. `terret-web` and `terret-headless` are replaced by `terret-ws`. A web console may return later as its own bundle, consuming the same event stream, without touching core.

That `terret-ws` is a gem alongside the others rather than a privileged part of core is load-bearing. The primary interface mounts through the same seams as everything else, which is the standing proof that the plugin claim in §1 is real.

---

## 6. Core Subsystems

### 6.1 Session log (`ctx.sessions`)

The heart. An append-only log of `SessionEvent`s per session, with an in-memory store and pluggable persistence.

- **Event envelope:** `Data.define(:id, :session_id, :seq, :at, :type, :payload, :parent_id)`, where `seq` is a per-session monotonic integer and `parent_id` supports forking.
- **Durable event types:** `turn/start`, `turn/end`, `step/start`, `step/end`, `user/message`, `assistant/chunk`, `assistant/message`, `tool/call`, `tool/result`, `session/created`, `session/forked`, `session/titled`, `context/injected`, `approval/requested`, `approval/resolved`. The set is open: plugins extend the event map via `Hames.event "session/x", durable: true` and must provide a projection for `derive_messages`.
- **`derive_messages(session, upto: nil)`** projects provider-neutral model history from the log. This is the only path by which context reaches an adapter.
- **The invariant, enforced.** Before each request the loop computes a digest of the outbound message list and asserts it equals the digest of `derive_messages` replayed from persisted events. In dev and test a mismatch raises `Terret::LogInvariantViolation`; in production it emits a high-severity telemetry event. This is the mechanical form of "model-visible means logged."
- **Persistence seam:** in-memory (default for tests), JSONL-per-session (default for headless runs, greppable), SQLite (default for the session daemon; WAL mode, one writer Fiber per session). Providers implement `append(event)`, `read(session_id, from_seq:)`, `stream(session_id)` returning an Async queue, and `fork(source, boundary_seq, child_id)`.
- **Fork and resume.** `ctx.sessions.fork(source, boundary: seq)` copies events up to the boundary under a new session id, with `session/forked` recording lineage. Resume loads events, replays derived state, and reopens the inbox. Resume is load-bearing for §9, where an orchestrator reconnects to a session by id.
- Everything downstream (transcripts, telemetry, titling, the protocol surface) consumes the same `session/event` emission. There are no side channels.

### 6.2 Prompt assembly (`ctx.prompt`)

Plugins register **prompt sections** (name, priority, block returning content or nil) and the tool registry contributes schemas. Per step, assembly collects sections for this agent's scope, orders by priority, renders against a `PromptEnv` (agent, session, workdir, model capabilities), then runs a cache-stability pass so that stable section ordering and byte-identical rendering let provider prompt caching actually hit. Sections are effects, so unloading a plugin removes its section from the prompt.

A long-lived agent needs its persona set once at session creation and amended over the session's life without a restart. Both are ordinary prompt sections at reserved priorities, and because sections are effects, amending one is a registration swap rather than a special case.

### 6.3 Tool registry and guarded pipeline (`ctx.tools`)

- **Definition:** name, description, JSON Schema params, handler, and metadata for `mutating:`, `concurrency: :safe|:exclusive`, and `approval: :never|:policy|:always`.
- **Registration is scoped:** global via `ctx.tools.register`, or per-agent via `agent.ctx.tools.register`, so subagents and presets get different tool sets without global state.
- **Pipeline (waterfalls):** `tools/pre_execute` for validation, approval gating, argument rewriting, and policy veto; `tools/execute` where a provider may replace execution entirely, which is how a remote sandbox takes over Bash without forking the tool; `tools/post_execute` for result truncation, redaction, and telemetry. `tool/call` and `tool/result` are the durable bookends.
- **Allowlisting.** A declarative allow list, expressed as config rather than a flag string, gates which tools an agent may call at all. It supports wildcards for namespaced tool sources (for example `mcp__nexus__*`). An unlisted tool is denied rather than prompted. It is a `tools/pre_execute` listener rather than a special case in the registry, which is what lets a per-agent allow list ride on the agent's forked context.
- **Approvals.** A `ctx.approvals` service. When policy requires it, the pipeline parks the call, emits durable `approval/requested`, and resumes on `approval/resolved`. Parked calls survive process restarts because both sides are in the log.
- **Concurrent tool calls.** Calls in one assistant message run in an Async barrier honoring each tool's concurrency class; `:exclusive` tools serialize.

### 6.4 Agents and the loop (`ctx.agents`, `ctx.loop`)

- **`Agent`** is an interface: an id, a session, an **inbox** (single Async queue), a status machine (`idle → running → waiting_approval | waiting_input → stopping → done/failed`), `inject(content, wake: false)` for context injection queued until a waking message arrives, and `cancel(reason)`.
- **`ctx.loop`** is the default driver implementing the turn flow in §2.4, translated event for event, with Ruby names using underscores (`agent/pre_step`, `agent/turn_stopping`). It is itself a plugin, so a research harness can replace the driver (tree-of-thought, multi-model debate, graph execution) while every tool, adapter, and interface keeps working. This is the single most important portability property to preserve.
- **Turn accounting.** A rejected or empty first claim still closes a durable turn that spent no step, so the log records the attempt. This matters for observability.
- **Subagents (`ctx.subagents`):** one interface, multiple providers. A fresh child agent in a forked context is the default; a delegated turn to an external agent over ACP and a pooled worker are alternatives. The `task` tool consumes the seam.
- **Goals (`ctx.goals`):** same-session objective tracking that continues work through `agent/*` events. v1 is minimal: persist a goal and offer a `goal_status` tool.

### 6.5 LLM seam (`ctx.llm`)

- **Vocabulary:** provider-neutral `Data` types. `Message(role:, parts:)` with parts `Text`, `ToolCall(id:, name:, args:)`, `ToolResult(id:, content:, error:)`, `Image`, and `Thinking(content:, signature:)`; a `StreamEvent` union of `MessageStart`, `TextDelta`, `ThinkingDelta`, `ToolCallStart/Delta/End`, `Usage`, `MessageStop`, and `StreamError`.
- **Adapter contract:** `capabilities` (tools, vision, thinking, caching, max context), `count_tokens(messages)` with a heuristic fallback provided, and `stream(request) { |event| ... }` yielding `StreamEvent`s from within an Async task. Retries with jittered backoff, 429 and overload handling, and mid-stream error surfacing (`StreamError`, after which the loop decides retry versus fail-turn) live in a shared `AdapterBase`.
- **`llm/stream` is a waterfall** wrapping every request, so middleware can rewrite requests (model routing, caching headers, failover chains, cost caps) or replace the stream entirely for record and replay.
- **v1 ships exactly one adapter: OpenRouter.** It is OpenAI-compatible, so a single implementation reaches Anthropic, OpenAI, Google, DeepSeek, Mistral, and the long tail of open models, with routing and failover handled upstream. Model roles (`main`, `titler`, `subagent`, `cheap`) map to OpenRouter model strings, so pointing a role at a different vendor is a config edit. This is the concrete meaning of model-agnostic for v1: the seam is provider-neutral even though only one provider implementation exists behind it.
- **Known costs of the OpenRouter-only choice.** Provider-specific features degrade to whatever OpenRouter normalizes. Prompt caching and interleaved thinking are the two that matter for §15, and their passthrough is uneven across upstream vendors. Treat both as best-effort in v1 and verify per model rather than assuming. A native adapter can be added later behind the same seam without touching the loop, which is the point of the seam.
- **Transport:** `async-http` for native SSE streaming on the Fiber scheduler, with no thread per request. The adapter is thin rather than a wrapper around `ruby_llm` or `langchainrb`, which keeps the streaming seam exact.

### 6.6 Execution world (`terret-exec` + sandbox gems)

The seam trio, ported intact. **`ctx.fs`** handles read, write, stat, glob, and watch behind a provider, with `fs/*` policy events for path allow and deny. **`ctx.subprocess`** puts spawn and PTY behind a provider. **`ctx.shell`** builds persistent bash sessions on subprocess. **`ctx.terminals`** manages long-lived PTYs and the terminal tool. Because fs and subprocess share one execution world, swapping in the Docker provider moves all of Read, Write, Edit, Bash, and PTY into the container together, with no per-tool forks. **`ctx.sandbox`** wraps argv before spawn, with providers `none` (trusted), `docker` (default isolation), `landlock` (Linux), and `seatbelt` (macOS). Local PTY uses the `pty` stdlib inside Async.

Workspace scoping belongs here too. An agent is granted one or more directories it may touch, and that list is a config row consumed by the fs provider's policy.

### 6.7 Standard tools (`terret-tools-std`)

v1 set: `read_file`, `write_file`, `edit_file` (string replace with a uniqueness check), `glob`, `grep` (ripgrep when present, pure-Ruby fallback), `bash`, `terminal_*`, `web_fetch`, `task` (subagent), `job_start/collect/stop` for background work via `ctx.jobs`, and `todo` for plan tracking. Each tool is its own plugin file, and each declares mutating, concurrency, and approval metadata honestly, because policy hangs off it.

Tool naming matters more than it looks. An orchestrator's allow lists are written against Claude Code's tool names (`Read`, `Edit`, `Bash`, `Glob`, `Grep`), so the std tools should either carry those names or ship a documented alias map. Decide this before the allow-list format sets.

### 6.8 Interop: MCP and ACP

- **`terret-mcp`** is an MCP *client* connecting stdio and streamable-HTTP servers. Discovered tools register into `ctx.tools` under a namespace with per-server approval policy, and resources become prompt sections on demand. This is not a late-stage nicety. An orchestrator that delivers a legate's entire tool roster as MCP servers cannot use Terret at all without it, so MCP is v1 scope (§12).
- **`terret-acp`** is an Agent Client Protocol server so ACP editors can drive a Terret agent, plus an ACP client subagent provider so Terret can delegate to other agents. Both are interfaces over `ctx.agents` and `session/event`, which is proof the core seams are right.

### 6.9 Commands, settings, credentials, telemetry, titling

`ctx.commands` dispatches human slash-commands without a model turn. `ctx.settings` provides layered config access with schema validation per plugin, feeding the generated config catalog. `ctx.credentials` is a keyring-style store (encrypted file by default, OS keychain optional) where adapters resolve keys by provider name and ENV always wins. `ctx.telemetry` derives OpenTelemetry-compatible spans and events from the session stream, with a pluggable exporter, off by default. `ctx.titler` is a sole-provider seam generating session titles with the `titler` model role.

---

## 7. Composition: Profiles, Bundles, Patches

Direct port of the dsh layering model, YAML-native.

- **Bundle:** a gem shipping `config/bundle.yml`, an ordered list of config rows each shaped `{id, plugin, config, disabled}`. `terret-base` inside the meta-gem is layer one of every profile: the adapter, std tools, persistence, sandbox and approval policy, settings, credentials, telemetry.
- **Profile:** a named composition in Terret home (`~/.terret/profiles/<name>/profile.yml`) listing the bundles it stacks, out-of-tree plugins it installs, and its `patch.yml`. A `headless` profile ships as the template.
- **Layer order:** bundles in listed order, then profile `patch.yml`, then `~/.terret/patch.yml`, then `--patch file.yml` overlays. A patch targets a row by id and replaces its whole config, never deep-merging, since wholesale replacement avoids merge ambiguity. It may also insert new rows with `after:` and `before:` anchors.
- **Dynamic values:** tagged scalars evaluated in a sandboxed binding at mount time, such as `!env OPENROUTER_API_KEY` and `!setting sandbox.image`. A `!ruby` tag requires `--allow-config-ruby`, off by default, because config is data first.
- **Introspection:** `--dump-config` prints the resolved tree annotated with which layer contributed each row. A `doctor` check validates every row's config against its plugin's schema before boot.

Example patch, swapping the execution world onto Docker and pointing the main role at a different model:

```yaml
# ~/.terret/profiles/headless/patch.yml
rows:
  - id: sandbox
    plugin: terret-sandbox-docker
    config: { image: "terret/sandbox:latest", network: none }
  - id: llm.main
    config: { model: "anthropic/claude-opus-4.5" }
```

## 8. Concurrency Model

- **Substrate:** `async` on the Fiber scheduler. The process runs one reactor, and each agent is an Async task tree: inbox reader, turn task, per-step stream task, and tool barrier. There are no user-facing threads, and SQLite writes go through a per-session writer task.
- **Structured cancellation:** `agent.cancel` stops the task tree top-down. The in-flight HTTP stream closes, running tools receive a cooperative `Cancellation` token with subprocess tools escalating SIGTERM to SIGKILL, and a durable `turn/end(status: cancelled)` is appended.
- **Backpressure:** `assistant/chunk` fan-out to consumers goes through bounded queues, so a slow reader drops to snapshot-then-tail rather than stalling the loop.
- **Why not Ractors:** adapters and tools need shared services, so Ractor isolation buys nothing here and costs everything. Rare CPU-heavy work can use a thread pool behind `ctx.jobs`.

## 9. Interfaces

The v1 interface is a bidirectional event stream over a WebSocket, shipped as a plugin. There is no interactive CLI (§1 Non-Goals), and there is no compatibility layer for any other harness's command-line contract.

### 9.1 Why a socket, and why a plugin

The first real workload is a long-lived agent: one session that stays open for days, wakes on external stimulus, does work, and goes quiet again. That shape wants a persistent duplex connection rather than a process invocation. A run-shaped interface would force the session to be reconstructed from storage on every wake, and would push liveness questions (is this agent still there? can I steer it right now?) out into a supervisor that has to guess.

A socket answers those questions structurally. The connection *is* the liveness signal. Steering is a frame rather than a side channel. Nothing has to be torn down between wakes.

It ships as a plugin (`terret-ws`) rather than as core, and that is the point of the architecture rather than a detail. If the primary interface cannot be a plugin, "everything is a plugin" is decoration. Anything the socket can do, another interface can do by mounting a different bundle against the same seams.

### 9.2 Shape

One connection per agent. The connection carries an agent id and a bearer token, resolves or creates that agent's session, and binds to the agent's **forked context** (§4.1). Registrations made on behalf of that connection dispose when the agent ends, which is exactly what the fork primitive was ported from dsh to provide.

Many agents share one process and one reactor. Each is an Async task tree (§8), so agent count is bounded by memory and model concurrency rather than by process table.

**Server to client.** Every durable session event, serialized as-is. The socket is a `session/event` listener like every other consumer in §6.1, so it invents no vocabulary of its own and adds no second source of truth. Nothing reaches a client that is not in the log first.

**Client to server.** A small, closed set of frames, each of which lands on an existing seam rather than a new code path:

| Frame | Lands on |
|---|---|
| `inject` (text, `wake:`) | `agent.inject` and the inbox (§6.4) |
| `cancel` (reason) | `agent.cancel`, structured cancellation (§8) |
| `approve` / `deny` (call id) | durable `approval/resolved` (§6.3) |
| `set_model` (role, model) | the model-role config row (§6.5) |
| `subscribe` (`from_seq:`) | replay-then-tail (§9.3) |

That list is deliberately short. A frame that cannot be expressed as one of these is a sign the seam is missing, and the fix belongs in the seam rather than in the socket.

### 9.3 Reconnect is the hard part, and the log already solves it

Sockets drop. Deploys, idle timeouts, and network blips all end connections that the agent's life should outlast, so the protocol has to make reconnection boring.

A client reconnects and sends `subscribe` with the highest `seq` it has durably recorded. The server replays from `sessions.read(session_id, from_seq:)` and then tails live. The signature in §6.1 already exists for this. Because `seq` is a per-session monotonic integer and the log is append-only, this is exact rather than best-effort: no gaps, no duplicates that the client cannot dedupe, no negotiation.

Backpressure follows the same rule as §8. A slow reader drains to a bounded queue, and a client that falls too far behind is dropped and told to resubscribe with its last `seq` rather than being allowed to stall the loop. Snapshot-then-tail and reconnect-then-replay are the same mechanism.

**The agent's liveness is independent of the socket.** A dropped connection must never cancel a turn or fail a run. Work continues, events accumulate in the log, and a reconnecting client catches up. Only an explicit `cancel` frame stops an agent. Getting this wrong in the other direction, by tying agent lifetime to connection lifetime, would make every deploy an outage.

### 9.4 Operational notes

Long-lived sockets behind a load balancer need a heartbeat, since idle timeouts will otherwise close healthy connections. Ping frames on an interval below the balancer's idle timeout, with the timeout treated as configuration rather than an assumption.

Auth is a bearer token presented at connection time and checked before the agent is resolved. Authorization is per-agent: a token scoped to one agent cannot subscribe to another's stream, because the stream carries everything the model saw.

Reconnect storms after a deploy are the predictable failure mode. Jittered client backoff, plus a server-side cap on concurrent replays, since replay reads the log and a thundering herd of full-history replays is the expensive case.

### 9.5 Later, if warranted

A web console rendering the live transcript, which is a second consumer of the same event stream and therefore mostly free. An ACP server (§6.8). A Rails engine exposing `Terret.boot(profile:)` for embedding agents in an existing app. None is v1. An interactive TUI remains out of scope.

## 10. Dependency Choices

| Concern | Choice | Notes |
|---|---|---|
| Ruby | latest 4.x | `Data`, Fiber scheduler maturity, YJIT; pinned in `.ruby-version` and `mise.toml` |
| Kernel deps | stdlib + `async` | hames stays tiny |
| HTTP/SSE | `async-http` | native fiber streaming |
| WebSocket | `async-websocket` | §9; same reactor as everything else |
| Autoload | `zeitwerk` | per-gem loaders |
| Config validation | `dry-schema` | also generates config catalog + tool JSON Schemas |
| SQLite | `sqlite3` (WAL) | store gem only |
| JSON | `oj` (optional) fallback stdlib | hot path: chunk events and protocol lines |
| Types | RBS + Steep in CI | signatures for public seams |
| Lint | RuboCop | |
| Docs | YARD; generated events.md / config-catalog.md | CI-diffed |

One entry is new: `async-websocket` carries §9, which keeps the socket on the same Fiber reactor as the adapter streams and the tool barriers rather than introducing a second concurrency model. Two entries from v0.1 are gone. There is no CLI framework dependency, since there is no CLI. There is no web framework in the core path, since the console is deferred.

The shipped code currently uses minitest rather than RSpec, and the LLM vocabulary lives in `terret-core` rather than a separate gem. Both are settled; §11 reflects the first.

## 11. Testing Strategy

- **Kernel unit tests** covering dispatch modes (waterfall short-circuit, prepend, disposal order), fork and isolate semantics, loader ordering, and hot-unload.
- **Loop tests against a scripted adapter.** A `FakeAdapter` driven by declarative scripts makes turn-flow tests deterministic and fast, and every event sequence in §2.4 gets a golden-order test.
- **Log invariant property tests.** Generate random plugin sets that inject context and rewrite claims, then assert the `derive_messages` digest always matches the outbound request.
- **Socket protocol tests.** The highest-value tests in v1, and they should be written before the implementation they check. Drive a connection with recorded client frames and assert the emitted event stream matches golden files, covering a plain turn, a multi-step tool turn, a mid-turn steer, a denied tool, and a cancellation. Then the cases that only a persistent connection has: a drop mid-turn where the agent must keep working, a reconnect with `from_seq` that yields no gap and no unexpected duplicate, a slow reader that gets dropped rather than stalling the loop, and a `cancel` racing a `result`.
- **Adapter contract suite.** One shared behavior run against the adapter with recorded SSE cassettes (VCR mangles streaming, so a custom cassette recorder is needed), plus a live smoke lane behind an env key.
- **Tool and sandbox integration.** Docker-based tests in CI on Linux runners, landlock tests on a Linux matrix, and snapshot tests for prompt assembly, since byte-stable rendering is a test rather than an aspiration when caching depends on it.
- **Bench lane.** Track chunk throughput and per-event dispatch overhead so kernel changes cannot silently regress streaming.

## 12. Milestones

Each phase ends with demoable acceptance criteria. No estimates are given; sequencing is what matters here, and the ordering below is the plan's main claim.

**M0. Spike. SHIPPED.** Hames event bus, effects, and waterfall semantics proven. *Accepted:* dispatch-mode test matrix green, disposal order proven.

**M1. Kernel and boot. SHIPPED.** Full Hames: services, inject-driven boot, fork, event contracts, patch layering. *Accepted:* Cordis primer semantics reproduced in tests, events catalog generation working.

**M2. Log, loop, and the OpenRouter adapter. PARTIALLY SHIPPED.** Session log with the invariant, `derive_messages`, prompt assembly, tool registry and pipeline, the default loop, and in-memory plus JSONL stores are all built and tested against `FakeAdapter`. What remains is the OpenRouter adapter itself and `async-http` streaming. *Accept:* a multi-step tool turn completes against a real model, golden event-order tests stay green, and the invariant survives an injected-context property test.

**M3. Durable sessions.** SQLite store, `read(session_id, from_seq:)`, load-and-replay resume, session fork. Nothing user-visible ships here, which is why it is easy to skip and why skipping it would be a mistake: every guarantee in §9.3 rests on this being exact. *Accept:* a session survives a process restart and resumes with byte-identical derived context, and a replay from an arbitrary `seq` yields the same events as a live tail from that point.

**M4. The socket.** `terret-ws`: one connection per agent bound to a forked context, durable events out, the five client frames in §9.2 in, `from_seq` replay-then-tail, bounded-queue backpressure, heartbeat, bearer auth. *Accept:* the socket protocol tests pass, including the connection-drop cases; an agent survives a client disconnect mid-turn and the reconnecting client sees no gap.

**M5. MCP client.** stdio and streamable-HTTP servers mounted as tool sources under a namespace, with per-server policy and a strict mode that ignores ambient config, plus the declarative per-agent allow list. *Accept:* an agent whose entire tool roster arrives from MCP servers works under policy, driven over the socket.

**M6. Long-lived agent hardening.** Everything a session that runs for weeks needs and a short run does not: context compaction, durable approvals resolved over the socket, wake-on-stimulus semantics through the inbox, titling, and cost accounting per session. *Accept:* an agent runs across many wakes and a deploy without losing derived context, and a parked approval resolves after a restart.

**M7. Execution world.** fs, subprocess, shell, and terminals seams; std tools; sandbox `none` and `docker`; workspace scoping. *Accept:* one patch row moves bash, read, write, and PTY into a container with zero tool changes.

**M8. Subagents, then 0.1 release.** The `task` tool over the subagent seam, background jobs, ACP server, docs and cookbook, `doctor`, the bench lane, the security pass in §13, RubyGems release, and an example third-party plugin gem published from a separate repo to prove the extension story.

The ordering is the plan's main claim, so the reasoning is worth stating plainly. Durable sessions come before the socket because reconnect correctness is a property of the log rather than of the transport, and building the socket first would mean discovering that the hard way. MCP comes early because an agent whose tool roster arrives over MCP is the launch workload, and no amount of transport substitutes for it. The execution world moves late for the same reason: that agent needs no local fs or subprocess access at all. Multi-provider adapter work left the roadmap, absorbed by OpenRouter. The interactive CLI and command-line compatibility both left the roadmap entirely.

## 13. Security Posture

Sandbox `docker` with `network: none` is the default for untrusted work, and `none` requires explicit opt-in per profile. Approval policy defaults to `:policy` for mutating fs tools, `:always` for bash outside a sandbox, and `:policy` inside. Credentials never enter the session log, enforced by redaction in `tools/post_execute` plus a log-append scrubber. `web_fetch` gets an allow and deny domain policy row.

The socket adds concerns of its own. A connection's bearer token authorizes exactly one agent, because the stream it subscribes to carries everything that agent's model saw, which is the most sensitive artifact in the system. Authorization is checked before the agent is resolved, so a bad token cannot probe which agent ids exist. Replay is capped per connection, since an unbounded `from_seq` request is a cheap way to make the server read an entire history.

Multi-tenancy inside one process is the structural risk. Agents share a reactor and a service tree, so isolation rests on the forked context in §4.1 rather than on the OS. That is adequate for agents under common ownership and inadequate for mutually untrusted ones. Where untrusted execution is required, the boundary is a separate process with the sandbox in §6.6, not a fork.

Prompt-injection stance: tool results are data. The loop never executes instructions from tool output except through the model, and the approval seam is the human backstop. Document this threat model explicitly in `docs/security.md`.

## 14. Risks and Open Questions

- **Waterfall ergonomics in Ruby.** Explicit `next_.()` is unfamiliar. The M0 spike validated the API feel before it fossilized, and it held up. Fallback if it sours: a `throw`/`catch` short-circuit sugar.
- **No side-by-side proving path.** Declining command-line compatibility means the first time Terret drives a real agent is also the first time anything depends on it. Recover some of that confidence cheaply: capture an incumbent harness's event stream on live traffic, replay the same stimulus into Terret offline, and diff the derived context rather than the wire bytes. That compares the thing that matters (what the model saw) without shipping a compatibility layer that would then need deleting.
- **Blast radius of one process.** Many agents on one reactor means one wedged Fiber, one memory leak, or one deploy can affect every agent on the box. A run-per-process model spreads that risk at the cost of everything §9.1 argues for. Mitigate with per-agent supervision inside the reactor, a hard cap on agents per process, and shard by process before shipping the cap as a tuning knob.
- **Long-session context growth.** A session measured in weeks outgrows any context window, so compaction is not a nicety and it interacts directly with the §2.5 invariant: a compacted history is still model-visible, so it must be logged as its own durable event rather than computed on the fly. Design the event before the feature.
- **OpenRouter as a single point of failure.** One adapter means one vendor relationship, one rate limiter, and one normalization layer standing between Terret and every model. The seam makes a native adapter cheap to add, but it is worth knowing this is a deliberate concentration of risk rather than an oversight.
- **Feature passthrough through OpenRouter.** Prompt caching and interleaved thinking are the two §15 claims most likely to degrade. Verify per model rather than assuming, and be willing to demote a claim rather than defend it.
- **Fiber-scheduler edge cases** in `sqlite3` and `pty` under load. Mitigate with the writer-task pattern and soak tests during M5.
- **Event typing without a compiler.** Runtime contracts plus CI catalog diffing is the bet. If drift still bites, add a Steep-checked events RBS generated from declarations.
- **Tool naming.** Whether std tools carry Claude Code's names or an alias map is unresolved and blocks nothing until M5, but it should be settled before allow-list formats harden.
- **Open:** should `hames` move to its own repo, for a cleaner story at the cost of more overhead? Should the meta-gem vendor a pinned bundle version map?

## 15. What "Cutting Edge" Means Here, Concretely

Agents that live for weeks on one session log, steerable mid-turn over a live connection, surviving disconnects and deploys without losing derived context. Interleaved thinking blocks preserved as first-class message parts and replayed. Provider prompt caching made reliable by byte-stable prompt assembly. Mid-conversation model switching on one session log. Structured cancellation. Parked approvals that survive restarts. MCP interop. A replaceable agent loop.

Each of these follows from two disciplines: everything is a plugin, and model-visible means logged. Keep those two and the rest stays honest. Note that the first two on this list are the ones most exposed to §14's passthrough risk, so they are claims to verify rather than assume.

## 16. Immediate Next Actions

1. Finish M2: the OpenRouter adapter over `async-http`, replacing `FakeAdapter` in the demo path.
2. Write `docs/protocol.md` capturing the §9 frame set and the reconnect contract precisely, then the socket protocol tests from §11, both before the M4 implementation. Primer-first is one of dsh's better exports.
3. Decide the compaction event now rather than at M6, since §14 makes it an invariant question rather than a feature.
4. Write `docs/hames-primer.md`, still outstanding from the original plan.
5. Run the trademark search (§1 Naming), the last unchecked item from the original launch list.

## 17. Appendix: Naming Landscape

"Harness" in ML also means eval harnesses such as EleutherAI's lm-evaluation-harness, so Terret's docs should say "agent harness" in the first sentence everywhere. Tack-derived candidates: Terret (chosen, the rein-guiding ring, short and pronounceable and unclaimed), Hames (the kernel, the load-bearing arcs), Crupper and Surcingle and Breeching (reserve), Martingale (rejected for a finance collision).
