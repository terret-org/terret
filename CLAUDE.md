# Terret

Ruby-native, model-agnostic agent harness where everything is a plugin. Seven gems in one
repo:

- `gems/hames` is the kernel. Services in a context, typed events, reversible effects,
  dependency-driven boot. It knows nothing about LLMs and is reusable for any
  plugin-composed application.
- `gems/terret-core` is the harness built on it. Session log, tools pipeline, agent loop,
  LLM seam (vocabulary, `AdapterBase` retry policy, `FakeAdapter`).
- `gems/terret-openrouter` is the one real adapter (plan §6.5): OpenRouter's
  OpenAI-compatible API behind `ctx.llm`, streaming SSE with tool calling and usage
  accounting. The transport is injectable, so its unit tests need no network and no
  gems; only the default `AsyncTransport` requires `async-http`.
- `gems/terret-store-sqlite` is the durable session store (M3): the append-only log
  one event per row in SQLite (WAL) behind the `ctx[:session_store]` seam. Memory and
  JSONL providers live in terret-core; the store row is explicit in every boot.
- `gems/terret-ws` is the v1 interface (M4): one WebSocket per agent behind `ctx[:ws]`,
  the §9.2 frames, exact replay-then-tail on the session log; wire contract in
  `docs/protocol.md`; only the real endpoint requires `async-websocket`.
- `gems/terret-mcp` is the MCP client (M5): manceps-backed stdio and streamable-HTTP
  servers mounted as `mcp__<server>__<tool>` sources behind `ctx[:tools]`, per-server
  approval, per-call timeouts, the allow list in terret-core; mapping in `docs/mcp.md`.
- `gems/terret` is a placeholder holding the name. It will carry profiles and boot.
  None of that is written. Do not add real behaviour here without reading §5 and §9 of
  the plan first.

The full roadmap is `docs/terret-implementation-plan.md`; phases are in its §12. What is
here covers M0–M5: kernel, session log with the invariant, tools pipeline, loop, the
OpenRouter adapter, the socket, and the MCP client. `LLM::FakeAdapter` (canned script
replay) remains the test/demo default; the OpenRouter path is proven by canned-wire tests
plus a live smoke lane. Session payloads are primitives at the append boundary; typed
parts encode through `LLM.encode_part`.

Note the plan has drifted from the code in places. It specifies RSpec (this uses minitest),
Ruby 3.4+ (this targets 4.0.6), and a separate `terret-llm` gem (the vocabulary lives in
terret-core). Treat the code as current and the plan as intent.

## Commands

```bash
rake test              # all suites, plain minitest, no bundler needed
rake events:catalog    # regenerates docs/events.md
ruby examples/headless_demo.rb
OPENROUTER_API_KEY=... ruby examples/openrouter_demo.rb   # real model; needs async-http
bundle exec ruby examples/ws_demo.rb   # real websocket loopback demo
bundle exec ruby examples/mcp_demo.rb   # MCP tools from a local stdio fixture
```

Ruby 4.0.6, pinned in `.ruby-version` and `mise.toml`. `hames` and `terret-core` have zero
runtime dependencies beyond stdlib, and that is a design constraint rather than a
coincidence. Think hard before adding a gem to any gemspec; network-touching dependencies
belong in adapter/interface gems (`terret-openrouter` carries `async-http`), never in the
kernel or core.

## Invariants worth protecting

**Model-visible means logged.** `Sessions#derive_messages` projects model history from the
append-only durable log, and `assert_log_invariant!` digests the outbound request against
that projection before it reaches an adapter. Middleware that smuggles content into a
request without appending it raises. If you find yourself wanting to relax this to make a
feature work, the feature is wrong.

**Dispatch mode is public contract.** Every event is declared once in
`Terret.declare_events!` with one of `:emit`, `:waterfall`, `:parallel`, `:serial`. The bus
refuses undeclared events and refuses a declared event dispatched through the wrong mode.
`docs/events.md` is generated from those declarations and CI diffs it, so changing a mode
shows up in review.

**Registration is reversible.** Services, listeners, and prompt sections all install
through `ctx.effect`, which returns a disposer recorded against the mounting plugin. That
is what makes `Loader#unload!` and forked agent scopes work. New registration paths go
through `effect` too.

## Conventions

- `# frozen_string_literal: true` on every file.
- `Data.define` for value types, `Struct` only where mutation is the point (`Sessions::Session`).
- Services subclass `Hames::Service`, declare `service_key`, and list dependencies with
  `inject`. The loader mounts in dependency order derived from those lists, so declaring
  `inject` accurately matters more than it looks.
- Config layering replaces a row's config wholesale. It is never a deep merge.
- Tests are plain minitest files run directly by the Rakefile glob, one per gem under
  `gems/*/test/`.

## Adding an event

Declare it in `Terret.declare_events!` with its mode and, if it belongs in the session log,
`durable: true`. Durable events can then be appended via `Sessions#append`, which fans them
out on `session/event`. Run `rake events:catalog` and commit the regenerated
`docs/events.md` in the same change.
