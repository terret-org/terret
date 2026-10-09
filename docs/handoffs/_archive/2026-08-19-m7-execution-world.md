---
created: 2026-08-19T02:09:13Z
branch: main
trigger: manual
restored: true
restored_at: 2026-08-19T02:14:29Z
topic: m7-execution-world
---

# Handoff: M7 Execution World — tasks 1–5 landed, review pending

## Goal
Ship M7 of the Terret harness (docs/terret-implementation-plan.md §12): the execution
world — `ctx[:fs]`, `ctx[:subprocess]`, `ctx[:shell]`, `ctx[:terminals]` seams; the std
tools under Claude Code names; sandbox `none` and `docker`; workspace scoping. Acceptance:
one patch row moves Bash/Read/Write/PTY into a container with zero tool changes. M0–M6 are
shipped and pushed; M6 (long-lived hardening) went out at `c6c127b`, CI green.

## Current State
- **M6: shipped and pushed** — `6f81801..c6c127b` on `main`, CI green. Both adversarial
  gates ran (opus whole-milestone review + Codex challenge); a 3-commit hardening batch
  fixed ~11 findings (append seq race, park verdict race, run_turn open-turn guard,
  ordered fan-out, resume-failure-leaves-turn-open, Morph tool-part render, token
  revocation, etc.). ~10 findings recorded in §14 as deliberate/M7+ deferrals.
- **M7 plan written**: `docs/superpowers/plans/2026-08-19-m7-execution-world.md` (16 tasks,
  self-reviewed). Untracked (plan files are never committed — house rule).
- **M7 tasks 1–5 committed locally, NOT pushed** (5 commits ahead of `origin/main`):
  - `31a7de1` Task 1 — primers `docs/exec.md` + `docs/security.md`
  - `6319a81` Task 2 — kernel: atomic `reconfigure!` (owner + rollback) + plugin-swap test
  - `4968d10` Task 3 — `Registry#register` gains `ctx:` (effect on caller, kills the
    M6 root-bleed) + `Definition.concurrency` metadata
  - `8a85e66` Task 4 — `terret-exec` gem + `ctx[:fs]` workspace-contained fs seam +
    `fs/authorize` waterfall (new gem #9; catalog regenerated)
  - `6d671f8` Task 5 — `ctx[:sandbox]` seam + `SandboxNone` provider
- **Task 4 security review REPORTED — found a P1 containment bypass (unfixed).**
  `fs.rb:94` (`authorize!`): a Hash return from the `fs/authorize` waterfall lets a
  listener REWRITE `:path`, and the rewrite is used WITHOUT re-running `contain()` —
  `next_.(call.merge(path: "/outside/secret"))` escapes the workspace (reviewer reproduced
  a real leak). Path-rewrite is undocumented, unspecified, untested; the reviewer (and I)
  recommend fix **(a): drop rewrite entirely** — waterfall listeners may only veto or pass
  through unchanged; collapses the surface, keeps all tests green. Alt (b): re-`contain()`
  `admitted[:path]` before trusting it. NOT pushed anywhere (local-only), so no live
  exposure. Everything else in the review passed: TOCTOU (2000-iter racer), symlink+
  traversal combos, case-folding, tilde, null-byte, absolute glob — all fail closed.
  The fix is TDD-able: the escape as a failing test first, then delete the rewrite branch
  at `fs.rb:94` (`admitted.is_a?(Terret::Tools::Veto) ? raise : resolved`), commit
  "Close the fs/authorize path-rewrite bypass", HEAD-guard `6d671f8`.
- All gates green through Task 5 (`rake test` + `bundle exec rake test`).

## Key Decisions
- **Approvals rescoped to opt-in (M6, user-confirmed)** — Terret's workload is autonomous,
  not interactive. Human-in-the-loop approvals stayed as an opt-in plugin row; the
  autonomous model is hot-reloadable deny-by-default policy-as-code. See memory
  `terret-m6-rescope`.
- **Std tools carry Claude Code names verbatim** (`Read`/`Write`/`Edit`/`Glob`/`Grep`/
  `Bash`/`WebFetch`, plus `terminal_*`) — orchestrator allow lists already speak them and
  `set_policy` ships them over the wire; the case-sensitive fnmatch AllowList has hardened.
  No alias map. Flagged to the user for cheap veto; not vetoed.
- **Docker execution world is a bind-mount** — workspace mounted at the same absolute path;
  fs syscalls run host-side against the mount (one world), processes run in-container via
  `docker exec`. What the container isolates is *execution*, which is the threat.
- **Bash approval derives from `sandbox.isolated?` at registration** (§13: `:always`
  unsandboxed, `:policy` inside); a hot sandbox swap re-registers.
- **Scrubber lives inside `Sessions#normalize_payload`** (append boundary), not as a
  read-time projection filter — both sides of the digest invariant see scrubbed bytes.
- **Compaction: interface with Morph, don't reinvent** — `ctx[:summarizer]` seam;
  `RoleSummarizer` default + `terret-morph` gem on agora's proven wire. User wants Morph
  ASAP; live lane pending `MORPH_API_KEY`.
- **Workspace containment is realpath-based, fails closed** — realpath the deepest existing
  prefix, prefix-match with a trailing-separator guard; workspace roots themselves are
  realpath'd (macOS /var→/private/var symlink bit us in Task 4).
- **At-least-once tool execution stands** — Write/Bash re-execute on crash-resume;
  idempotency is the tool's concern; harness idempotency keys are a recorded M7+ item.

## Modified Files
- Untracked (do NOT commit): `docs/superpowers/plans/2026-08-18-m6-long-lived-hardening.md`,
  `docs/superpowers/plans/2026-08-19-m7-execution-world.md`
- Everything else through Task 5 is committed; working tree otherwise clean.

## Failed Approaches
- Task 4 first pass expanded workspace roots with `File.expand_path` only, not realpath —
  every in-workspace op got Denied on macOS because `/var` is a symlink to `/private/var`.
  Fixed by realpath-ing roots at boot/reconfigure. Watch this in Task 12 (docker bind-mount
  must agree with fs *after* realpath, feed both the same pre-realpath config string).
- (M6) Two pre-existing tests collided with new invariants and had to get honest successor
  tests, not weakening: a WS listener-error test (emit isolation) and a poison-payload test
  that *hung* the suite (asserted invalid UTF-8 appends durably). Both recorded in the M6
  plan's fallout notes. Lesson carried: a hang in the suite is often a semantic collision,
  not infra.

## Files to Read
- `docs/superpowers/plans/2026-08-19-m7-execution-world.md` — the plan being executed
  (Design-decisions section + Context primer first, then tasks 6→16)
- `docs/exec.md`, `docs/security.md` — the M7 primers (normative contracts)
- `docs/terret-implementation-plan.md` §12 (M7 entry ~L465), §6.6/§6.7 (seams/std tools),
  §13 (security), §14 (paid + carry-forward debts)
- `gems/terret-exec/lib/terret/exec/fs.rb` — the containment algorithm the review is probing
- `gems/terret-core/lib/terret/tools.rb` — registry, `register(ctx:)`, AllowList, Definition
- `docs/handoffs/_archive/2026-08-17-terret-bootstrap-and-plan.md` — original bootstrap
- Memories: `terret-m6-rescope`, `terret-finishing-flow`, `subagent-driven-execution-always`,
  `codex-in-adversarial-reviews`, `minitest-version-assertion-counts`

## Next Steps
1. **Get `m7-task4-review-2`'s verdict.** If a P1 containment bypass: dispatch a fix
   implementer (TDD the escape as a failing test first, commit "Close the workspace
   containment bypass", HEAD-guard `6d671f8`), re-verify, before anything else.
2. **Resolve the glob return-shape question** (Task 4 flagged): fs `glob` returns ABSOLUTE
   paths; plan text said "workspace-relative". Decide before Task 8's `Glob` tool so the
   shape doesn't bite. The review was asked to weigh in.
3. **Task 6 — `ctx[:subprocess]`** (spawn/PTY/cancellation, SIGTERM→SIGKILL, every argv
   through `sandbox.wrap`). OPUS implementer. PTY fiber-cooperation is empirically verified.
4. Then the chain per plan: 7 shell/terminals (opus + reviewer), 8 file tools, 9 bash/
   terminal tools (+reviewer), 10 WebFetch, 11 redaction (opus + reviewer), 12 docker
   (opus + reviewer), 13 allow-list cache, 14 soak (opus), 15 acceptance (opus), 16 demo +
   ship (both adversarial gates, push, CI watch).
5. **Ship discipline** (memory `terret-finishing-flow`): direct push to `main` + `gh run
   watch`; no PR, no /ship; versions stay 0.1.0. README updated in the ship push
   (CLAUDE.md Shipping rule). Regenerate `docs/events.md` in any commit that declares an
   event.

## Open Questions
- **glob return shape** — absolute vs workspace-relative (see Next Step 2). Needs a call
  before Task 8.
- **Docker acceptance image** — plan says pick a CI-cached image and state it (Task 12
  suggests `ruby:slim`); confirm what CI Linux runners have cached.
- **`MORPH_API_KEY`** — not set in this environment, so terret-morph's live lane never ran
  (canned-wire-proven only). User may want to export it and prove the real wire.
- **gstack upgrade pending** (1.60→1.67), deferred; harmless.
- **Execution mode**: this session ran subagent-driven with the controller pacing via
  ScheduleWakeup and one committer at a time in the shared worktree. The user paused the
  autonomous goal for review after Task 5 — resume only on their go.
