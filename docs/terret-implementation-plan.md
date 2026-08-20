# Terret: Implementation Plan

**A Ruby-native, model-agnostic agent harness, informed by DeepSeek Harness (`dsh`)**

Version 0.5, August 2026
Status: Design document. M0–M5 are shipped; see §12 for what shipped.

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
4. **Ruby-idiomatic.** Zeitwerk, `Data` value objects, keyword args, blocks for effects, Fiber-based structured concurrency via the `async` ecosystem. It should feel like good Ruby, not transliterated TypeScript.
5. **Built for long-lived agents.** The first workload is a session that stays open indefinitely, wakes on external stimulus, and is steered while running. Terret's primary interface is a bidirectional event stream over a WebSocket, one connection per agent, shipped as a plugin. See §9.
6. **Embeddable.** Terret must run as a long-lived multi-agent process and as a library inside an existing Rails app.

### Non-Goals (v1)

- Training, fine-tuning, or eval benchmarking. That is a different kind of "harness"; see §17 on the naming collision with EleutherAI's lm-evaluation-harness.
- **An interactive text CLI.** Explicitly deferred: no human-facing TUI is on
  the roadmap, and none should be built ahead of real demand.
- **Command-line compatibility with any other harness.** Terret does not
  implement Claude Code's `-p` streaming-JSON contract or anyone else's. Terret
  is the harness, so serializing NDJSON over a pipe to reach it would just be
  ceremony. Consumers connect over the socket in §9. This costs a side-by-side
  comparison against an incumbent on live traffic; §14 records how to recover
  some of that confidence.
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
3. **Dependencies are declared via `inject`.** A plugin naming required services waits until they exist, so boot order emerges from the dependency graph instead of a manual sequence.
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

- **Language substrate.** There is no Cordis to vendor. **Hames** is a small
  kernel purpose-built for Ruby instead of a port of Cordis's TypeScript
  declaration-merging type system. Ruby gives up compile-time event typing;
  runtime event contracts (§4.4) and RBS signatures recover the safety.
- **Monorepo tooling.** pnpm workspaces become a Bundler monorepo of path-referenced gems with a shared Rakefile.
- **Provider strategy.** dsh ships native adapters per provider. Terret v1 ships one OpenRouter adapter instead, which reaches the same model space for a fraction of the surface area (§6.5).
- **First interface.** dsh ships a TUI and a browser app. Terret ships neither at first. Its first interface is a WebSocket event stream (§9), because the immediate consumer is an orchestrator driving long-lived agents, not a human at a terminal.
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

The v0.1 layout looked different in three ways: the per-provider adapter gems
collapsed into `terret-openrouter`, the `terret-llm` vocabulary gem folded
into `terret-core`, where it already lives, and `terret-web` and
`terret-headless` gave way to `terret-ws`. A web console may return later as
its own bundle, consuming the same event stream, without touching core.

That `terret-ws` is a gem alongside the others, not a privileged part of core, is load-bearing. The primary interface mounts through the same seams as everything else, which is the standing proof that the plugin claim in §1 is real.

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

Plugins register **prompt sections** (name, priority, block returning content or nil) and the tool registry contributes schemas. Per step, assembly collects sections for this agent's scope, orders by priority, renders against a `PromptEnv` (agent, session, workdir, model capabilities), then runs a cache-stability pass so that stable section ordering and byte-identical rendering let provider prompt caching hit. Sections are effects, so unloading a plugin removes its section from the prompt.

A long-lived agent needs its persona set once at session creation and amended over the session's life without a restart. Both are ordinary prompt sections at reserved priorities, and because sections are effects, amending one is a registration swap, not a special case.

### 6.3 Tool registry and guarded pipeline (`ctx.tools`)

- **Definition:** name, description, JSON Schema params, handler, and metadata for `mutating:`, `concurrency: :safe|:exclusive`, and `approval: :never|:policy|:always`.
- **Registration is scoped:** global via `ctx.tools.register`, or per-agent via `agent.ctx.tools.register`, so subagents and presets get different tool sets without global state.
- **Pipeline (waterfalls):** `tools/pre_execute` for validation, approval gating, argument rewriting, and policy veto; `tools/execute` where a provider may replace execution entirely, which is how a remote sandbox takes over Bash without forking the tool; `tools/post_execute` for result truncation, redaction, and telemetry. `tool/call` and `tool/result` are the durable bookends.
- **Allowlisting.** A declarative allow list, expressed as config, not a flag string, gates which tools an agent may call at all. It supports wildcards for namespaced tool sources (for example `mcp__nexus__*`). An unlisted tool is denied without being prompted. It is a `tools/pre_execute` listener instead of a special case in the registry, which is what lets a per-agent allow list ride on the agent's forked context.
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
- **Known costs of the OpenRouter-only choice.** Provider-specific features degrade to whatever OpenRouter normalizes. Prompt caching and interleaved thinking are the two that matter for §15, and their passthrough is uneven across upstream vendors. Treat both as best-effort in v1, and verify per model without assuming. A native adapter can be added later behind the same seam without touching the loop, which is the point of the seam.
- **Transport:** `async-http` for native SSE streaming on the Fiber scheduler, with no thread per request. The adapter is thin rather than a wrapper around `ruby_llm` or `langchainrb`, which keeps the streaming seam exact.

### 6.6 Execution world (`terret-exec` + sandbox gems)

The seam trio, ported intact. **`ctx.fs`** handles read, write, stat, glob, and watch behind a provider, with `fs/*` policy events for path allow and deny. **`ctx.subprocess`** puts spawn and PTY behind a provider. **`ctx.shell`** builds persistent bash sessions on subprocess. **`ctx.terminals`** manages long-lived PTYs and the terminal tool. Because fs and subprocess share one execution world, swapping in the Docker provider moves all of Read, Write, Edit, Bash, and PTY into the container together, with no per-tool forks. **`ctx.sandbox`** wraps argv before spawn, with providers `none` (trusted), `docker` (default isolation), `landlock` (Linux), and `seatbelt` (macOS). Local PTY uses the `pty` stdlib inside Async.

Workspace scoping belongs here too. An agent is granted one or more directories it may touch, and that list is a config row consumed by the fs provider's policy.

### 6.7 Standard tools (`terret-tools-std`)

v1 set: `read_file`, `write_file`, `edit_file` (string replace with a uniqueness check), `glob`, `grep` (ripgrep when present, pure-Ruby fallback), `bash`, `terminal_*`, `web_fetch`, `task` (subagent), `job_start/collect/stop` for background work via `ctx.jobs`, and `todo` for plan tracking. Each tool is its own plugin file, and each declares mutating, concurrency, and approval metadata honestly, because policy hangs off it.

Tool naming matters more than it looks. An orchestrator's allow lists are written against Claude Code's tool names (`Read`, `Edit`, `Bash`, `Glob`, `Grep`), so the std tools should either carry those names or ship a documented alias map. Decide this before the allow-list format sets.

### 6.8 Interop: MCP and ACP

- **`terret-mcp`** is an MCP *client* connecting stdio and streamable-HTTP
  servers. Discovered tools register into `ctx.tools` under a namespace with
  per-server approval policy, and resources become prompt sections on demand.
  An orchestrator that delivers a legate's entire tool roster as MCP servers
  cannot use Terret at all without it, so MCP is v1 scope (§12).
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
- **Backpressure:** `assistant/chunk` fan-out to consumers goes through bounded queues, so a slow reader drops to snapshot-then-tail without stalling the loop.
- **Why not Ractors:** adapters and tools need shared services, so Ractor
  isolation has no upside here and a real cost. Rare CPU-heavy work can use a
  thread pool behind `ctx.jobs`.

## 9. Interfaces

The v1 interface is a bidirectional event stream over a WebSocket, shipped as a plugin. There is no interactive CLI (§1 Non-Goals), and there is no compatibility layer for any other harness's command-line contract.

### 9.1 Why a socket, and why a plugin

The first real workload is a long-lived agent: one session that stays open
for days, wakes on external stimulus, does work, and goes quiet again. That
shape wants a persistent duplex connection, not a process invocation.
A run-shaped interface would force the session to be reconstructed from
storage on every wake, and it would push liveness questions, whether the
agent is still there and whether it can be steered right now, out into a
supervisor that has to guess.

A socket answers those questions structurally. The connection *is* the liveness signal. Steering is a frame, not a side channel. Nothing has to be torn down between wakes.

It ships as a plugin (`terret-ws`) instead of as core. That placement carries
real architectural weight: if the primary interface cannot be a plugin,
"everything is a plugin" is decoration. Anything the socket can do, another
interface can do by mounting a different bundle against the same seams.

### 9.2 Shape

One connection per agent. The connection carries an agent id and a bearer token, resolves or creates that agent's session, and binds to the agent's **forked context** (§4.1). Registrations made on behalf of that connection dispose when the agent ends, which is exactly what the fork primitive was ported from dsh to provide.

Many agents share one process and one reactor. Each is an Async task tree (§8), so agent count is bounded by memory and model concurrency, not by process table.

**Server to client.** Every durable session event, serialized as-is. The
socket is a `session/event` listener like every other consumer in §6.1. It
invents no vocabulary of its own, so there is no second source of truth.
Nothing reaches a client that is not in the log first.

**Client to server.** A small, closed set of frames, each of which lands on an existing seam instead of a new code path:

| Frame | Lands on |
|---|---|
| `inject` (text, `wake:`) | `agent.inject` and the inbox (§6.4) |
| `cancel` (reason) | `agent.cancel`, structured cancellation (§8) |
| `approve` / `deny` (call id) | durable `approval/resolved` (§6.3) |
| `set_model` (role, model) | the model-role config row (§6.5) |
| `subscribe` (`from_seq:`) | replay-then-tail (§9.3) |

That list is deliberately short. A frame that cannot be expressed as one of these is a sign the seam is missing, and the fix belongs in the seam, not in the socket.

### 9.3 Reconnect is the hard part, and the log already solves it

Sockets drop. Deploys, idle timeouts, and network blips all end connections that the agent's life should outlast, so the protocol has to make reconnection boring.

A client reconnects and sends `subscribe` with the highest `seq` it has
durably recorded. The server replays from `sessions.read(session_id,
from_seq:)` and then tails live. The signature in §6.1 already exists for
this. Because `seq` is a per-session monotonic integer and the log is
append-only, this is exact rather than best-effort: it leaves no gaps, any
duplicate the client sees is one it can already dedupe, and there is nothing
to negotiate.

Backpressure follows the same rule as §8. A slow reader drains to a bounded queue, and a client that falls too far behind is dropped and told to resubscribe with its last `seq`. It is not allowed to stall the loop. Snapshot-then-tail and reconnect-then-replay are the same mechanism.

**The agent's liveness is independent of the socket.** A dropped connection must never cancel a turn or fail a run. Work continues, events accumulate in the log, and a reconnecting client catches up. Only an explicit `cancel` frame stops an agent. Getting this wrong in the other direction, by tying agent lifetime to connection lifetime, would make every deploy an outage.

### 9.4 Operational notes

Long-lived sockets behind a load balancer need a heartbeat, since idle timeouts will otherwise close healthy connections. Ping frames on an interval below the balancer's idle timeout, with the timeout treated as configuration, not an assumption.

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

One entry is new: `async-websocket` carries §9, which keeps the socket on the
same Fiber reactor as the adapter streams and the tool barriers, without
introducing a second concurrency model. Two entries from v0.1 are gone. There
is no CLI framework dependency, since there is no CLI. The console is
deferred too, so no web framework sits in the core path.

The shipped code currently uses minitest, not RSpec, and the LLM vocabulary
lives in `terret-core` instead of a separate gem. Both are settled; §11
reflects the first.

## 11. Testing Strategy

- **Kernel unit tests** covering dispatch modes (waterfall short-circuit, prepend, disposal order), fork and isolate semantics, loader ordering, and hot-unload.
- **Loop tests against a scripted adapter.** A `FakeAdapter` driven by declarative scripts makes turn-flow tests deterministic and fast, and every event sequence in §2.4 gets a golden-order test.
- **Log invariant property tests.** Generate random plugin sets that inject context and rewrite claims, then assert the `derive_messages` digest always matches the outbound request.
- **Socket protocol tests.** The highest-value tests in v1, and they should be written before the implementation they check. Drive a connection with recorded client frames and assert the emitted event stream matches golden files, covering a plain turn, a multi-step tool turn, a mid-turn steer, a denied tool, and a cancellation. Then the cases that only a persistent connection has: a drop mid-turn where the agent must keep working, a reconnect with `from_seq` that yields no gap and no unexpected duplicate, a slow reader that gets dropped without stalling the loop, and a `cancel` racing a `result`.
- **Adapter contract suite.** One shared behavior run against the adapter with recorded SSE cassettes (VCR mangles streaming, so a custom cassette recorder is needed), plus a live smoke lane behind an env key.
- **Tool and sandbox integration.** Docker-based tests in CI on Linux runners, landlock tests on a Linux matrix, and snapshot tests for prompt assembly, since byte-stable rendering is a test rather than an aspiration when caching depends on it.
- **Bench lane.** Track chunk throughput and per-event dispatch overhead so kernel changes cannot silently regress streaming.

## 12. Milestones

Each phase ends with demoable acceptance criteria. No estimates are given; sequencing is what matters here, and the ordering below is the plan's main claim.

**M0. Spike. SHIPPED.** Hames event bus, effects, and waterfall semantics proven. *Accepted:* dispatch-mode test matrix green, disposal order proven.

**M1. Kernel and boot. SHIPPED.** Full Hames: services, inject-driven boot, fork, event contracts, patch layering. *Accepted:* Cordis primer semantics reproduced in tests, events catalog generation working.

**M2. Log, loop, and the OpenRouter adapter. SHIPPED.** Session log with the invariant, `derive_messages`, prompt assembly, tool registry and pipeline, the default loop, in-memory plus JSONL stores, and the `terret-openrouter` gem: SSE streaming over `async-http` with tool calling, usage accounting on `step/end`, mid-stream error surfacing, and retry with jittered backoff in a shared `AdapterBase`. The transport is injectable, so the adapter's unit tests run without the network; a loopback-socket test covers the real transport and an opt-in live lane (`TERRET_LIVE=1`) covers a real model. *Accepted:* a multi-step tool turn completed live against a real model with golden event order and the invariant asserted on every request. The generative log-invariant property test from §11 remains open.

**M3. Durable sessions. SHIPPED.** Payloads became primitives at the append boundary (typed parts encode through the LLM codec), a `ctx[:session_store]` seam landed with memory, JSONL, and SQLite providers, `read(session_id, from_seq:)` and resume rebuilt sessions exactly, and `session/compacted` was declared with its projection ahead of the M6 compactor. The web chat's session sidebar is the first consumer. *Accepted:* a session survives a process restart and resumes with byte-identical derived context, and a replay from an arbitrary `seq` yields the same events as a live tail from that point.

**M4. The socket. SHIPPED.** `terret-ws`: one connection per agent, durable session events out, the five §9.2 client frames plus subscribe in, exact replay-then-tail reconnect with flow-controlled replay, bounded-queue backpressure with an idempotent lagged-drop, bearer auth per agent with connection supersede, and heartbeat pings. Cooperative cancel is honored at step boundaries; mid-stream abort waits on the §8 async work. Approval events are declared, with resolution machinery deferred to M6. A cross-model adversarial review (Codex) plus two-stage per-task reviews drove several hardening fixes during implementation; accepted-but-deferred findings from that review are recorded in §14. *Accepted:* the socket protocol tests pass, including the connection-drop cases; an agent survives a client disconnect mid-turn and the reconnecting client sees no gap.

**M5. MCP client. SHIPPED.** `terret-mcp`: a manceps-backed client mounting
stdio and streamable-HTTP servers as namespaced `mcp__<server>__<tool>` tool
sources behind `ctx[:tools]`, targeting the deployed legacy wire (protocol
revisions 2025-11-25/2025-06-18); per-server approval metadata, a strict mode
closed to ambient config, per-call timeouts that poison a connection and
reconnect on next use, live `tools/list_changed` reconciliation, and
resources registered as prompt sections. Two core preludes made policy real:
`Context#effect` disposers became self-removing and idempotent (paying down
an M4 debt item), and `Registry#execute` now dispatches its waterfalls on the
calling agent's forked context, so `Terret::Tools::AllowList` (a
deny-by-default `tools/pre_execute` veto with `File.fnmatch` globs) governs
one agent alone when installed on its fork. *Accepted:* an agent whose entire
tool roster arrived from a real stdio MCP server ran a turn over the M4
socket with the allow list admitting one call and denying another, proven
live against a fixture subprocess. *Deferred:* approval resolution machinery
(M6); the 2026-07-28 stateless MCP wire revision, not yet deployed anywhere.

**M6. Long-lived agent hardening. SHIPPED.** Rescoped mid-execution (recorded
in the plan, user-confirmed) once it became clear Terret's primary workload
is autonomous agentic systems, not interactive use. Durable
human-in-the-loop approvals (`ctx[:approvals]`) landed as designed: a
`tools/execute`-stage gate that a per-agent `AllowList` veto always settles
first, parking on durable `approval/requested`/`approval/resolved` so a
verdict already in the log never re-parks after a restart. They shipped as an
**opt-in row**, though, not the milestone's center of gravity. That center
became three things instead: a kernel-level reconfigure contract
(`Hames::Service#reconfigure` / `Loader#reconfigure!`, wholesale config
replace, a live `config/updated` event), adopted immediately for
`Loop.max_agents` and the socket's tokens/heartbeat/queue_limit;
hot-reloadable per-agent policy as a durable log projection (`AllowList` v2:
the active pattern set is the last `policy/updated` event in the session,
install patterns only the floor, the socket's `set_policy` frame appending
it, replay rebuilding it exactly after a restart); and a summarizer seam
(`ctx[:summarizer]`, sole-provider like the session store) behind the
compactor, with `RoleSummarizer` (no signup, one `:compactor`-role model
call) as the core default and a new eighth gem, `terret-morph`, calling
Morph's Compact API on the wire proven in the deployed agora integration
(bearer key, `compression_ratio: 0.4`, `preserve_recent: 0`,
nil-on-any-failure, an injectable transport keeping its unit tests off the
network). `Loop#resume_turn` re-enters an open turn straight from the log,
closing the crashed step by re-executing tool calls the last assistant
message still owes and reading approval verdicts already recorded instead of
re-asking. The socket now auto-resumes on either a wake or a verdict landing
for an agent with no parked fiber, with the wake-race requeuing a losing
steer without dropping it. Titling (one durable `session/titled` per
session, `:titler` role with a 40-char fallback) and `Sessions#usage` (a pure
log rollup of every `step/end`'s usage) round out the observability the
milestone needed. Three §14 debts got paid alongside all of it:
`Context#emit` isolates listener failures instead of surfacing them into a
producer whose append already committed; the append boundary refuses invalid
UTF-8 instead of failing deep in a store; and the agent registry gained a
real lifecycle (`AgentExists`, `AgentCapExceeded` at a cap of 128,
`dispose_agent` for idle agents only, `agent_for_session`). Steers now log as
`context/injected` rather than `user/message`, restoring a distinction the
projection always supported but nothing emitted. *Accepted:* a turn wedged
mid-tool-call survived `kill -9` and completed on the first wake in a fresh
process, at-least-once for tool calls documented as the cost of that
guarantee; a single in-process run proved four wakes, a compaction, a title,
a cost rollup, and a live policy flip over the socket in one session.
*Deferred:* the fuller §6.4 status machine
(`waiting_input`/`stopping`/`done`) to M7/M8; spontaneous resume on boot
(resume stays stimulus-driven by design); compaction retention tails;
`terret-morph`'s `query:` param.

**M7. Execution world. SHIPPED.** Three new gems gave the agent hands.
`terret-exec` carries the seams: `ctx[:fs]`, where every path expands,
resolves its deepest existing prefix through `realpath`, and must land inside
a granted workspace directory (traversal and symlink escapes fail closed,
including the dangling symlink whose target does not exist yet, with
`O_NOFOLLOW` on the leaf open), and every operation passes an `fs/authorize`
waterfall that may veto or admit but never rewrite the path;
`ctx[:subprocess]`, spawn and PTY under the one reactor with cooperative
cancellation escalating SIGTERM to SIGKILL, every argv routed through
`ctx[:sandbox].wrap` before it spawns; `ctx[:shell]`, one persistent bash per
agent behind a sentinel protocol the model cannot forge, cwd and environment
surviving between calls; and `ctx[:terminals]`, named long-lived PTYs under a
per-owner cap. All four hold per-agent runtime state that no registration
owns, which reversibility alone could not reap, so the milestone declared
`agent/disposed` and hung shell and terminal teardown off it: an agent's
shells, its terminals, and its backgrounded jobs now go down with it.
`terret-tools-std` registers the roster on those seams under Claude Code's
names verbatim (`Read`, `Write`, `Edit`, `Glob`, `Grep`, `Bash`, `WebFetch`,
and `terminal_open`/`input`/`read`/`close`), with honest `mutating`,
`approval`, and `concurrency` metadata; `Bash` derives its approval from
`ctx[:sandbox].isolated?` at registration, §13's rule made mechanical and
re-derived when a sandbox row swaps, and `WebFetch` sits behind a
deny-by-default domain policy re-checked on every redirect hop, over a
host-side floor that refuses loopback and link-local addresses after
resolution. The fetch egresses from the harness, not from the container, so
`network: none` was never going to govern it. `terret-sandbox-docker` is the
third gem and the acceptance itself: a long-lived container per boot, each
workspace directory bind-mounted at the same absolute path, argv wrapped into
`docker exec`, `--network none` unless configured otherwise. Redaction landed
where §13 asked for it and inside the invariant, not against it: a
`tools/post_execute` pass over a Result's content and error, plus a scrubber
seam folded into `Sessions#normalize_payload`, so the stored log and every
projection derived from it, both sides of the digest, see identical bytes.
Streaming forced a second round: per-fragment scrubbing leaks any secret a
provider happens to split across deltas, so a mounted redactor now coalesces
each text run into a single chunk at run end, proven by window-straddling
tests the first fix would have passed; and resume refuses to re-execute a
call whose arguments or whose name the log redacted, without silently
running a different command. Four preludes in the kernel and core made all of
it safe to mount: `Tools::Registry#register` records its effect on the
registering context, so a forked agent's tools die with the fork instead of
surviving it holding filesystem authority; `Loader#reconfigure!` became
atomic, committing the row only after an owned hook returns; the `AllowList`
projection caches per session with log-first invalidation instead of
rescanning the whole log on every call, which the std tools multiply by an
order of magnitude; and `Registry#execute` hands a handler the session it is
running in, merge-ordered so a model-forged `session_id` in the arguments can
never reach another agent's shell. The `sqlite`/`pty` soak owed since M2
finally ran: eight agents driving concurrent multi-step tool turns against
both the SQLite and JSONL stores with two PTYs streaming throughout, every
session's seqs unique and contiguous on a fresh re-read, no reactor stall.
Both adversarial gates ran at the milestone as M4's did (a fresh opus
reviewer over the whole-milestone diff and a cross-model Codex challenge),
converging on the disposal leak and diverging productively, with Codex
finding a dangling-symlink containment escape the opus pass had rated out of
scope. Their synthesis drove a four-commit fix batch before the push.
*Accepted:* one appended patch row moved `Bash`, `Read`, `Write`, and a PTY
into a container with zero tool changes: the roster identical field for field
save `Bash`'s sandbox-derived approval, the same handler blocks proven by
source location, discriminated by container membership (`/.dockerenv`), not
kernel name, since a Linux runner reports `Linux` from both worlds.
Proven live under docker and exercised live in CI. *Deferred:* the §14
additions from the ship gate: host-side output caps for `Read`, `Grep`, and
capture; a cancellation model for children orphaned mid-spawn; a total
wall-clock deadline for `WebFetch`; docker resource limits as config
passthrough; hash-key scrubbing at the log boundary; and two accepted TOCTOU
windows, an intermediate-component symlink swap and DNS rebinding under
`WebFetch`. To M8: the `task`/`job_*`/`todo` tools and the tool barrier that
honors `concurrency:`. Unscheduled beyond it, recorded in §14's ledger
without being promised to a milestone: `landlock` and `seatbelt` sandboxes,
`fs.watch`, the SQLite per-session writer task (the soak says it is not
needed yet), and harness-level idempotency keys.

**M8. Subagents, then 0.1 release. SHIPPED.** The last milestone gave the
agent agents of its own and then made the whole thing installable.
`Terret::Subagents` is a sole-provider seam whose `run(prompt:, ctx:)`
creates a fresh durable session (capabilities inherited, transcript not),
spawns a child agent marked `unattended` so its approval gate denies without
parking on a human who is not there, runs one turn to completion, and
returns the final text with its session id, usage, and status before
`dispose_agent` always reaps it; `terret-tools-std`'s `Task` tool (Claude
Code's name, `concurrency: :parallel`, `approval: :never` because the child's
own pipeline gates every real effect) delegates through it on the caller's
context, so a child inherits the caller's roster and its install-time policy
floor but never a mid-session narrowing: a fresh session holds no
`policy/updated`, which is the structural reason no-escalation holds, not
a check that could be forgotten. Several calls in one assistant message
now run under a tool barrier: `Loop#execute_batch` chunks the calls into
maximal runs of adjacent `concurrency: :parallel` tools and runs each run's
members together on the one reactor (`execute_together`, one `Async` task per
call, the first exception re-raised only after every sibling in flight
settles), while a `:serial` tool is a barrier of one that nothing may reorder
across; results always append in call order regardless of concurrency, so
`derive_messages` and resume rebuild the same history, and with no reactor a
run degrades to one call at a time without changing that order. Background
work outlives the turn that started it through `ctx[:jobs]`
(`Terret::Exec::Jobs`: a `bash -lc` child spawned through the sandbox wrap,
not the shell, a per-session ledger, SIGTERM→SIGKILL stop, teardown
hung off `agent/disposed`, capped and deliberately not durable) with
`job_start`/`job_collect`/`job_stop` on top; `TodoWrite` holds no state at
all: it validates and renders the list straight back, and the durable tool
result is the storage, so resume needs no special case. The meta-gem `terret`
became real: `Composition` resolves bundles (ordered rows), profiles (stacked
bundles), and patches (a row replaced wholesale by id, or inserted at a
`before:`/`after:` anchor) across four layers with `!env`/`!setting`/`!ruby`
tags materialized only at boot behind a Psych visitor. It refuses an unknown
tag; it does not silently drop one. `Terret.boot` hands the resolved, constantized
rows to the Hames loader, and the `trt` CLI exposes `boot`, `dump-config`
(each row annotated with the layer that set it, secrets left unresolved),
`doctor`, and `acp`. `Hames::Schema` is the config contract the plan's §10
dry-schema mention is now superseded by: a hand-rolled, zero-dependency
per-service DSL (`type`, `required`, `enum`, a `default` filled at read time,
not merged, `doc`) whose `declared` registry `rake config:catalog`
walks and whose `validate` `trt doctor` runs against a resolved profile
without booting it, reporting an unschema'd service, a bad key, or an
unresolvable tag, and refusing a path-shaped `plugins:` require. It never
executes one. `terret-acp` is the second interface (plan §9.1):
`Terret::ACP::Server`, ACP v1 over newline-delimited JSON-RPC 2.0 on stdio,
`session/new` spawning a durable agent, `session/prompt` pending the whole
turn on a task rooted so a client disconnect cannot cancel it, and
`session/update` notifications projected from the session log, the same
`ctx[:loop]` and `session/event` seams the socket consumes, on a different
transport, with no change to core, which is the standing proof the interface
is not privileged. A bench lane (plan §11) landed with regression floors CI
gates (`rake bench BENCH_FLOORS=1`), `docs/cookbook/` collected three worked
end-to-end recipes (adding a tool, a provider, and a bundle), and
`ctx[:credentials]` (`Terret::Credentials`, in terret-core) resolves a
provider secret ENV-first then from an optional AES-256-GCM on-disk store
keyed by `TERRET_CREDENTIALS_KEY`, feeding every resolved value to the log
scrubber and refusing a store present without its key. It never falls
back to plaintext. Discovery closed the extension loop:
`Composition.discover_bundles` scans loaded gemspecs for
`metadata["terret"]`, resolves the bundle YAML within the owning gem's root,
and makes a third-party plugin gem composable by shipping normally. A
stranger gem built on disk at test time is discovered off its gemspec,
stacked into a profile, booted, its tool run end to end, and denied until the
profile's allow list names it, all proven in `discovery_integration_test.rb`
including a real `Terret.boot` over a gem added to the global spec set. The
cookbook's `terret-fortune` is the worked companion a reader follows to the
same shape. The security pass in §13 closed three surfaces and re-examined
the rest: the deny-by-default allow list became an authoritative gate the
registry consults after the waterfall on the exact admitted call: no listener
a row registers can mount ahead of it and short-circuit past, and a per-agent
`AllowList` can only narrow; the append-boundary scrubber now folds hash keys
as well as values past the structural surface, with a fail-closed corner
where two content keys redacting to one token collide and the append raises;
a profile `plugins:` path require and a `!ruby` scalar are gated behind
`--allow-config-ruby` (off by default) while a trusted bundle's own
`requires:` and a load-path feature name are not; the socket's `replay_limit`
and `max_concurrent_replays` bound a reconnect's `from_seq` and a reconnect
storm; and the M7-§14 exec quick-wins were paid: a symlink-hop cap so a
dangling loop denies without overflowing the stack, a glob that drops a
dangling entry without crashing the listing, and a `WebFetch` floor that
resolves the bracket-stripped host so `[::1]` is refused as loopback. Both
adversarial gates ran as prior milestones' did: a mid-milestone
opus-plus-Codex checkpoint over the subagent and composition work, and a
consolidated cross-model security audit over the closing diff, whose findings
drove the floor-authoritative, hash-key, and consent-gate fixes and are
recorded, paid and deferred alike, in §14. *Accepted:* the extension story is
proven in-repo end to end: a stranger gem discovered, mounted, run, and
governed by the same deny-by-default floor as a first-party tool. The twelve
gems build in lockstep at 0.1.0 (`rake release:build` with `--strict`), which
`release:push` sends to RubyGems in a tested topological order (hames first,
the meta-gem last, every gem after its declared dependencies); the publish
itself is the one remaining act, run by hand because it needs RubyGems MFA.
*Deferred:* the §14 ledger from the security audit: `WebFetch`'s missing
total wall-clock deadline and its still-reachable private ranges (a
`block_private_ranges` knob is M9), an OS-keychain credential backend and a
`trt credentials set` writer, lineage-scoped policy inheritance so a parent's
narrowing reaches a `Task` child (which runs at the floor today),
idle-session eviction (the M6 lifecycle gap, M9), a job grandchild that can
outlive its job's disposal, and resume's `redacted?` check folding values but
not keys. Plus the M7 carries not taken here: `landlock`/`seatbelt`
sandboxes, `fs.watch`, docker resource-limit passthrough, and harness-level
idempotency keys.

The ordering is the plan's main claim. Durable sessions come before the socket because reconnect correctness is a property of the log rather than of the transport, and building the socket first would mean discovering that the hard way. MCP comes early because an agent whose tool roster arrives over MCP is the launch workload, and no amount of transport substitutes for it. The execution world moves late for the same reason: that agent needs no local fs or subprocess access at all. Multi-provider adapter work left the roadmap, absorbed by OpenRouter. The interactive CLI and command-line compatibility both left the roadmap entirely.

## 13. Security Posture

Sandbox `docker` with `network: none` is the default for untrusted work, and `none` requires explicit opt-in per profile. Approval policy defaults to `:policy` for mutating fs tools, `:always` for bash outside a sandbox, and `:policy` inside. Credentials never enter the session log, enforced by redaction in `tools/post_execute` plus a log-append scrubber. `web_fetch` gets an allow and deny domain policy row.

The socket adds concerns of its own. A connection's bearer token authorizes exactly one agent, because the stream it subscribes to carries everything that agent's model saw, which is the most sensitive artifact in the system. Authorization is checked before the agent is resolved, so a bad token cannot probe which agent ids exist. Replay is capped per connection, since an unbounded `from_seq` request is a cheap way to make the server read an entire history.

Multi-tenancy inside one process is the structural risk. Agents share a reactor and a service tree, so isolation rests on the forked context in §4.1, not on the OS. That is adequate for agents under common ownership and inadequate for mutually untrusted ones. Where untrusted execution is required, the boundary is a separate process with the sandbox in §6.6, not a fork.

Prompt-injection stance: tool results are data. The loop never executes instructions from tool output except through the model, and the approval seam is the human backstop. That backstop is optional per profile: autonomous profiles, Terret's primary workload, run deny-by-default hot-reloadable policy (M6) instead of a human in the loop. Document this threat model explicitly in `docs/security.md`.

## 14. Risks and Open Questions

- **Waterfall ergonomics in Ruby.** Explicit `next_.()` is unfamiliar. The M0 spike validated the API feel before it fossilized, and it held up. Fallback if it sours: a `throw`/`catch` short-circuit sugar.
- **No side-by-side proving path.** Declining command-line compatibility means the first time Terret drives a real agent is also the first time anything depends on it. Recover some of that confidence cheaply: capture an incumbent harness's event stream on live traffic, replay the same stimulus into Terret offline, and diff the derived context, not the wire bytes. That compares the thing that matters (what the model saw) without shipping a compatibility layer that would then need deleting.
- **Blast radius of one process.** Many agents on one reactor means one wedged Fiber, one memory leak, or one deploy can affect every agent on the box. A run-per-process model spreads that risk at the cost of everything §9.1 argues for. Mitigate with per-agent supervision inside the reactor, a hard cap on agents per process, and shard by process before shipping the cap as a tuning knob.
- **Long-session context growth.** A session measured in weeks outgrows any context window, so compaction is not a nicety and it interacts directly with the §2.5 invariant: a compacted history is still model-visible, so it must be logged as its own durable event. It cannot be computed on the fly. Design the event before the feature.
- **OpenRouter as a single point of failure.** One adapter means one vendor
  relationship, one rate limiter, and one normalization layer standing between
  Terret and every model. The seam makes a native adapter cheap to add, but
  this is a deliberate concentration of risk, not an oversight.
- **Feature passthrough through OpenRouter.** Prompt caching and interleaved
  thinking are the two §15 claims most likely to degrade. Verify per model
  without assuming, and demote a claim instead of defending it.
- **Fiber-scheduler edge cases** in `sqlite3` and `pty` under load. Mitigate
  with the writer-task pattern and soak tests during M7's execution-world work.
  (M5's canary pins fiber-safety at the MCP boundary only.) *The soak ran
  during M7*: eight agents drove concurrent multi-step tool turns against both
  the SQLite and JSONL stores with two PTYs streaming throughout, seqs unique
  and contiguous on a fresh re-read of each store, and found no stall. The risk
  retires into normal regression coverage (the lane is opt-in behind
  `TERRET_SOAK=1`, so wiring it into a scheduled CI job is the remaining
  follow-up). The writer-task pattern stays unbuilt on purpose: durable-first
  ordering means a writer task cannot return before the write lands, so it buys
  serialization, not latency, and the soak shows a single connection
  with sub-millisecond inserts is not where the time goes.
- **Event typing without a compiler.** Runtime contracts plus CI catalog diffing is the bet. If drift still bites, add a Steep-checked events RBS generated from declarations.
- **Tool naming.** Whether std tools carry Claude Code's names or an alias map is unresolved and blocks nothing until M5, but it should be settled before allow-list formats harden.
- **Kernel ergonomics debt, found during M3 review.** Two small Hames sharp edges hit
  independently by multiple reviewers: `Hames::Service.service_key` is a per-class ivar
  not inherited by subclasses, so a test double subclassing a keyed provider silently
  fails to mount; and `Hames.event` on an undeclared name raises a bare `KeyError` from
  `Hash#fetch` instead of a `ContractError` naming the event. Neither blocks anything;
  both are worth fixing together in a small kernel pass. *Paid down during M4.*
- **Debt from the M4 cross-model (Codex) review.** Four accepted-but-deferred
  findings, none blocking M4's acceptance: (1) a disposed `Context#on`
  listener's effect entry stays in `@effects` forever: long-lived contexts
  retain every disposed disposer and whatever its closure captures (each socket
  subscription, for one). The fix belongs in `Context#effect` making disposers
  self-removing, a kernel pass. *Paid down during M5*, driven by MCP mounting
  and unmounting tools constantly. (2) `Hames::Context#emit` runs listeners
  inline and unrescued, so any listener error surfaces to the producer after a
  durable append has committed. Decide whether fire-and-forget should isolate
  listener failures (the socket rescues its own listener as a workaround).
  *Paid down during M6.* (3) the JSONL and SQLite stores `JSON.generate`
  payloads that `normalize_payload` admits without an encoding check, so an
  invalid-UTF-8 string in a tool result can fail an append at the store instead
  of at the boundary. Tighten `normalize_payload`. *Paid down during M6.* (4)
  `Loop`'s agent registry is unbounded, never disposes a replaced agent's
  forked context, and allows silent id replacement. It needs a lifecycle story
  before M6's long-lived agents. *Paid down during M6.*
- **Accepted deferrals from the M6 reviews.** `terret-morph`'s `summarize`
  catches a broad `rescue StandardError` because transport failures share no
  common exception ancestor to rescue more narrowly; it declines to nil and
  records `e.class` in its warn, which is enough for now. Revisit once an
  error-tracking seam exists. `Tools::AllowList`'s `current_patterns` is an
  O(events) linear scan of the session log on every call; fine at M6's scale, a
  caching candidate if a long session ever makes it show up in a profile. *Paid
  down during M7*, where the std tools made it show up: the projection now
  caches per session, invalidated the log-first way by a `session/event`
  listener watching for `policy/updated`, with an unknown session left uncached
  so deny-all never ossifies into allow.
- **Recorded, not fixed, at M6's final gates.** Seven findings from the closing
  cross-model review that are real but not M6's problem, each with the reason
  it waited. (1) `Context#register`'s service entry is recorded on the ROOT
  context, not the registering fork, so a forked agent's service
  registration bleeds upward. That was pre-existing and invisible at M6's
  usage, an M7 kernel pass. *Paid down during M7* at the surface that reached
  it: `Tools::Registry#register` recorded its effect on the registry's own root
  instead of on the caller, so a tool a forked agent registered outlived
  `dispose_agent`, a security bug the moment tools carry filesystem authority.
  `register` now takes `ctx:` and records there; the roster stays global
  because visibility is the allow list's job, but ownership follows the
  registering context so disposal reaps it. (2) Nothing evicts: `Sessions`'
  `@cache` (and now its per-session lock map) grows for the life of the
  process, and the agent pool never auto-disposes an idle agent, so a box
  serving thousands of long-lived sessions leaks both. Long-lived memory
  lifecycle is an M7 topic in its own right, alongside the §9.1 blast-radius
  work. (3) Cost accounting undercounts twice: utility calls (the compactor's
  and titler's own model requests) never reach a `step/end`, and a step whose
  process died before its `step/end` loses its usage entirely. `Sessions#usage`
  is honestly "what the log recorded", not "what the vendor billed". (4) Both
  the policy scan and the pending-approvals scan are O(events) per call, and
  `pending` inside a long park loop is quadratic in the requests of one turn;
  fine at M6's scale, caching candidates the moment a profile shows them. *Half
  paid during M7*: the policy scan got its per-session cache when the std tools
  multiplied call volume; the pending-approvals scan is untouched and still
  O(events), which is honest because approvals stayed an opt-in row. (5)
  `Loader#reconfigure!` is not atomic: a service whose `reconfigure` hook
  raises leaves the row's config swapped and the service half-updated, and the
  hooks themselves run ownerless, so an effect one registers is not recorded
  against the row. *Paid down during M7*: the row and the service's config roll
  back when a hook raises, `config/updated` fires only on success, and hooks
  run under `with_owner(id)` so what they register belongs to the row. (6) The
  at-least-once tool contract has a narrower cousin: a tool that
  performs its side effect and dies before its `tool/result` appends leaves
  resume unable to tell whether the effect happened, worse than plain
  repetition. Idempotency stays the tool's concern in v1; harness-level
  idempotency keys are an M7+ candidate. (7) `set_policy` carries the whole of
  a connection's authority: a client that can steer an agent can also rewrite
  its allow list. Splitting per-frame capabilities from the bearer token is a
  real design question and belongs with the multi-tenant work, not here.
- **Accepted deferrals from the M7 ship gate.** Both adversarial gates found
  more than the fix batch took, and the rest was deferred deliberately
  without being rushed into an invariant-sensitive surface at a push. (1) Nothing caps
  what a single read buffers: `FS#read`, `Subprocess`' capture, and `Grep` will
  all happily pull a huge file into memory, and because the harness is one
  process the OOM kills every agent on the box. It does not spare the one that asked.
  A host-side cap on each is the M8 candidate; the shell already has
  `max_output` for exactly this reason. (2) A fiber cancelled mid-spawn or
  mid-close can orphan its child: `ensure` closes the pipes but cannot reap,
  since the reap loop's own sleep would re-raise inside it. Exposure is low
  today because parks happen at approval gates, not mid-spawn, and the
  `timeout:` path reaps correctly, but it needs a design decision before M8's
  cancellation work. (3) `WebFetch` has per-phase timeouts and no total
  wall-clock deadline, so a slowloris-shaped server can hold a fiber for far
  longer than any single phase allows. (4) The docker provider passes no
  `--memory`, `--cpus`, or `--pids` limits; the container isolates execution
  but does not bound it. Deployment-hardening config passthrough, M8. (5) The
  append-boundary scrubber folds string *values* but not hash *keys*, so a
  credential used as a key would reach the log unscrubbed. Unreachable through
  the fixed-schema std tools, which is why it waited; fold keys through the
  scrubber, respecting the structural exemption, in M8. *Paid down during M8*:
  `normalize_payload` now folds a hash key through the same scrubber as its
  values once past the structural surface. A secret-shaped content key scrubs,
  and a structural field name stays exempt, with a fail-closed corner where two
  content keys redacting to the same token collide and the append raises
  without dropping one. (6) Two TOCTOU windows are accepted with their reasoning:
  the fs symlink fix put `O_NOFOLLOW` on the leaf open, so the racy leaf swap
  is closed, but an *intermediate* component swapped mid-operation remains a
  window. Single-agent sequential execution makes it practically unreachable,
  and `openat`/dirfd is the M8 close; and `WebFetch` resolves, checks, then
  connects, so a DNS answer that changes between the two rebinds past the
  floor. Pinning the IP via `Net::HTTP#ipaddr=` would widen the injectable
  transport's `call(url)` contract, so it waits for a transport-shape decision.
  (7) Three smaller things the final controller pass caught and left:
  `FS#resolve_real` recurses without a hop cap, so a *loop* of dangling
  symlinks raises `SystemStackError` instead of `Denied`. That is DoS-shaped,
  not an escape, and a hop cap closes it. `FS#glob` calls `File.realpath` on every
  entry, and a glob can legitimately return a dangling symlink, so
  `Errno::ENOENT` crashes the listing. It does not skip the entry. And
  `WebFetch`'s loopback floor never sees an IPv6 bracket literal such as
  `[::1]` because the resolver answers nothing for it and the connect then
  fails on its own. That is safe today by accident, the kind of safety worth
  pinning with a test in M8's security pass. *Paid down during M8*:
  `FS#resolve_real` caps its symlink hops (`MAX_SYMLINK_HOPS`), so a dangling
  loop raises `Denied` rather than `SystemStackError`; `FS#glob` drops an entry
  whose realpath raises `ENOENT`/`ELOOP`. It does not crash the listing. And
  the `WebFetch` floor resolves the bracket-stripped `uri.hostname`, so `[::1]`
  is refused as loopback and never reaches the connect. Each is pinned by a
  test.
- **Accepted in M8's job seam.** Two things the code and `docs/subagents.md` §6
  both point here for. (1) *A grandchild can outlive its job's disposal.*
  Ending a job signals its process group, and that signal is only sent while
  the leader is alive or an unreaped zombie, which is what proves the pgid is
  still ours and not one the kernel has recycled into a stranger's group. A job
  whose leader exited on its own and was already reaped has no such proof, so
  nothing is signalled for it, and a background child it started survives. The
  exposure is narrower than it sounds: closing the handle drops the pipe's read
  end, so any survivor still holding the write end dies of SIGPIPE on its next
  write, which confines the leak to grandchildren that are silent or have
  closed stdout. Bounding the wait without collecting the leader is what would
  lift it. (2) *Lineage-scoped job visibility.* A job's ledger is keyed by the
  session that started it and a child's session is fresh, so "my parent's job"
  and "another agent's live process" are the same shape to the seam and both
  fail closed, which is why jobs and children do not mix in v1. Lifting it
  means a lineage link the runtime does not have yet, and a decision about what
  a child may do with a job it did not start; the fail-closed answer holds
  until both exist.
- **Paid down during the M8 security pass.** Three security surfaces closed in
  M8's closing pass, beyond the M7-§14 exec quick-wins and the hash-key scrub
  marked paid above. (1) *The floor-bypass.* The deny-by-default allow list was
  a `tools/pre_execute` listener, and a no-inject row's listener mounted ahead
  of it could admit a call without delegating and short-circuit past, defeating
  the autonomous safety mechanism by registration order. It is now an
  authoritative gate the registry consults after the waterfall, on the exact
  admitted call, so no listener any row registers can bypass it, and a
  per-agent `AllowList` can only narrow. (2) *Replay caps.* The socket's
  `replay_limit` (default 10,000, with a `replay_truncated` frame) and
  `max_concurrent_replays` (default 4) bound what a reconnect's `from_seq` and
  a reconnect storm can make the server read: the concrete cap §9.4 and §13
  promised. (3) *The consent gate.* A profile's `plugins:` entry naming a
  filesystem path is code execution with a YAML extension, so it is now gated
  behind `--allow-config-ruby` exactly as a `!ruby` scalar is, while a bundle's
  own `requires:` (operator-installed, trusted) and a load-path feature name
  are not; `doctor` refuses a path-shaped require by default, so inspecting an
  untrusted profile does not run it (docs/security.md, docs/composition.md).
- **Accepted deferrals from the M8 security pass.** Each re-examined in the
  pass and deferred deliberately, with its reason. (1) `WebFetch` still has no
  total wall-clock deadline: a slowloris server can hold a fiber past any
  single phase. It is bounded in practice by `MAX_REDIRECTS × timeout`; a real
  deadline waits. (2) `WebFetch`'s SSRF floor leaves private ranges reachable;
  a `block_private_ranges` knob to close them is M9. (3) `ctx[:credentials]`
  ships only the on-disk AES-256-GCM store format. An OS-keychain backend and a
  `trt credentials set` writer CLI are deferred, so a deployment writes the
  store itself for now. (4) A hot-narrowed per-session policy does not reach a
  `Task` child: a child gets a fresh session with no `policy/updated`, so it
  runs at the floor, not the parent's narrowing. A narrowing that must
  reach children belongs in the floor, and lineage-scoped policy inheritance is
  future work. (5) Child sessions accumulate unbounded: nothing evicts an idle
  session, the M6-recorded lifecycle gap, and eviction is M9. (6) Resume's
  `redacted?` check, which refuses to replay an owed call carrying the
  replacement token, folds hash *values* but not *keys*, so a redacted token
  planted in a tool-arg key would not trip it, a narrow edge given the
  fixed-schema tools. (7) The test-diagnostic materialize path exposes fixture
  env values only, because boot needs plaintext settings and a test asserts it;
  not a production surface. (8) `install_floor` is a privileged plugin
  capability by design: a mounted plugin can replace the floor. Plugin trust
  and supply-chain are out of scope under the v1 multi-tenancy stance (mutually
  untrusted code belongs in a separate process). (9)
  `Composition.load_path_feature?` classifies POSIX path shapes; a Windows
  backslash path (`..\evil`) is not caught, which is acceptable for a
  POSIX-targeted runtime.
- **MCP wire and fiber-safety, from M5.** v1 targets the deployed legacy wire
  (protocol revisions 2025-11-25/2025-06-18); the 2026-07-28 stateless revision
  stays out of scope until something deploys it. manceps' fiber-safety under
  the async scheduler is empirically verified, not an upstream contract. The
  integration canary pins it at Terret's boundary, and a future manceps release
  could still break it silently.
- **Open:** should `hames` move to its own repo, for a cleaner story at the cost of more overhead? Should the meta-gem vendor a pinned bundle version map?

## 15. What "Cutting Edge" Means Here, Concretely

Agents that live for weeks on one session log, steerable mid-turn over a live connection, surviving disconnects and deploys without losing derived context. Interleaved thinking blocks preserved as first-class message parts and replayed. Provider prompt caching made reliable by byte-stable prompt assembly. Mid-conversation model switching on one session log. Structured cancellation. Hot-reloadable per-agent policy that survives restarts by replay, with durable approvals available opt-in. MCP interop. A replaceable agent loop.

Each of these follows from two disciplines: everything is a plugin, and model-visible means logged. Keep those two and the rest stays honest. The first two on this list are the ones most exposed to §14's passthrough risk, so they are claims to verify, not assume.

## 16. Immediate Next Actions

1. Write `docs/protocol.md` capturing the §9 frame set and the reconnect contract precisely, then the socket protocol tests from §11, both before the M4 implementation. Primer-first is one of dsh's better exports. *Done in M4.*
2. Write `docs/hames-primer.md`, still outstanding from the original plan.
3. Run the trademark search (§1 Naming), the last unchecked item from the original launch list.

## 17. Appendix: Naming Landscape

"Harness" in ML also means eval harnesses such as EleutherAI's lm-evaluation-harness, so Terret's docs should say "agent harness" in the first sentence everywhere. Tack-derived candidates: Terret (chosen, the rein-guiding ring, short and pronounceable and unclaimed), Hames (the kernel, the load-bearing arcs), Crupper and Surcingle and Breeching (reserve), Martingale (rejected for a finance collision).
