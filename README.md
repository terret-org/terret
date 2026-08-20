# Terret

A Ruby-native, model-agnostic agent harness where **everything is a plugin**,
informed by DeepSeek Harness. A *terret* is the ring on a horse harness that
the driving reins pass through — the small component that lets one driver
guide any horse. **Hames** is the kernel underneath (the load-bearing pieces
of the harness): services in a context, typed events with four dispatch
modes, reversible effects, dependency-driven boot.

Twelve gems in one repo:

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
- `gems/terret-acp` is the second interface: an Agent Client Protocol server
  behind `ctx[:acp]` so an editor can drive an agent over JSON-RPC on stdio.
  It consumes `session/event` and drives `ctx[:loop]` — the same two seams the
  socket does, on a different transport, with no change to core; mapping in
  `docs/acp.md`. stdlib-only, no network gem.
- `gems/terret-mcp` is the MCP client: manceps-backed stdio and
  streamable-HTTP servers mounted as `mcp__<server>__<tool>` sources behind
  `ctx[:tools]`, per-server approval, per-call timeouts, the allow list in
  `terret-core`; mapping in `docs/mcp.md`.
- `gems/terret-morph` is a `ctx[:summarizer]` provider: Morph's Compact API
  on the wire proven in the deployed agora integration, extractive-
  compressing a session's history instead of asking a model to write a
  summary. Every failure declines to nil rather than raising, and an
  injectable transport keeps its unit tests off the network.
- `gems/terret-exec` is the execution world: `ctx[:fs]`, whose every path
  is contained to a granted workspace directory; `ctx[:subprocess]`, spawn
  and PTY under the one reactor with cooperative cancellation;
  `ctx[:shell]`, one persistent bash per agent whose cwd and environment
  survive between calls; `ctx[:terminals]`, named long-lived PTYs; and the
  `ctx[:sandbox]` seam every argv passes through before it spawns.
- `gems/terret-tools-std` is the standard tool roster, carrying Claude
  Code's names verbatim — `Read`, `Write`, `Edit`, `Glob`, `Grep`, `Bash`,
  `WebFetch`, and `terminal_open`/`input`/`read`/`close` — registered on
  those seams with honest `mutating` and `approval` metadata. `Bash`
  derives its approval from whether the sandbox isolates, and `WebFetch`
  sits behind a deny-by-default domain policy re-checked on every redirect
  hop.
- `gems/terret-sandbox-docker` is the container sandbox: one patch row
  moves the whole execution world into a long-lived container, with each
  workspace directory bind-mounted at the same absolute path and
  `--network none` by default.
- `gems/terret` is the meta-gem: the composition layer and the `trt`
  command. Bundles ship ordered config rows, profiles stack bundles,
  patches adjust rows by id, and `Terret.boot` hands the result to the
  Hames loader — so which plugins run, in what order, with what config is
  a question YAML answers rather than Ruby. Ships `terret-base` (the log,
  the harness, the model seam, the execution world sandboxed with the
  network denied, the standard tool roster, and a policy floor that starts
  closed), the `headless` profile template, and `trt boot` /
  `trt dump-config` / `trt doctor` / `trt acp`. Contract in
  `docs/composition.md`.

## Status

Milestones M0 through M7 are shipped: the Hames kernel, the session log
with the "model-visible means logged" invariant, the tools pipeline, the
agent loop, the OpenRouter adapter, durable SQLite sessions, the WebSocket
interface, the MCP client, long-lived agent hardening — durable
approvals, resumable turns that survive a `kill -9`, context compaction
behind a summarizer seam, session titling, per-session cost accounting, and
hot-reloadable per-agent policy — and the execution world: the filesystem,
subprocess, shell, and terminal seams under workspace scoping, the standard
tool roster on top of them, credential redaction at both the tool pipeline
and the log-append boundary, and a sandbox seam whose `docker` provider
moves everything a tool executes into a container from one config row.
`LLM::FakeAdapter` (canned script replay) remains the test/demo default;
the OpenRouter path is proven by canned-wire tests plus a live smoke lane.
Session payloads are primitives at the append boundary; typed parts encode
through `LLM.encode_part`.

The full roadmap, including what is not yet built (M8 subagents and the 0.1
release), is `docs/terret-implementation-plan.md`; see its §12 for
milestone detail. Note
the plan has drifted from the code in places: it specifies RSpec (this uses
minitest), Ruby 3.4+ (this targets 4.0.6), and a separate `terret-llm` gem
(the vocabulary lives in `terret-core`). Treat the code as current and the
plan as intent.

## Commands

```bash
rake test              # all suites, plain minitest, no bundler needed
rake events:catalog    # regenerates docs/events.md
rake config:catalog    # regenerates docs/config-catalog.md
rake bench             # bench/README.md — chunk throughput + dispatch overhead
rake bench BENCH_FLOORS=1   # also asserts against bench/floors.yml (CI runs this)
trt doctor --profile headless   # validate a profile's config without booting
trt acp --profile headless      # serve the Agent Client Protocol on stdio for an editor
ruby examples/headless_demo.rb
OPENROUTER_API_KEY=... ruby examples/openrouter_demo.rb   # real model; needs async-http
bundle exec ruby examples/ws_demo.rb   # real websocket loopback demo
bundle exec ruby examples/mcp_demo.rb   # MCP tools from a local stdio fixture
ruby examples/lifecycle_demo.rb   # park/resume, compaction, titling, cost, hot policy
ruby examples/exec_demo.rb   # file tools, shell, terminals, redaction; the container act needs docker
ruby examples/subagent_demo.rb   # Task delegation, background jobs, TodoWrite, the tool barrier
ruby examples/boot_demo.rb   # bundles, profiles, patches; dump-config, boot, one turn
```

Ruby 4.0.6, pinned in `.ruby-version` and `mise.toml`. `hames` and
`terret-core` have zero runtime dependencies beyond stdlib, and that is a
design constraint rather than a coincidence. Network-touching dependencies
belong in adapter/interface gems (`terret-openrouter` carries `async-http`),
never in the kernel or core.

## Documentation

- `docs/terret-implementation-plan.md` — the full roadmap and design
  rationale.
- `docs/hames-primer.md` — the kernel on its own terms: services in a
  context, reversible effects, the four dispatch modes, config rows and
  reconfigure, and `Hames::Schema`. No LLM or agent vocabulary, because the
  kernel has none.
- `docs/cookbook/` — worked, end-to-end recipes for building on Terret:
  adding a tool, adding a provider, adding a bundle. Start at
  `docs/cookbook/README.md`.
- `docs/protocol.md` — the WebSocket wire contract (`terret-ws`).
- `docs/acp.md` — the Agent Client Protocol mapping (`terret-acp`).
- `docs/mcp.md` — the MCP tool-source mapping (`terret-mcp`).
- `docs/exec.md` — the execution world: the seams, workspace scoping, the
  sandbox, the std tool roster, and redaction.
- `docs/security.md` — the threat model the execution world is built
  against, and where its boundaries honestly stop.
- `docs/events.md` — the generated event catalog; regenerate with
  `rake events:catalog` whenever an event's contract changes.
- `docs/config-catalog.md` — the generated config catalog, one section per
  service with a schema; regenerate with `rake config:catalog` whenever a
  service's config surface changes. `trt doctor` validates a profile against
  these same schemas.

## License

MIT. See `LICENSE.txt`.
