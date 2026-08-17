# Terret: Implementation Plan

**A Ruby-native, model-agnostic agent harness, informed by DeepSeek Harness (`dsh`)**

Version 0.1 — August 2026
Status: Pre-implementation design document. Everything here precedes the first line of shipped code.

---

## 1. Executive Summary

DeepSeek Harness (`dsh`) demonstrated that an agent harness can be built where *everything is a plugin* — the model adapter, the tool registry, the session log, and even the agent loop itself are replaceable plugins mounted into a shared context, powered by the Cordis framework. Nothing in that architecture is TypeScript-specific. Its essential ideas — services in a context, typed events with explicit dispatch modes, reversible registrations, an append-only session log as the single source of model-visible truth, and layered declarative composition — translate cleanly to Ruby, and in several places Ruby's strengths (blocks, refinement-free open modules, Zeitwerk autoloading, Fiber-based structured concurrency) make the design *simpler* than the original.

**Terret** is that translation: a cutting-edge, modular harness for driving *any* LLM (Anthropic, OpenAI, Google, DeepSeek, Mistral, local models via Ollama/llama.cpp, and OpenAI-compatible endpoints) through a plugin kernel called **Hames** (the Cordis analogue). The name comes from harness tack: a *terret* is the ring on a harness through which the driving reins pass — the small, load-bearing component that lets one driver guide any horse. *Hames* are the rigid curved pieces that transfer the pulling force. The metaphor holds: the kernel bears the load; the harness guides any model.

This document covers: research findings on `dsh`, the full architecture mapped to Ruby, the gem/monorepo layout, every core subsystem's interface design, the event vocabulary and turn flow, the configuration/composition system, concurrency model, testing strategy, tooling, a phased milestone plan with acceptance criteria, and open questions.

### Naming

Primary: **Terret** (`terret` gem namespace; CLI binary `trt`). A RubyGems search on 2026-08-17 shows no existing `terret` gem. Alternates held in reserve, all from harness tack and all obscure enough to be unique: **Hames** (reserved here for the kernel gem), **Crupper**, **Surcingle**, **Breeching**, **Martingale** (likely conflicts — it's a finance term with existing gems). Before first release: reserve `terret` and `terret-*` on RubyGems, grab the GitHub org, and run a basic trademark search (USPTO TESS + EUIPO) since "Terret" is also a wine grape variety — low collision risk for software.

### Goals

1. **Model-agnostic by construction.** No provider is privileged. The default distribution ships adapters for Anthropic, OpenAI, Google, DeepSeek, and OpenAI-compatible/local endpoints, all behind one streaming seam.
2. **Everything is a plugin.** The agent loop, tool registry, session store, sandbox policy, prompt assembly, and every UI are plugins mounted in a Hames context. There is no privileged core to patch.
3. **Replayable truth.** Anything the model saw must be reconstructable from the append-only session log, enforced by a runtime invariant.
4. **Ruby-idiomatic.** RSpec, Zeitwerk, `Data` value objects, keyword args, blocks for effects, Fiber-based structured concurrency via the `async` ecosystem. It should feel like the best Ruby you've read, not transliterated TypeScript.
5. **Embeddable.** Terret must run as a CLI, a headless one-shot runner, a long-lived daemon with a web UI, *and* as a library inside an existing Rails app (e.g., mounting an agent inside a fintech back office).

### Non-Goals (v1)

- Training, fine-tuning, or eval benchmarking (that's a different kind of "harness"; see §17 on the naming collision with EleutherAI's lm-evaluation-harness).
- A native desktop app.
- Windows support beyond WSL2 (sandbox seams assume POSIX; revisit post-1.0).
- Multi-tenant SaaS concerns (authn/z beyond a bearer token on the local web server).

---

## 2. Research Summary: What `dsh` Actually Is

Findings from the repository (README, `docs/architecture.md`, `docs/cordis-primer.md`), distilled to what matters for a port.

### 2.1 Cordis, the substrate

Cordis is a plugin framework built on five ideas, each of which Terret must reproduce or consciously replace:

1. **A plugin is an object implementing a service lifecycle** — either a function with `inject` + `apply(ctx)` or a Service subclass mounted into a context.
2. **A context is a repository of services.** A service claims a stable key (`ctx.tools`, `ctx.llm`, `ctx.sessions`); consumers find capabilities by key, never by importing a concrete class.
3. **Dependencies are declared via `inject`.** A plugin naming required services waits until they exist; boot order emerges from the dependency graph rather than a manual sequence.
4. **Typed events with four dispatch modes** — `emit` (fire-and-forget, ordered), `waterfall` (around-middleware with `next()`, return values propagate), `parallel` (awaited, concurrent fan-out), `serial` (awaited, ordered, returns a value). The mode is part of each event's public contract.
5. **Registrations are reversible effects.** Every registration (listener, tool schema, prompt section, adapter) is installed through an effect that returns a disposer, so plugin reload/unload unwinds cleanly and hot-reload is safe.

### 2.2 Composition: profiles, bundles, patches

A running `dsh` is a plugin tree composed at boot from ordered layers. A **profile** names a composition (e.g., `web`, `headless`) and lists **bundles** — distribution formats for config rows plus the code they mount. Layers apply in order: each bundle, then the profile's patch file, then the home-level patch, then any `--patch` CLI overlay. A patch targets a config row by id and replaces its config wholesale or inserts rows. `dsh --dump-config` prints the fully resolved tree. The base bundle carries model adapters, tools, persistence, sandbox/approval policy, settings, credentials, and telemetry.

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

`turn/*`, `step/*`, `user/message`, `assistant/*`, `tool/*` are **durable session events**; the rest are live extension points. `agent/pre-step`, `agent/request`, `llm/stream`, and the three `tools/*` events are waterfalls. Input reaches the driver through one inbox; injected context waits in the inbox until a waking message arrives.

### 2.5 The session log invariant

The log is the source of the model's context. `deriveMessages()` projects model history from it; raw `assistant/chunk` events preserve replay and UI fidelity. Fork, resume, transcripts, telemetry, and persistence all derive from this stream. **Model-visible means logged** — a runtime invariant asserts that anything reaching a model request is reconstructable from the log, which is why new model-visible input requires a new session event type.

### 2.6 Capability seams

A **seam** = Service Definition (interface) + Service Provider (implementation) + Consumer (usually a model-facing tool). One provider swap changes the whole product: filesystem and subprocess providers share one execution world, so pointing them at a remote sandbox moves Bash, PTY, and LSP together with no forks. Documented seams include: `ctx.llm` (adapters), `ctx.tools`, `ctx.shell`, `ctx.subprocess`, `ctx.terminals`, `ctx.fs`, `ctx.sandbox`, `ctx.commands` (human slash-commands, no model turn), `ctx.jobs` (background work), `ctx.goals`, `ctx.sessionTitle`, subagent providers, plus `ctx.sessions.fork` for live forking, `agent.inject()` for context injection, and per-agent scoped registration via `agent.ctx`.

### 2.7 What we deliberately do differently

- **Language substrate:** no Cordis to vendor; we build **Hames**, a small (~1,500 LOC target) kernel purpose-built for Ruby, rather than porting Cordis's TypeScript declaration-merging type system. Ruby gives up compile-time event typing; we recover safety with runtime event contracts (see §4.4) and Sorbet/RBS signatures.
- **Monorepo tooling:** pnpm workspaces → a Bundler monorepo of path-referenced gems with a shared Rakefile and `gem_release` fan-out (§5).
- **Web UI:** dsh ships a full browser app; Terret v1 ships a leaner Hotwire (Turbo Streams) web console, because streaming session events map beautifully onto Turbo Streams over SSE/WebSocket, and it keeps the frontend in the Ruby toolchain.
- **Concurrency:** Node's event loop → Ruby Fiber scheduler via `async`. Every agent runs in its own Async task tree; cancellation is structured (§8).

---

## 3. Architecture at a Glance

```
                        ┌─────────────────────────────────────────┐
                        │              Interfaces                 │
                        │  trt CLI · headless runner · web console│
                        │  Rails engine · ACP server              │
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
        │  (adapter seam) (default      ctx.shell     ctx.sandbox        │
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

Hames is Terret's Cordis. It is a standalone gem (`hames`) with zero knowledge of LLMs — reusable for any plugin-composed Ruby application. Keeping it ignorant of the domain is what keeps "everything is a plugin" honest.

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

- `Hames::Service` is a class with lifecycle hooks (`start`, `stop`), a claimed key, and declared injections. A bare plugin can also be any object responding to `apply(ctx)` — the functional form — with optional `inject`. Both mount into the tree identically.
- `ctx.tools` resolution uses `method_missing` backed by a registry with a `respond_to_missing?` implementation and an RBS/Sorbet interface file generated per release, so editors and type checkers see real methods. A `ctx[:tools]` indexer is the canonical metaprogramming-free form.
- **Fork semantics:** `ctx.fork` produces a child context inheriting parent services with copy-on-write registration scopes. Per-agent isolation (`agent.ctx`) is a fork whose registrations dispose when the agent ends. This is the port of dsh's `core/scope`.
- **Isolation realms:** a service row in config may declare `isolate: [:tools]`, giving a subtree its own instance of that service — how an agent preset gets a different capability set (dsh parity).

### 4.2 Plugins as reversible effects

Every registration flows through `ctx.effect`, which takes a block performing side effects and returning a disposer (or uses helpers that auto-dispose):

```ruby
ctx.effect do
  ctx.tools.register(schema)
  -> { ctx.tools.unregister(schema.name) }
end

ctx.on("tools/pre_execute") { |call, next_| ... }   # auto-disposed listener
```

Unloading a plugin disposes its effects in reverse order. This single rule is what makes hot-reload (`trt dev --watch` via `listen` gem) and config patching at runtime safe. Rule of thumb ported directly from Cordis: *if teardown order matters, keep the related work in one effect.*

### 4.3 Events and dispatch modes

Hames reproduces all four Cordis dispatch modes with identical semantics:

| Mode | Ruby dispatch | Awaited | Return value | Use for |
|---|---|---|---|---|
| `emit` | `ctx.emit(name, *args)` | No | No | Notifications (`session/event`) |
| `waterfall` | `ctx.waterfall(name, *args)` | No | Yes | Around-middleware (`agent/request`, `tools/execute`) |
| `parallel` | `ctx.parallel(name, *args)` | Yes (Async barrier) | No | Fan-out hooks |
| `serial` | `ctx.serial(name, *args)` | Yes | Yes | Ordered decisions (`agent/turn_stopping`) |

Waterfall semantics are the load-bearing subtlety and must match Cordis exactly: a listener receives `(*args, next_)`; calling `next_.()` delegates (possibly with rewritten args) and its return value propagates; returning without calling `next_` short-circuits — the design for single-decision policy events. `prepend: true` is supported but discouraged. In Ruby the natural spelling is a block whose last parameter is the continuation:

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

The bus rejects dispatch of undeclared events and dispatch via the wrong mode (dev/test mode raises; production logs). A `rake events:catalog` task generates `docs/events.md` — every event, its mode, producers, and consumers — the port of dsh's generated event map, and CI diffs it so the contract can't drift silently. Payload shapes are `Data` classes (Ruby 3.2+ immutable value objects) with RBS signatures.

### 4.5 Dependency-driven boot

The loader mounts plugins in dependency order derived from `inject` declarations. Missing services park the plugin (mounted-but-inactive) until the service appears — which is what lets a patch insert a provider later in the layer stack than its consumers. Cycles are a boot error with the cycle printed. `trt --profile web --dump-config` prints the fully resolved, layer-annotated tree (dsh parity).

---

## 5. Repository and Gem Layout

One monorepo, many gems, versioned in lockstep (Rails-style). Bundler workspace via path sources during development; `rake release:all` publishes the fan-out.

```
terret/
├── Gemfile / Gemfile.lock          # workspace: path-sourced gems
├── Rakefile                        # build, test-all, events:catalog, release
├── .rspec / .rubocop.yml / .ruby-version (3.4)
├── AGENTS.md / CLAUDE.md           # agent-facing dev guide (dsh parity)
├── docs/
│   ├── architecture.md             # this document, maintained
│   ├── hames-primer.md
│   ├── events.md                   # generated catalog
│   ├── config-catalog.md           # generated from settings schemas
│   └── cookbook/                   # adding-a-tool, adding-an-adapter, ...
├── gems/
│   ├── hames/                      # the kernel (no LLM knowledge)
│   ├── terret-core/                # sessions, prompt, tools, agents, loop
│   ├── terret-llm/                 # message vocabulary + adapter seam
│   ├── terret-llm-anthropic/
│   ├── terret-llm-openai/          # also covers OpenAI-compatible/local
│   ├── terret-llm-gemini/
│   ├── terret-llm-deepseek/
│   ├── terret-exec/                # fs, subprocess, shell, terminals seams
│   ├── terret-sandbox-docker/
│   ├── terret-sandbox-landlock/    # Linux; macOS seatbelt variant
│   ├── terret-tools-std/           # read/write/edit/bash/grep/glob/fetch...
│   ├── terret-mcp/                 # MCP client (stdio + HTTP) as tool source
│   ├── terret-acp/                 # Agent Client Protocol server (editors)
│   ├── terret-store-sqlite/        # session persistence provider
│   ├── terret-web/                 # Roda + Turbo web console bundle
│   ├── terret-headless/            # one-shot runner bundle
│   └── terret/                     # meta-gem: CLI `trt`, profiles, boot
├── bundles/                        # config rows shipped by each bundle
└── examples/
```

Gem dependency direction is strictly downward: interface gems depend on core, core depends on `terret-llm` vocabulary and `hames`, `hames` depends on `async` and stdlib only. Each gem declares its Terret contribution in its gemspec metadata (`metadata["terret"] = { "bundle" => "config/bundle.yml" }`), the port of dsh's `package.json` `dsh` field — this is how third-party gems become discoverable bundles (`gem install terret-tool-foo` then reference it in a profile).

---

## 6. Core Subsystems

### 6.1 Session log (`ctx.sessions`) — gem `terret-core`

The heart. An append-only log of `SessionEvent`s per session, with an in-memory store and pluggable persistence.

- **Event envelope:** `Data.define(:id, :session_id, :seq, :at, :type, :payload, :parent_id)` — `seq` is a per-session monotonic integer; `parent_id` supports forking.
- **Durable event types (v1):** `turn/start`, `turn/end`, `step/start`, `step/end`, `user/message`, `assistant/chunk`, `assistant/message`, `tool/call`, `tool/result`, `session/created`, `session/forked`, `session/titled`, `context/injected`, `approval/requested`, `approval/resolved`. The set is open: plugins extend the event map (`Hames.event "session/x", durable: true`) and must provide a renderer for `derive_messages`.
- **`derive_messages(session, upto: nil)`** projects provider-neutral model history from the log. This is the *only* path by which context reaches an adapter.
- **The invariant, enforced:** before each request the loop computes a digest of the outbound message list and asserts it equals the digest of `derive_messages` replayed from persisted events. In dev/test a mismatch raises `Terret::LogInvariantViolation`; in production it emits a high-severity telemetry event. This is the mechanical form of "model-visible means logged."
- **Persistence seam:** in-memory (default for tests), JSONL-per-session (default for CLI, greppable), SQLite (`terret-store-sqlite`, default for web/daemon; WAL mode; one writer Fiber per session). Providers implement `append(event)`, `read(session_id, from_seq:)`, `stream(session_id)` (returns an Async queue), `fork(source, boundary_seq, child_id)`.
- **Fork/resume:** `ctx.sessions.fork(source, boundary: seq)` copies events up to the boundary under a new session id with `session/forked` recording lineage. Resume = load events, replay derived state, reopen the inbox.
- Everything downstream — transcripts (`trt export`), the web console, telemetry, titling — consumes the same `session/event` emission. No side channels.

### 6.2 Prompt assembly (`ctx.prompt`)

Plugins register **prompt sections** (name, priority, block returning content or nil) and the tool registry contributes schemas. Per step, assembly is: collect sections for this agent's scope → order by priority → render against a `PromptEnv` (agent, session, workdir, model capabilities) → cache-stability pass (stable section ordering and byte-identical rendering when inputs are unchanged, so provider prompt caching actually hits). Sections are effects — unload a plugin and its section leaves the prompt.

### 6.3 Tool registry and guarded pipeline (`ctx.tools`)

- **Definition:** name, description, JSON Schema params (hand-written or derived from a `Data` class via `dry-schema`→JSON Schema), handler, and metadata: `mutating:`, `concurrency: :safe|:exclusive`, `approval: :never|:policy|:always`.
- **Registration is scoped:** global (`ctx.tools.register`) or per-agent (`agent.ctx.tools.register`) — subagents and presets get different tool sets without global state.
- **Pipeline (waterfalls, dsh parity):** `tools/pre_execute` (validation, approval gating, argument rewriting, policy veto) → `tools/execute` (a provider may replace execution entirely — this is how a remote sandbox takes over Bash without forking the tool) → `tools/post_execute` (result truncation, redaction, telemetry). `tool/call` and `tool/result` are the durable bookends.
- **Approvals:** an `ctx.approvals` service; when policy requires it, the pipeline parks the call, emits durable `approval/requested`, and resumes on `approval/resolved` (CLI prompt, web button, or auto-policy). Parked calls survive process restarts because both sides are in the log.
- **Concurrent tool calls:** calls in one assistant message run in an Async barrier honoring each tool's concurrency class; `:exclusive` tools serialize.

### 6.4 Agents and the loop (`ctx.agents`, `ctx.loop`)

- **`Agent`** is an interface: an id, a session, an **inbox** (single Async queue), a status machine (`idle → running → waiting_approval | waiting_input → stopping → done/failed`), `inject(content, wake: false)` for context injection (queued until a waking message arrives — dsh inbox semantics), and `cancel(reason)`.
- **`ctx.loop`** is the default driver implementing the turn flow in §2.4, translated event-for-event (Ruby names use `_`: `agent/pre_step`, `agent/turn_stopping`). It is itself a plugin — a research harness can replace the driver (tree-of-thought, multi-model debate, graph execution) while every tool, adapter, and UI keeps working. This is the single most important portability property to preserve.
- **Turn accounting:** a rejected or empty first claim still closes a durable turn that spent no step, so the log records the attempt (dsh parity — matters for observability).
- **Subagents (`ctx.subagents`):** one interface, multiple providers — fresh child agent in a forked context (default), delegated turn to an external agent (ACP client), or a pooled worker. The `task` tool consumes the seam.
- **Goals (`ctx.goals`):** same-session objective tracking that continues work through `agent/*` events (v1: minimal — persist a goal, offer a `goal_status` tool).

### 6.5 LLM seam (`ctx.llm`) — gems `terret-llm*`

- **Vocabulary:** provider-neutral `Data` types — `Message(role:, parts:)` with parts `Text`, `ToolCall(id:, name:, args:)`, `ToolResult(id:, content:, error:)`, `Image`, `Thinking(content:, signature:)`; `StreamEvent` union (`MessageStart`, `TextDelta`, `ThinkingDelta`, `ToolCallStart/Delta/End`, `Usage`, `MessageStop`, `StreamError`).
- **Adapter contract:** `capabilities` (tools?, vision?, thinking?, caching?, max context), `count_tokens(messages)` (heuristic fallback provided), and `stream(request) { |event| ... }` yielding `StreamEvent`s from within an Async task. Retries with jittered backoff, 429/overload handling, and mid-stream error surfacing (`StreamError` → the loop decides retry vs. fail-turn) are handled in a shared `AdapterBase`.
- **`llm/stream` is a waterfall** wrapping every request: middleware can rewrite requests (model routing, prompt caching headers, failover chains, cost caps) or replace the stream (record/replay for tests).
- **Model routing:** config maps logical roles (`main`, `titler`, `subagent`, `cheap`) to `provider/model` strings; anything can be pointed anywhere, including a local Ollama endpoint — the concrete meaning of "not just DeepSeek."
- **Transport:** `async-http` for native SSE streaming on the Fiber scheduler (no thread-per-request). Native adapters are thin (~200 LOC each) rather than wrapping `ruby_llm`/`langchainrb`, keeping the streaming seam exact; a `terret-llm-rubyllm` bridge gem can exist as a community plugin.

### 6.6 Execution world (`terret-exec` + sandbox gems)

The seam trio, ported intact: **`ctx.fs`** (read/write/stat/glob/watch behind a provider; `fs/*` policy events for path allow/deny), **`ctx.subprocess`** (spawn/PTY behind a provider), **`ctx.shell`** (persistent bash sessions built on subprocess), **`ctx.terminals`** (long-lived PTYs + the terminal tool). Because fs and subprocess share one execution world, swapping in the Docker provider moves *all* of Read/Write/Edit/Bash/PTY into the container together — no per-tool forks. **`ctx.sandbox`** wraps argv before spawn: providers `none` (trusted), `docker` (default isolation), `landlock` (Linux), `seatbelt` (macOS). Local PTY via the `pty` stdlib inside Async.

### 6.7 Standard tools (`terret-tools-std`)

v1 set: `read_file`, `write_file`, `edit_file` (string-replace with uniqueness check), `glob`, `grep` (ripgrep if present, pure-Ruby fallback), `bash`, `terminal_*`, `web_fetch`, `task` (subagent), `job_start/collect/stop` (background work via `ctx.jobs`), `todo` (plan tracking). Each tool is its own plugin file; each declares mutating/concurrency/approval metadata honestly, because policy hangs off it.

### 6.8 Interop: MCP and ACP

- **`terret-mcp`:** MCP *client* — connect stdio and streamable-HTTP servers; discovered tools register into `ctx.tools` under a namespace with per-server approval policy; resources become prompt sections on demand. This instantly makes the tool ecosystem "cutting edge" without writing hundreds of tools.
- **`terret-acp`:** Agent Client Protocol server so Zed/JetBrains/other ACP editors can drive a Terret agent; and an ACP *client* subagent provider so Terret can delegate to other agents. Both are just interfaces over `ctx.agents` + `session/event` — proof the core seams are right.

### 6.9 Commands, settings, credentials, telemetry, titling

`ctx.commands`: human slash-commands dispatched without a model turn (`/model`, `/fork`, `/export`, `/approve`). `ctx.settings`: layered config access with `dry-schema` validation per plugin; schemas feed the generated config catalog. `ctx.credentials`: keyring-style store (encrypted file default; OS keychain provider optional); adapters resolve keys by provider name; ENV always wins. `ctx.telemetry`: OpenTelemetry-compatible spans/events derived from the session stream, exporter pluggable, off by default. `ctx.titler`: sole-provider seam generating session titles with the `titler` model role.

---

## 7. Composition: Profiles, Bundles, Patches

Direct port of the dsh layering model, YAML-native.

- **Bundle:** a gem shipping `config/bundle.yml` — an ordered list of config rows, each `{id, plugin, config, disabled}`. `terret-base` (inside the meta-gem) is layer one of every profile: adapters, std tools, persistence, sandbox+approval policy, settings, credentials, telemetry.
- **Profile:** a named composition in Terret home (`~/.terret/profiles/<name>/profile.yml`): the bundles it stacks, out-of-tree plugins it installs, and its `patch.yml`. `web` and `headless` ship as templates.
- **Layer order:** bundles in listed order → profile `patch.yml` → home-level `~/.terret/patch.yml` → `--patch file.yml` overlays. A patch targets a row by id and replaces its whole config (never deep-merges — wholesale replacement is dsh's rule and it avoids merge ambiguity) or inserts new rows with `after:`/`before:` anchors.
- **Dynamic values:** where Cordis uses `!!js` expressions, Terret uses tagged scalars evaluated in a sandboxed binding at mount time: `!env OPENAI_BASE_URL`, `!setting sandbox.image`, `!ruby ctx[:settings].get("...")` (the `!ruby` tag requires `--allow-config-ruby`, off by default — config is data first).
- **Introspection:** `trt --profile web --dump-config` prints the resolved tree annotated with which layer contributed each row. `trt doctor` validates every row's config against its plugin's schema before boot.

Example patch — swap the whole execution world onto Docker and point the main model at a local endpoint:

```yaml
# ~/.terret/profiles/web/patch.yml
rows:
  - id: sandbox
    plugin: terret-sandbox-docker
    config: { image: "terret/sandbox:latest", network: none }
  - id: llm.main
    config: { provider: openai_compatible, base_url: !env OLLAMA_URL, model: "qwen3:32b" }
```

## 8. Concurrency Model

- **Substrate:** `async` (Fiber scheduler). The process runs one reactor; each agent is an Async task tree: inbox reader → turn task → per-step stream task + tool barrier. No user-facing threads; SQLite writes go through a per-session writer task.
- **Structured cancellation:** `agent.cancel` stops the task tree top-down: the in-flight HTTP stream is closed, running tools receive a cooperative `Cancellation` token (subprocess tools escalate SIGTERM→SIGKILL), a durable `turn/end(status: cancelled)` is appended. Mirrors dsh's cancellation/error-recovery contract.
- **Backpressure:** `assistant/chunk` fan-out to UIs goes through bounded queues; a slow web client drops to snapshot-then-tail rather than stalling the loop.
- **Why not Ractors:** adapters and tools need shared services; Ractor isolation buys nothing here and costs everything. CPU-heavy work (rare) can use a thread pool behind `ctx.jobs`.

## 9. Interfaces

- **CLI (`trt`):** interactive TUI chat (chunk streaming, approval prompts, slash-commands), plus `run` (headless one-shot: prompt in, transcript out, exit code from turn status — CI-friendly), `web`, `sessions list/export/fork`, `doctor`, `--dump-config`. Built on `dry-cli`; TUI rendering with `tty-*` or a thin custom renderer (decide in M4; keep the renderer behind an interface).
- **Web console (`terret-web`):** Roda + Turbo. Session list, live transcript rendered from `session/event` over an SSE/WebSocket tail, approval buttons, config viewer (read-only dump-config), fork button. Server-rendered; a heavier SPA can arrive later as a bundle without touching core — renderer nodes are keyed by event type, the analogue of dsh's ConversationNodeDefinition.
- **Rails engine (later, `terret-rails`):** mounts the console and exposes `Terret.boot(profile:)` for embedding agents in an existing app.

## 10. Dependency Choices

| Concern | Choice | Notes |
|---|---|---|
| Ruby | 3.4+ | `Data`, Fiber scheduler maturity, YJIT default |
| Kernel deps | stdlib + `async` | hames stays tiny |
| HTTP/SSE | `async-http` | native fiber streaming |
| Autoload | `zeitwerk` | per-gem loaders |
| Config validation | `dry-schema` | also generates config catalog + tool JSON Schemas |
| CLI | `dry-cli` | |
| Web | `roda` + `turbo` assets | no Rails dependency in core path |
| SQLite | `sqlite3` (WAL) | store gem only |
| JSON | `oj` (optional) fallback stdlib | hot path: chunk events |
| Types | RBS + Steep in CI | signatures for public seams; not Sorbet (runtime cost in hot loop) |
| Lint | RuboCop + rubocop-rspec | |
| Docs | YARD; generated events.md / config-catalog.md | CI-diffed |

## 11. Testing Strategy

- **RSpec throughout.** Kernel: exhaustive unit specs for dispatch modes (waterfall short-circuit, prepend, disposal order), fork/isolate semantics, loader ordering, hot-unload.
- **Loop specs against a scripted adapter:** a `FakeAdapter` driven by declarative scripts (message → tool calls → message) makes turn-flow specs deterministic and fast; every event sequence in §2.4 has a golden-order spec.
- **Log invariant property tests:** generate random plugin sets that inject context/rewrite claims; assert `derive_messages` digest always matches the outbound request.
- **Adapter contract suite:** one shared RSpec behavior (`it_behaves_like "an llm adapter"`) run against every adapter with VCR-style recorded streams (custom SSE cassette recorder — VCR itself mangles streaming; budget 2–3 days) plus a live smoke lane behind env keys.
- **Tool/sandbox integration:** Docker-based specs in CI (Linux runners); landlock specs on a Linux matrix; snapshot specs for prompt assembly (byte-stable rendering is a *test*, since caching depends on it).
- **End-to-end:** headless runner against Ollama in CI running a tiny local model for true no-key E2E.
- **Bench lane:** `rake bench` tracks chunk-throughput and per-event dispatch overhead so kernel changes can't silently regress streaming.

## 12. Milestones

Each phase ends with demoable acceptance criteria; estimates assume ~1 experienced Ruby engineer + agent leverage.

**M0 — Spike (1 wk).** Hames event bus + effects + waterfall semantics proven; a 200-line toy app (no LLM) composes three plugins from YAML layers and hot-unloads one. *Accept:* dispatch-mode spec matrix green; disposal order proven.

**M1 — Kernel + boot (2 wks).** Full Hames: services, inject-driven boot, fork/isolate, event contracts, `dump-config`, patch layering. *Accept:* dsh §Cordis primer semantics reproduced 1:1 in specs; events catalog generation working.

**M2 — Log + loop + one adapter (3 wks).** Session log with invariant, derive_messages, prompt assembly, tool registry/pipeline, default loop, Anthropic adapter, in-memory + JSONL stores. *Accept:* headless `trt run "..."` completes multi-step tool turns; golden event-order specs green; invariant survives an injected-context property test.

**M3 — Execution world (3 wks).** fs/subprocess/shell/terminals seams, std tools, sandbox `none` + `docker`, approvals end-to-end. *Accept:* the Docker-swap demo — one patch row moves bash+read+write+PTY into a container with zero tool changes.

**M4 — Multi-model + interfaces (3 wks).** OpenAI/compatible, Gemini, DeepSeek adapters; model roles/routing; interactive TUI; SQLite store; fork/resume; titling. *Accept:* same session driven across three providers mid-conversation via `/model`; kill -9 then resume with identical derived context.

**M5 — Web + interop (3 wks).** Web console (live tail, approvals, fork), MCP client, subagents + `task` tool, jobs. *Accept:* an MCP server's tools appear and execute under policy; web approval unblocks a parked CLI-started session.

**M6 — Hardening + 0.1 release (2 wks).** ACP server, docs/cookbook, `doctor`, bench lane, security pass (§13), RubyGems fan-out, example third-party plugin gem published from a separate repo to prove the extension story.

~17 weeks to a credible public 0.1.

## 13. Security Posture

Sandbox `docker` with `network: none` is the *default* for untrusted work; `none` requires explicit opt-in per profile. Approval policy defaults: mutating fs tools `:policy`, bash `:always` outside a sandbox, `:policy` inside. Credentials never enter the session log (redaction in `tools/post_execute` + a log-append scrubber). `web_fetch` gets an allow/deny domain policy row. Prompt-injection stance: tool results are data — the loop never executes instructions from tool output except through the model, and the approval seam is the human backstop; document this threat model explicitly in `docs/security.md`.

## 14. Risks and Open Questions

- **Waterfall ergonomics in Ruby.** Explicit `next_.()` is unfamiliar; the M0 spike exists partly to validate the API feel before it fossilizes. Fallback: a `throw/catch`-based short-circuit sugar.
- **Fiber-scheduler edge cases** in `sqlite3` and `pty` under load — mitigate with the writer-task pattern and M3 soak tests.
- **Event typing without a compiler.** Runtime contracts + CI catalog diffing is the bet; if drift still bites, add a Steep-checked events RBS generated from declarations.
- **Scope creep toward dsh's full web app.** The Turbo console is deliberately modest; hold the line until core seams are stable.
- **Name check:** `terret` clean on RubyGems as of today; re-verify + reserve immediately, including `hames`.
- **Open:** should `hames` live in its own repo from day one (cleaner story, more overhead)? Should the meta-gem vendor a pinned `terret-base` bundle version map (dsh-style lockstep) — leaning yes.

## 15. What "Cutting Edge" Means Here, Concretely

Interleaved thinking blocks preserved as first-class message parts and replayed; provider prompt-caching made *reliable* by byte-stable prompt assembly; mid-conversation model switching on one session log; structured cancellation; parked approvals that survive restarts; MCP + ACP interop; a replaceable agent loop. Each of these is a direct consequence of two disciplines: everything is a plugin, and model-visible means logged. Keep those two and the rest stays honest.

## 16. Immediate Next Actions

1. Reserve `terret`, `terret-*`, `hames` on RubyGems; create the GitHub org.
2. Run the M0 spike; publish the dispatch-mode spec matrix as the kernel's contract.
3. Write `docs/hames-primer.md` *before* M1 code — the primer-first discipline is one of dsh's best exports.

## 17. Appendix: Naming Landscape

"Harness" in ML also means eval harnesses (EleutherAI lm-evaluation-harness) — Terret's docs should say "agent harness" in the first sentence everywhere. Tack-derived candidate table: Terret (chosen — the rein-guiding ring; short, pronounceable, unclaimed), Hames (kernel — the load-bearing arcs), Crupper/Surcingle/Breeching (reserve), Martingale (rejected — finance collision). CLI `trt` is three keystrokes and unclaimed in PATH conventions.
