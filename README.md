# Terret

A Ruby-native, model-agnostic agent harness where **everything is a plugin**,
informed by DeepSeek Harness. A *terret* is the ring on a horse harness that
the driving reins pass through — the small component that lets one driver
guide any horse. **Hames** is the kernel underneath (the load-bearing pieces
of the harness): services in a context, typed events with four dispatch
modes, reversible effects, dependency-driven boot.

Eight gems in one repo:

- `gems/hames` is the kernel. Services in a context, typed events, reversible
  effects, dependency-driven boot. It knows nothing about LLMs and is
  reusable for any plugin-composed application.
- `gems/terret-core` is the harness built on it. Session log, tools
  pipeline, agent loop, LLM seam (vocabulary, `AdapterBase` retry policy,
  `FakeAdapter`).
- `gems/terret-openrouter` is the one real adapter: OpenRouter's
  OpenAI-compatible API behind `ctx.llm`, streaming SSE with tool calling and
  usage accounting. The transport is injectable, so its unit tests need no
  network and no gems; only the default `AsyncTransport` requires
  `async-http`.
- `gems/terret-store-sqlite` is the durable session store: the append-only
  log, one event per row in SQLite (WAL), behind the `ctx[:session_store]`
  seam. Memory and JSONL providers live in `terret-core`; the store row is
  explicit in every boot.
- `gems/terret-ws` is the v1 interface: one WebSocket per agent behind
  `ctx[:ws]`, the wire frames, exact replay-then-tail on the session log; the
  wire contract is in `docs/protocol.md`; only the real endpoint requires
  `async-websocket`.
- `gems/terret-mcp` is the MCP client: manceps-backed stdio and
  streamable-HTTP servers mounted as `mcp__<server>__<tool>` sources behind
  `ctx[:tools]`, per-server approval, per-call timeouts, the allow list in
  `terret-core`; mapping in `docs/mcp.md`.
- `gems/terret-morph` is a `ctx[:summarizer]` provider: Morph's Compact API
  on the wire proven in the deployed agora integration, extractive-
  compressing a session's history instead of asking a model to write a
  summary. Every failure declines to nil rather than raising, and an
  injectable transport keeps its unit tests off the network.
- `gems/terret` is a placeholder holding the name. It will carry profiles
  and boot. None of that is written yet.

## Status

Milestones M0 through M6 are shipped: the Hames kernel, the session log
with the "model-visible means logged" invariant, the tools pipeline, the
agent loop, the OpenRouter adapter, durable SQLite sessions, the WebSocket
interface, the MCP client, and long-lived agent hardening — durable
approvals, resumable turns that survive a `kill -9`, context compaction
behind a summarizer seam, session titling, per-session cost accounting, and
hot-reloadable per-agent policy. `LLM::FakeAdapter` (canned script replay)
remains the test/demo default; the OpenRouter path is proven by canned-wire
tests plus a live smoke lane. Session payloads are primitives at the append
boundary; typed parts encode through `LLM.encode_part`.

The full roadmap, including what is not yet built (M7 execution world, M8
subagents and 0.1 release), is `docs/terret-implementation-plan.md`; see
its §12 for milestone detail. Note
the plan has drifted from the code in places: it specifies RSpec (this uses
minitest), Ruby 3.4+ (this targets 4.0.6), and a separate `terret-llm` gem
(the vocabulary lives in `terret-core`). Treat the code as current and the
plan as intent.

## Commands

```bash
rake test              # all suites, plain minitest, no bundler needed
rake events:catalog    # regenerates docs/events.md
ruby examples/headless_demo.rb
OPENROUTER_API_KEY=... ruby examples/openrouter_demo.rb   # real model; needs async-http
bundle exec ruby examples/ws_demo.rb   # real websocket loopback demo
bundle exec ruby examples/mcp_demo.rb   # MCP tools from a local stdio fixture
ruby examples/lifecycle_demo.rb   # park/resume, compaction, titling, cost, hot policy
```

Ruby 4.0.6, pinned in `.ruby-version` and `mise.toml`. `hames` and
`terret-core` have zero runtime dependencies beyond stdlib, and that is a
design constraint rather than a coincidence. Network-touching dependencies
belong in adapter/interface gems (`terret-openrouter` carries `async-http`),
never in the kernel or core.

## Documentation

- `docs/terret-implementation-plan.md` — the full roadmap and design
  rationale.
- `docs/protocol.md` — the WebSocket wire contract (`terret-ws`).
- `docs/mcp.md` — the MCP tool-source mapping (`terret-mcp`).
- `docs/events.md` — the generated event catalog; regenerate with
  `rake events:catalog` whenever an event's contract changes.

## License

MIT. See `LICENSE.txt`.
