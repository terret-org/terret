# Terret

A Ruby-native, model-agnostic agent harness where **everything is a plugin**,
informed by DeepSeek Harness. A *terret* is the ring on a horse harness that
the driving reins pass through — the small component that lets one driver
guide any horse. **Hames** is the kernel underneath (the load-bearing pieces
of the harness): services in a context, typed events with four dispatch
modes, reversible effects, dependency-driven boot.

This repository is the M0–M2 vertical slice from the implementation plan:
the complete Hames kernel plus enough of Terret core to run real multi-step
tool turns against a scripted adapter, with the full event choreography and
the "model-visible means logged" invariant enforced.

## Status

Working now (28 tests, zero runtime dependencies beyond Ruby 3.2 stdlib):

- **Hames kernel** — contexts, services, `inject`-ordered boot, layered
  config rows with wholesale-replacement patching, `emit`/`waterfall`/
  `parallel`/`serial` dispatch with runtime mode contracts, reversible
  effects with per-plugin disposal, forked (agent-scoped) contexts,
  hot unload.
- **Session log** — append-only durable events, `derive_messages`
  projection, fork with lineage, optional JSONL persistence, and a digest
  invariant that raises if any middleware smuggles unlogged content into a
  model request.
- **Tools** — scoped registry; `pre_execute → execute → post_execute`
  waterfall pipeline with policy veto and wholesale execution replacement
  (the remote-sandbox seam).
- **Agent loop** — the turn/step choreography as a replaceable plugin:
  claims, inbox injection, rejected-turn accounting, streamed chunks,
  multi-step tool continuation.
- **LLM seam** — provider-neutral vocabulary, model roles, the `llm/stream`
  waterfall, and a deterministic `FakeAdapter` for tests and replay.

Not yet here (next milestones in `docs/terret-implementation-plan.md`):
real adapters over async-http, the execution-world seams (fs/subprocess/
sandbox), approvals, MCP/ACP, CLI/web interfaces.

## Try it

```
rake test                     # kernel + loop suites
ruby examples/headless_demo.rb
rake events:catalog           # regenerates docs/events.md
```

The demo runs a two-step tool turn where a policy plugin vetoes one tool
call through the pipeline, and the transcript renders live from the single
`session/event` stream — no side channels.
