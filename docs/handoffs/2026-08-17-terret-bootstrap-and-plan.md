---
created: 2026-08-17T23:35:28Z
branch: main
trigger: manual
restored: false
topic: terret-bootstrap-and-plan
---

# Handoff: Terret bootstrap and implementation plan through v0.3

## Goal

Stand up a new public project from a code tarball (`terret-0.1.0-m2-slice.tar`), then revise its
implementation plan to match what Obie actually wants to build. The code itself was not touched
beyond packaging fixes. The substantive work was two rounds of plan revision that changed the
project's direction: one adapter instead of five, no CLI, and a WebSocket event stream instead of
Claude Code command-line compatibility.

## Current State

**Shipped and verified:**

- Repo live at https://github.com/terret-org/terret. Public, MIT, homepage `terret.org`.
- Four commits on `main`, working tree clean, pushed. CI green on every one.
- Ruby 4.0.6 pinned in `.ruby-version` and `mise.toml`; both library gemspecs require `>= 4.0`.
- All 28 tests pass (18 kernel, 10 loop). `rake events:catalog` reproduces `docs/events.md`
  byte-identically, and CI fails on drift.
- Three gems published to RubyGems under Obie Fernandez: `hames` 0.1.0, `terret-core` 0.1.0,
  `terret` 0.0.2.
- `terret.org` registered by Obie.
- `docs/terret-implementation-plan.md` at v0.3, revised twice this session.

**Not started:**

- The OpenRouter adapter. The only adapter in the tree is `LLM::FakeAdapter`, which replays a
  canned script. Nothing in the codebase does network I/O; the full dependency list is
  `securerandom`, `digest`, `json`, and minitest.
- Everything in §9 of the plan. There is no socket, no `terret-ws` gem.
- `gems/terret` is a placeholder whose only file is `lib/terret/cli.rb`, a stub that aborts.

**Blocked:**

- `zarpay/terret` (the original private repo, now superseded) is still not deleted. The `gh` token
  lacks the `delete_repo` scope. Obie needs to run
  `gh auth refresh -h github.com -s delete_repo`, then it can be removed. It currently carries an
  outdated copyright and is a confusing duplicate.

## Key Decisions

- **Public repo under a new `terret-org` GitHub org, not `zarpay`** — `github.com/terret` and
  `github.com/hames` are both taken by dormant personal accounts (1 and 0 public repos). Obie chose
  `terret-org` after discussion; `terret-rb` was the recommendation on `dry-rb`/`rom-rb` precedent.
- **Copyright is `Obie Fernandez` alone** — went through three forms this session (Terret
  contributors, then Obie Fernandez & Golden Age Dev Lab PTE. LTD, then just Obie). Each change was
  folded into the initial commit by amend so history never reads as a revision.
- **Licence file is `LICENSE.txt`, not `LICENSE`** — matches the house convention in
  `zarpay/amounts` and `zarpay/servus`.
- **Ruby 4.0.6, latest release** — Obie asked for latest, not just "Ruby 4". Verified all tests,
  the catalog, and the demo against it before pinning.
- **One OpenRouter adapter replaces five native per-provider adapters** — OpenRouter is
  OpenAI-compatible, so one implementation reaches the whole model space. Cost recorded in plan
  §6.5 and §14: prompt caching and interleaved thinking degrade to whatever OpenRouter normalises,
  and those are exactly the two claims §15 leans on.
- **No interactive CLI, ever, as a stated non-goal** — not a deferred milestone. `dry-cli` and the
  `tty-*` renderer left the dependency table with it.
- **No time estimates anywhere in the plan** — including the original "~17 weeks to a credible
  public 0.1" and the "budget 2–3 days" in the testing section.
- **WebSocket event stream instead of Claude Code `-p` compatibility** — Obie's call, overriding a
  recommendation to keep `-p` as a transitional proving path. Rationale: Terret is the harness, so
  serialising NDJSON over a pipe to reach it from Ruby is ceremony. One socket per agent, bound to
  that agent's forked context, shipped as the `terret-ws` plugin.
- **Durable sessions (M3) sequenced before the socket (M4)** — reconnect correctness is a property
  of the append-only log, not the transport. Building the socket first would mean discovering that
  against a SQLite store that does not exist yet.
- **Agent lifetime is independent of connection lifetime** — a dropped socket must never cancel a
  turn. Tying them would make every deploy an outage. Stated in plan §9.3 and the first thing to
  write a test for.
- **`terret-ws` is a gem alongside the others, not part of core** — if the primary interface cannot
  be a plugin, the "everything is a plugin" claim is decoration.
- **Gemspec file lists anchored with `Dir.chdir(__dir__)`** — see Failed Approaches.

## Modified Files

Working tree is clean; everything below is committed and pushed.

- `docs/terret-implementation-plan.md` — the main artefact, revised twice
- `docs/events.md` — from the tarball, generated, do not hand-edit
- `CLAUDE.md` — written this session
- `LICENSE.txt`, `Gemfile`, `.gitignore`, `.ruby-version`, `mise.toml`
- `.github/workflows/ci.yml` — runs both suites, then diffs the regenerated event catalog
- `gems/hames/hames.gemspec`, `gems/terret-core/terret-core.gemspec` — authorship, metadata, file glob
- `gems/terret/terret.gemspec`, `gems/terret/lib/terret/cli.rb` — new placeholder gem
- All `gems/*/lib/**/*.rb` — unchanged from the tarball

## Failed Approaches

- **`Dir["lib/**/*.rb"]` in the original gemspecs was silently broken.** The glob resolves against
  the current directory, not the gemspec's, so `Gem::Specification.load` from the repo root reported
  `files=0` on every gem. Building from anywhere but inside each gem directory would have published
  empty gems that install cleanly then fail at `require`. Fixed with `Dir.chdir(__dir__)`. Verified
  by unpacking the built `.gem` files rather than trusting the spec.
- **The `terret` gem cannot ship `lib/terret.rb`.** `terret-core` already provides that path, and
  two gems shipping the same file shadow each other on the load path. The placeholder ships only
  `lib/terret/cli.rb`.
- **`rubygems.org/api/v1/owners/obie` is not Obie.** It returns gems authored by someone else. The
  reliable source for his open-source identity was `git config user.email`, confirmed by him:
  `obiefernandez@gmail.com`.
- **`whois` for `.dev` falls through to IANA and returns nothing useful.** RDAP with redirect
  following (`curl -L https://rdap.org/domain/...`) is the reliable availability check; a bare
  `rdap.org` call returns 302 for some TLDs and reads as inconclusive.
- **I recommended keeping `-p` as a migration path. Obie overrode it.** Do not re-propose it; the
  plan now lists command-line compatibility as an explicit non-goal.
- **I raised a process-supervision concern about Ruby that was wrong.** It assumed a child process
  per run, which is a Claude-Code-shaped constraint. With the loop in-process there is nothing to
  supervise. Corrected in conversation, and the plan reflects the in-process model.

## Files to Read

- `docs/terret-implementation-plan.md` — start here. §9 (the socket), §12 (milestones and the
  reasoning for their order), §14 (risks) are where this session's thinking landed.
- `CLAUDE.md` — the three invariants worth protecting, and where the plan has drifted from the code.
- `gems/terret-core/lib/terret/sessions.rb` — the log, `derive_messages`, and
  `assert_log_invariant!`. `read(session_id, from_seq:)` is specified in the plan but **not yet
  implemented here**.
- `gems/terret-core/lib/terret/loop.rb` — the turn/step choreography and the `Agent` inbox.
- `gems/hames/lib/hames/context.rb` — `fork` at the bottom is the per-agent scope primitive the
  socket binds to.
- `examples/headless_demo.rb` — the only runnable thing; shows the whole stack against `FakeAdapter`.

Reference material in `../agentus`, read this session to ground the design:

- `agora/app/services/frenum/claude_code.rb` — how Agora dispatches today (HTTP to a runner)
- `runner/server.js` ~line 1160 and `runner/consciousnessd.js` ~line 420 — the actual `claude` spawn
- `runner/stream-input.js` — the stdin envelope and the turn-counting deadlock they hit

## Next Steps

1. **Build the OpenRouter adapter** over `async-http`, replacing `FakeAdapter` in the demo path.
   This finishes M2 and is the gate on everything else; nothing can be proven end to end until a
   real model is in the loop.
2. **Decide the compaction durable event.** A session measured in weeks outgrows any context
   window, and compacted history is still model-visible, so under the §2.5 invariant it must be
   logged as its own event rather than computed on the fly. This is an invariant decision, not a
   feature, so it belongs before M6 rather than in it.
3. **Write `docs/protocol.md`** capturing the §9 frame set and the reconnect contract precisely,
   then the socket protocol tests, both before any M4 implementation.
4. **Implement M3 durable sessions**: SQLite store, `read(from_seq:)`, load-and-replay resume,
   session fork.
5. **Write `docs/hames-primer.md`** — outstanding from the original plan; primer-first is one of
   dsh's better exports.
6. **Delete `zarpay/terret`** once the `delete_repo` scope is granted.
7. **Run the trademark search** (USPTO TESS and EUIPO), the last unchecked item from the original
   launch list.

## Open Questions

- **The plan does not yet state the "Terret is the runner" ambition.** Obie's direction late in the
  session was that Terret should make `runner.js` and `consciousnessd.js` unnecessary, becoming the
  runner in Agentus terms. §9's socket enables this, but §1 never claims it as a goal and no
  milestone mentions replacing the runner. If that is the real target, the plan should say so.
- **Replacing Agora was raised and I argued against it.** Agora is 56,674 lines across 69 models,
  versus 7,426 lines of runner. Scheduling, triggers, Mattermost threading, and missions are product
  domain logic that gains nothing from being plugins. Not settled with Obie either way.
- **Agora-side integration is entirely unscoped.** Nothing has been written about what changes in
  Agora to speak the socket instead of spawning a CLI.
- **Tool naming.** Whether the std tools carry Claude Code's names (`Read`, `Edit`, `Bash`) or ship
  an alias map. Blocks nothing until the execution world, but should settle before allow-list
  formats harden.
- **Should `hames` live in its own repo?** Open in the plan since v0.1.
- **How many agents per process, and when to shard.** §14 flags the blast radius of many agents on
  one reactor but sets no number.
