# Terret

Ruby-native, model-agnostic agent harness where everything is a plugin. Three gems in one
repo:

- `gems/hames` is the kernel. Services in a context, typed events, reversible effects,
  dependency-driven boot. It knows nothing about LLMs and is reusable for any
  plugin-composed application.
- `gems/terret-core` is the harness built on it. Session log, tools pipeline, agent loop,
  LLM seam.
- `gems/terret` is a placeholder holding the name. It will carry the `trt` CLI, profiles,
  and boot. None of that is written. Do not add real behaviour here without reading §5
  and §9 of the plan first.

The full roadmap is `docs/terret-implementation-plan.md`; phases are in its §12. What is
here covers M0 and M1 in full, plus the subsystems of M2 that need no network. M2 is not
actually complete: it also calls for the Anthropic adapter and a working `trt run`, and
neither exists. The only adapter is `LLM::FakeAdapter`, which replays a canned script.

Note the plan has drifted from the code in places. It specifies RSpec (this uses minitest),
Ruby 3.4+ (this targets 4.0.6), and a separate `terret-llm` gem (the vocabulary lives in
terret-core). Treat the code as current and the plan as intent.

## Commands

```bash
rake test              # both suites, plain minitest, no bundler needed
rake events:catalog    # regenerates docs/events.md
ruby examples/headless_demo.rb
```

Ruby 4.0.6, pinned in `.ruby-version` and `mise.toml`. Zero runtime dependencies beyond
stdlib, and that is a design constraint rather than a coincidence. Think hard before adding
a gem to either gemspec.

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
