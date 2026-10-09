# M7: The Execution World Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship M7 from `docs/terret-implementation-plan.md` §12: the execution world — `ctx[:fs]`, `ctx[:subprocess]`, `ctx[:shell]`, `ctx[:terminals]` seams; the std tools; sandbox `none` and `docker`; workspace scoping — accepted by **one patch row moving Bash, Read, Write, and PTY into a container with zero tool changes**.

**Architecture:** Three new gems. `terret-exec` (stdlib-only) carries the seam trio plus the sandbox seam: `ctx[:fs]` (workspace-contained file ops behind an `fs/authorize` waterfall), `ctx[:subprocess]` (spawn + PTY under the fiber scheduler, cooperative cancellation with SIGTERM→SIGKILL), `ctx[:shell]` (a persistent bash per agent, sentinel-protocol), `ctx[:terminals]` (named long-lived PTYs with a cap), and `ctx[:sandbox]` with the `None` provider — every argv passes through `sandbox.wrap` before spawn. `terret-tools-std` registers the tools on those seams with honest metadata. `terret-sandbox-docker` is one patch row: a long-lived container with the workspace bind-mounted at the same absolute path, argv wrapped into `docker exec`, `--network none` by default — fs and subprocess share one execution world (the mount), so everything moves together. Two kernel/core preludes make it safe: `Loader#reconfigure!` becomes atomic-with-owner (M6 debt), and `Registry#register` records its effect on the *caller's* context so per-agent tool registrations die with the agent (the M6-recorded bleed — a security fix now that tools carry filesystem authority). Redaction lands as §13 requires: a `tools/post_execute` redactor plus a log-append scrubber seam on `Sessions`, designed inside the invariant rather than against it.

**Tech Stack:** Ruby 4.0.6, plain minitest. `terret-exec` and `terret-tools-std` have zero runtime deps (pty/open3/net-http are stdlib; **empirically verified on this Ruby: PTY reads and `Process.wait` park the fiber, not the thread, under the async scheduler**). `terret-sandbox-docker` shells out to the docker CLI (no gem dep); its tests and the acceptance are docker-gated (Docker 29.4.0 verified locally; CI Linux runners carry it per plan §11). Grep prefers ripgrep when present with a pure-Ruby fallback.

---

## Design decisions already made (do not relitigate mid-task)

- **Std tools carry Claude Code's names verbatim**: `Read`, `Write`, `Edit`, `Glob`, `Grep`, `Bash`, `WebFetch`, plus `terminal_open/input/read/close` (no CC equivalent exists). Rationale (plan §6.7): orchestrator allow lists are written against CC's names, the AllowList format has already hardened (case-sensitive `File.fnmatch`), and `set_policy` ships these patterns over the wire today. No alias map. The `mcp__server__tool` convention stays for MCP; std tools are bare names.
- **`task`, `job_*`, and `todo` tools are M8** (they need `ctx[:jobs]` and the subagent seam). `fs.watch` is deferred until a consumer exists. `landlock`/`seatbelt` sandboxes are not in M7 (§12 names only none + docker).
- **The docker execution world is a bind-mount**: the container mounts each workspace dir at the same absolute path; fs ops run host-side against the mount (same bytes, same paths — one world), subprocess/PTY run inside via `docker exec`. Documented honestly in docs/exec.md: fs syscalls execute on the host; *processes* are what the container isolates, which is exactly the §13 threat (untrusted code execution), and path containment is enforced identically in both worlds.
- **Bash approval derives from the sandbox at registration** (§13: `:always` outside a sandbox, `:policy` inside): the Bash tool registers with `approval: ctx[:sandbox].isolated? ? :policy : :always`. Captured at registration; a hot sandbox swap re-registers (the std-tools service listens for it) — stated in docs.
- **`Definition` gains `concurrency:`** (`:serial` default). The loop keeps executing a message's calls sequentially in M7 — the field is declared metadata for M8's tool barrier, and docs say so plainly.
- **The SQLite per-session writer task stays deferred** (the store's own comment): durable-first ordering means a writer task cannot return before the write lands, so it buys serialization, not latency — and M7's soak lane (Task 14) is what tells us when it's needed. §14's line retargets to "when the soak shows it".
- **Scrubbing lives at the append boundary**: `Sessions#register_scrubber(callable)` (an effect, like prompt sections) runs over every String in every payload inside `normalize_payload` — both the projection and the outbound request derive from the scrubbed log, so the digest invariant holds by construction. The `tools/post_execute` redactor is the immediate layer; the scrubber is the backstop that also covers `user/message`/`context/injected`/plugin events. Patterns are config (regexp source strings); the `ctx[:credentials]` integration is M8 (§6.9).
- **Workspace containment is realpath-based**: every path expands, resolves symlinks on the deepest existing prefix, and must be inside a granted workspace dir — traversal (`..`, symlink escapes) fails closed with a `Tools::Failure`-class error the model can read.
- **At-least-once stands** (M6 contract): `Write`/`Bash` re-execute on resume by design; docs/exec.md restates it where the destructive tools are introduced. Harness idempotency keys remain the recorded M7+ §14 item — not built here.

## Context primer (read before any task)

- Repo: eight gems under `gems/`; this plan adds `terret-exec`, `terret-tools-std`, `terret-sandbox-docker` (eleven total). Run everything through `mise exec --`. Full gates: `mise exec -- rake test` AND `mise exec -- bundle exec rake test`. `Gemfile.lock` is gitignored — never commit it. Docker-gated tests skip cleanly when `docker info` fails.
- House rules: `# frozen_string_literal: true`; `Data.define` for values; strict TDD with failing-first evidence reported verbatim; commit subjects are plain evocative sentences (no prefixes, no AI attribution, no trailers); one implementer commits at a time; `git log -1` HEAD-guard before every commit; NEVER stage `docs/superpowers/plans/*`; foreground gates one at a time, never two rake runs concurrently; kill hung test processes (`pkill -f "rake test"`, verify with pgrep).
- **Empirical facts (verified on this checkout at `c6c127b`):**
  - Under `Async`, `PTY.spawn`'s IO reads and `Process.wait` park only the calling fiber (probe: ticker fibers kept ticking through a blocking `gets`). `Thread::Queue#pop` is likewise fiber-cooperative (M6's parking primitive). Docker 29.4.0 runs linux containers locally; `uname` inside is `Linux`, host is `Darwin` — the acceptance discriminator.
  - `Hames::Loader#layer` (gems/hames/lib/hames/loader.rb:63-91): a later row with an existing id replaces the row wholesale — **including the plugin class** (`plugin: h[:plugin] || existing.plugin`). That line is the entire acceptance mechanism and is currently UNTESTED for class swap (Task 2 covers it). `Hames::Service` lives in loader.rb, not a service.rb.
  - `Registry` (gems/terret-core/lib/terret/tools.rb): `Definition = Data.define(:name, :description, :params, :handler, :mutating, :approval)`; `register(name:, description:, params: {}, mutating: false, approval: :never, &handler)` records via `@ctx.effect` where `@ctx` is the ROOT — the M6-recorded bleed Task 3 fixes. `execute(call, ctx:)` runs pre_execute (Veto → error Result) → execute (base block calls the handler; the approvals gate is execute-stage middleware) → post_execute. Waterfalls dispatch on the caller's ctx, parent-first.
  - `AllowList` v2: active patterns = last durable `policy/updated` in the call's session, else the install floor; `File.fnmatch`, case-sensitive, fails closed on unknown sessions. `Sessions#append` serializes per session (fiber-aware Mutex) and fans out in seq order via an emit queue — a listener's own append returns before that event fans out.
  - `Sessions#normalize_payload` admits primitives only, refuses invalid UTF-8, symbol values become strings. `assert_log_invariant!` digests the projection against every outbound request — anything that rewrites model-visible bytes must do it at the append boundary or the invariant trips.
  - Approvals: execute-stage gate; `requires_approval?` is `always || (policy && mutating)`; correlation is turn-scoped and args-bound. `resume_turn` re-executes owed calls (at-least-once); `run_turn` raises `TurnOpenInLog` on an open turn.
  - Test harness conventions: per-file `boot(script:, extra_rows:)` modules (Memory store, `roles: {main: "fake/scripted"}`, `FakeAdapter` scripts consumed strictly in order); terret-ws has `FakeSocket`/`connect`/`await`. Copy the conventions of the file you touch; never invent a parallel harness. Gem scaffolds copy `gems/terret-morph` (the smallest recent gem: gemspec, entry file with monorepo fallback require, Gemfile path row).
  - Events: any new declaration in `Terret.declare_events!` requires `mise exec -- rake events:catalog` and committing `docs/events.md` in the SAME commit (CI diffs it).
- **Do not relax invariants**: model-visible means logged; deny-by-default fails closed; registration is reversible through effects; durable-first append ordering; one reactor, no user-facing threads — a blocking read that doesn't park the fiber stalls every agent in the process.

## File map

| File | Status | Responsibility |
|---|---|---|
| `docs/exec.md` | create | the execution-world primer (seams, naming, workspace, sandbox, at-least-once) |
| `docs/security.md` | create | the §13 threat model, finally written down |
| `gems/hames/lib/hames/loader.rb` | modify | atomic `reconfigure!` (owner + rollback); plugin-swap test coverage |
| `gems/hames/test/hames_test.rb` | modify | patch-row plugin-class swap test; reconfigure atomicity tests |
| `gems/terret-core/lib/terret/tools.rb` | modify | `register(..., ctx:)` effect-on-caller; `Definition.concurrency`; AllowList pattern cache |
| `gems/terret-core/lib/terret/sessions.rb` | modify | `register_scrubber` seam inside `normalize_payload` |
| `gems/terret-core/lib/terret/redactor.rb` | create | `ctx[:redactor]`: post_execute redaction + scrubber registration |
| `gems/terret-core/lib/terret.rb` | modify | declare `fs/authorize`; require redactor |
| `gems/terret-core/test/*` | modify | tests for all of the above |
| `gems/terret-exec/*` | create | fs/subprocess/shell/terminals seams + Sandbox::None |
| `gems/terret-tools-std/*` | create | Read/Write/Edit/Glob/Grep/Bash/WebFetch/terminal_* tools |
| `gems/terret-sandbox-docker/*` | create | the container provider (one patch row) |
| `gems/terret-ws/test/*` or `gems/terret-exec/test/*` | create | the soak lane |
| `Gemfile`, `docs/events.md`, `docs/protocol.md` | modify | path rows; catalog; any wire notes |
| `examples/exec_demo.rb` | create | local-vs-docker walk-through |
| `CLAUDE.md`, `README.md`, `docs/terret-implementation-plan.md` | modify | M7 shipped (final task) |

---
### Task 1: The primers — `docs/exec.md` and `docs/security.md` before any code

Primer-first, house style. Two documents.

**Files:** Create `docs/exec.md`, `docs/security.md`.

- [ ] **Step 1: Write docs/exec.md** in the repo's documentation voice, covering in order:

1. **One execution world** (§2.6/§6.6 thesis): fs and subprocess share a world, so swapping the sandbox row moves Read/Write/Edit/Bash/PTY together with zero tool changes. State the bind-mount design plainly: the docker provider mounts each workspace dir at the same absolute path inside the container; fs syscalls run host-side against the mount (same bytes), processes run inside; what the container isolates is *execution*, which is the threat.
2. **The seams**: `ctx[:fs]` (read/write/edit/stat/glob, every path realpath-contained to the workspace list, every op passing the `fs/authorize` waterfall — a Veto renders as a tool error); `ctx[:subprocess]` (spawn with timeout + cooperative cancellation escalating SIGTERM→SIGKILL, `pty_spawn`; **every argv passes `ctx[:sandbox].wrap(argv, cwd:)` before spawn**); `ctx[:shell]` (one persistent bash per agent, sentinel protocol, cwd/env persist across calls); `ctx[:terminals]` (named long-lived PTYs, `max_terminals` cap, closed on agent disposal).
3. **Workspace scoping**: the `workspace:` config row (list of dirs) consumed by the fs provider and bind-mounted by docker; containment semantics (expand, realpath the deepest existing prefix, prefix-match against granted dirs; traversal and symlink escapes fail closed).
4. **The sandbox seam**: `wrap(argv, cwd:)` + `isolated?`; `None` (identity, opt-in trusted), `Docker` (long-lived container, `--network none` default, image/network/mounts config). One patch row swaps worlds — show the §7-style row.
5. **The std tools and their names**: the Claude Code names decision and why (allow lists already speak them; `set_policy` ships them); the v1 roster with each tool's `mutating`/`approval`/`concurrency` metadata in a table; Bash approval derived from `sandbox.isolated?` at registration (re-registered on a sandbox swap).
6. **Redaction**: the two layers (post_execute redactor; append-boundary scrubber), why the scrubber lives inside `normalize_payload` (both sides of the digest see scrubbed bytes — the invariant holds by construction), and the honest limits (patterns are config until `ctx[:credentials]` lands in M8).
7. **Destructive tools and at-least-once**: restate the M6 resume contract where it now bites (`Write`, `Bash` re-execute after a crash; idempotency is the tool's concern).
8. **Concurrency**: one reactor; PTY/spawn verified fiber-cooperative; `concurrency:` metadata declared now, honored by the M8 tool barrier; MAX_STEPS applies to tool-heavy turns.

- [ ] **Step 2: Write docs/security.md** — the §13 posture as a real document: the threat model (tool results are data; the model is the only interpreter; approval/policy seams are the backstops), sandbox defaults (`docker`+`network: none` for untrusted work; `none` is explicit opt-in), approval defaults (`:policy` mutating fs, `:always` bash unsandboxed, `:policy` inside), workspace containment, redaction layers, the socket's authority model (bearer token = the agent's full authority incl. `set_policy` — the §14-recorded stance), multi-tenancy (fork isolation is for common ownership; mutually untrusted work needs the process boundary + sandbox), at-least-once and idempotency. Cross-link docs/exec.md, docs/lifecycle.md, docs/protocol.md.

- [ ] **Step 3: Cross-check** every named API against this plan's tasks; fix the primer, not the plan. Commit:

```bash
git add docs/exec.md docs/security.md
git commit -m "Write the execution-world and security primers before the code"
```

---

### Task 2: Kernel — atomic reconfigure and the plugin-swap proof

Two M6-recorded items, one commit. (a) `Loader#reconfigure!` commits the row before the hook can raise, and hooks run ownerless. (b) The patch-row **plugin-class swap** — the single line M7's acceptance stands on — has no test.

**Files:** Modify `gems/hames/lib/hames/loader.rb`; test `gems/hames/test/hames_test.rb`.

- [ ] **Step 1: Failing tests** (adapt to the file's conventions; `capture_warn` exists from M6):

```ruby
class HamesPatchSwapTest < Minitest::Test
  class ProviderA < Hames::Service
    service_key :greeter
    def start(_ctx); end
    def greet = "A:#{config[:tone]}"
  end

  class ProviderB < Hames::Service
    service_key :greeter
    def start(_ctx); end
    def greet = "B:#{config[:tone]}"
  end

  def setup = Hames.reset_events!

  def test_a_patch_row_swaps_the_plugin_class_wholesale
    loader = Hames::Loader.new
    loader.layer([{ id: "greeter", plugin: ProviderA, config: { tone: "warm" } }])
    loader.layer([{ id: "greeter", plugin: ProviderB, config: { tone: "cold" } }])
    ctx = loader.boot!
    assert_equal "B:cold", ctx[:greeter].greet, "the later layer's plugin class must win"
  end

  def test_a_patch_row_without_a_plugin_keeps_the_class_and_replaces_config
    loader = Hames::Loader.new
    loader.layer([{ id: "greeter", plugin: ProviderA, config: { tone: "warm", extra: 1 } }])
    loader.layer([{ id: "greeter", config: { tone: "cold" } }])
    ctx = loader.boot!
    assert_equal "A:cold", ctx[:greeter].greet
    assert_equal({ tone: "cold" }, ctx[:greeter].config, "wholesale, not merged")
  end
end

class HamesReconfigureAtomicityTest < Minitest::Test
  class Fragile < Hames::Service
    service_key :fragile
    attr_reader :knob
    def start(_ctx) = @knob = config[:knob]

    def reconfigure(config)
      raise "hook exploded" if config[:explode]

      @knob = config[:knob]
    end
  end

  def setup = Hames.reset_events!

  def test_a_raising_hook_rolls_the_row_and_config_back
    loader = Hames::Loader.new
    loader.layer([{ id: "fragile", plugin: Fragile, config: { knob: 1 } }])
    ctx = loader.boot!
    assert_raises(RuntimeError) { loader.reconfigure!("fragile", { knob: 2, explode: true }) }
    assert_equal({ knob: 1 }, ctx[:fragile].config, "config must roll back when the hook raises")
    assert_equal 1, ctx[:fragile].knob
    loader.reconfigure!("fragile", { knob: 3 }) # and the row still works afterward
    assert_equal 3, ctx[:fragile].knob
  end

  def test_hook_registrations_are_owned_by_the_row
    loader = Hames::Loader.new
    loader.layer([{ id: "fragile", plugin: Fragile, config: { knob: 1 } }])
    ctx = loader.boot!
    # a hook that registers an effect: its disposer must be owned by the row id
    owner_seen = nil
    ctx.define_singleton_method(:effect_owner_probe) { @owner }
    ctx[:fragile].define_singleton_method(:reconfigure) do |_config|
      owner_seen = ctx.effect_owner_probe
    end
    loader.reconfigure!("fragile", { knob: 9 })
    assert_equal "fragile", owner_seen, "reconfigure hooks must run under with_owner(id)"
  end
end
```

(The owner probe reads the context's `@owner` — if the file has a cleaner established way to observe ownership, use it; the assertion is what matters.)

- [ ] **Step 2: Run, verify failure modes** (`plugin swap` may pass already — if it does, KEEP the test, it's the acceptance's insurance; atomicity tests fail: config not rolled back, owner nil).

- [ ] **Step 3: Implement** — in `reconfigure!`: snapshot the old row + old service config; wrap the hook in `@ctx.with_owner(id) { service.reconfigure(config) }`; on any raise, restore the row and `service.replace_config!(old_config)`, then re-raise; emit `config/updated` only on success. Keep the wholesale-replace semantics.

- [ ] **Step 4: Gates, commit**

```bash
git add gems/hames/lib/hames/loader.rb gems/hames/test/hames_test.rb
git commit -m "Make reconfigure atomic and prove the plugin swap"
```

---

### Task 3: Core — effects on the caller and honest concurrency metadata

(a) `Registry#register` records its effect on the ROOT ctx, so an agent-registered tool survives `dispose_agent` and bleeds authority — a security fix now that tools carry filesystem access. `register` gains `ctx:` (default: the registry's root, preserving every existing call site) and records the effect there. (b) `Definition` gains `concurrency:` (`:serial` default) — declared metadata for M8's barrier; the loop stays sequential and the schema hash is unchanged.

**Files:** Modify `gems/terret-core/lib/terret/tools.rb`; test `gems/terret-core/test/loop_test.rb`.

- [ ] **Step 1: Failing tests**

```ruby
class RegistryScopeTest < Minitest::Test
  include TerretTestHarness

  def test_an_agent_registered_tool_dies_with_the_agent
    ctx, = boot(script: [])
    s = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: s.id)
    agent.ctx.with_owner("agent-tools") do
      ctx[:tools].register(name: "mine", description: "scoped", params: {},
                           ctx: agent.ctx) { "ok" }
    end
    assert ctx[:tools].schemas.any? { |sc| sc[:name] == "mine" }

    ctx[:loop].dispose_agent(agent.id)
    refute ctx[:tools].schemas.any? { |sc| sc[:name] == "mine" },
           "a tool registered through a fork must not survive the fork's disposal"
  end

  def test_definitions_carry_concurrency_metadata
    ctx, = boot(script: [])
    ctx.with_owner("t") do
      ctx[:tools].register(name: "solo", description: "d", params: {},
                           concurrency: :serial) { "x" }
    end
    assert_equal :serial, ctx[:tools].fetch("solo").concurrency
  end
end
```

- [ ] **Step 2: Implement** — `Definition = Data.define(:name, :description, :params, :handler, :mutating, :approval, :concurrency)`; `schema` unchanged. `register(name:, description:, params: {}, mutating: false, approval: :never, concurrency: :serial, ctx: @ctx, &handler)` — build the Definition, then `ctx.effect { @defs[d.name] = d; -> { @defs.delete(d.name) } }`. Comment: the roster is global (visibility is policy's job via AllowList); *ownership* follows the registering context so disposal reaps it — the M6 §14 bleed, paid.

- [ ] **Step 3: Sweep** — `Definition.new` call sites (terret-mcp's translate builds Definitions via register? check; anything constructing Definition positionally needs the new field). Full gates.

- [ ] **Step 4: Commit**

```bash
git add gems/terret-core/lib/terret/tools.rb gems/terret-core/test/loop_test.rb
git commit -m "Scope tool registration to its caller"
```

---

### Task 4: `terret-exec` — the gem, `ctx[:fs]`, and workspace containment

Scaffold the gem (copy terret-morph's shape; zero runtime deps; Gemfile path row). `ctx[:fs]`: read/write/edit/stat/glob, every path contained to the `workspace:` list, every op through a new `fs/authorize` waterfall (declared in terret-core's vocabulary since events are app-global; catalog regen rides this commit).

**Files:** Create `gems/terret-exec/terret-exec.gemspec`, `gems/terret-exec/lib/terret/exec.rb`, `gems/terret-exec/lib/terret/exec/fs.rb`, `gems/terret-exec/test/fs_test.rb`. Modify `gems/terret-core/lib/terret.rb` (declare `fs/authorize`), `Gemfile`, `docs/events.md`.

- [ ] **Step 1: Failing tests** (`gems/terret-exec/test/fs_test.rb`) — boot a loader with just the fs row (`config: { workspace: [dir] }` on a mktmpdir), plus sessions-free harness (fs has no core deps beyond hames + the event declaration; require terret-core's terret.rb for `declare_events!`):

Cover: read/write round-trip inside the workspace; `edit` replaces a unique string and raises `Terret::Exec::EditAmbiguous` (a `Tools::Failure` subclass) when the target appears 0 or 2+ times; `stat` returns `{size:, mtime:, directory:}` primitives; `glob` returns absolute paths (decided post-review: absolute round-trips into read/edit unambiguously under multi-root workspaces, and matches CC's Glob) and never escapes; **containment**: absolute path outside the workspace → `Terret::Exec::Denied` (a `Tools::Failure` subclass); `../` traversal → Denied; a symlink inside the workspace pointing outside → Denied (create one in the test); a path in a second granted workspace dir → allowed; an `fs/authorize` listener returning a `Tools::Veto` → the op raises Denied with the veto reason; unknown workspace (empty list) → everything Denied.

- [ ] **Step 2: Implement** `Terret::Exec::FS < Hames::Service` (`service_key :fs`):

```ruby
    def start(ctx)
      @ctx = ctx
      @workspace = Array(config[:workspace]).map { |d| File.expand_path(d) }
    end

    def reconfigure(config)
      @workspace = Array(config[:workspace]).map { |d| File.expand_path(d) }
    end

    def read(path)   = File.read(authorize!(:read, path))
    def write(path, content)
      p = authorize!(:write, path)
      FileUtils.mkdir_p(File.dirname(p))
      File.write(p, content)
      p
    end
    def edit(path, old, new)
      p = authorize!(:write, path)
      body = File.read(p)
      count = body.scan(old).length  # careful: scan with a string, not regexp
      raise EditAmbiguous, "#{old.inspect} appears #{count} times in #{path}; must be exactly 1" unless count == 1
      File.write(p, body.sub(old, new))
      p
    end
    def stat(path)
      p = authorize!(:read, path)
      s = File.stat(p)
      { size: s.size, mtime: s.mtime.utc.iso8601, directory: s.directory? }
    end
    def glob(pattern)
      @workspace.flat_map { |root| Dir.glob(File.join(root, pattern)) }
                .select { |p| contained?(p) }
    end
```

`authorize!` expands, resolves the deepest existing prefix via `File.realpath`, checks containment (prefix match against `@workspace` with a trailing-separator guard so `/ws-evil` never matches `/ws`), then dispatches `@ctx.waterfall("fs/authorize", { op:, path: })` — a `Tools::Veto` return raises `Denied.new(veto.reason)`. `Denied < Tools::Failure`, `EditAmbiguous < Tools::Failure`. Declare `e.("fs/authorize", :waterfall, doc: "veto or admit an fs operation")` in terret.rb; regen the catalog.

- [ ] **Step 3: Gates** (new suite rides the glob), catalog diff clean, commit:

```bash
git commit -m "Give agents a workspace-scoped filesystem seam"
```

---

### Task 5: `terret-exec` — `ctx[:sandbox]` and the `None` provider

The seam every argv passes through before spawn. Small by design.

**Files:** Create `gems/terret-exec/lib/terret/exec/sandbox_none.rb`, test in `gems/terret-exec/test/sandbox_test.rb`.

- [ ] **Steps**: TDD `Terret::Exec::SandboxNone < Hames::Service` (`service_key :sandbox`): `wrap(argv, cwd:)` returns `argv` untouched; `isolated?` is `false`; `workspace_ready!` is a no-op (docker overrides it to ensure the container). Tests: identity wrap, isolated? false. Comment: `none` is the explicit-opt-in trusted provider (§13); the docker row replaces this plugin wholesale. Commit:

```bash
git commit -m "Seam the sandbox in front of every spawn"
```

---

### Task 6: `terret-exec` — `ctx[:subprocess]`: spawn, PTY, cancellation

**Files:** Create `gems/terret-exec/lib/terret/exec/subprocess.rb`, `gems/terret-exec/test/subprocess_test.rb`.

- [ ] **Step 1: Failing tests.** Cover: `spawn(argv, cwd:, env:, stdin:, timeout:)` → `Result = Data.define(:status, :stdout, :stderr)` for a happy echo; non-zero exit captured, not raised; `timeout:` expiring → the process is SIGTERMed (assert the child is gone) and the result carries `status: nil, stderr: /timed out/` shape — pick one honest shape and test it; a stubborn child ignoring TERM (ruby -e trapping TERM + sleeping) gets SIGKILL after the grace (short grace in tests); argv passes through `ctx[:sandbox].wrap` (boot with a probe sandbox that records + prefixes argv with `env` — assert the wrap was applied); `pty_spawn(argv)` → a handle with `read(max)`, `write(str)`, `pid`, `close` (which reaps) — round-trip a line; everything cooperates under `Sync` (a ticker fiber keeps ticking during a slow child — the probe pattern from the plan's primer).

- [ ] **Step 2: Implement** `Terret::Exec::Subprocess < Hames::Service` (`service_key :subprocess`, `inject :sandbox`): `spawn` uses `Open3.capture3`-equivalent built on `Process.spawn` with pipes (stdlib; do not use Open3.capture3 directly if it fights the scheduler — verify empirically and note what you found), timeout via a deadline loop with `Process.wait(pid, Process::WNOHANG)` + `sleep 0.01` (parks the fiber) then TERM → grace (`config[:term_grace] || 2`) → KILL; `pty_spawn` wraps `PTY.spawn` with the wrapped argv, returning a small handle object. Every argv: `argv = @ctx[:sandbox].wrap(argv, cwd: cwd)` first — one comment stating this is the §6.6 contract.

- [ ] **Step 3: Gates + commit**

```bash
git commit -m "Spawn processes and terminals under the reactor"
```

---

### Task 7: `terret-exec` — `ctx[:shell]` and `ctx[:terminals]`

**Files:** Create `gems/terret-exec/lib/terret/exec/shell.rb`, `.../terminals.rb`, tests.

- [ ] **Step 1: Failing tests.** Shell: `run("echo hi")` → `{stdout: "hi\n", status: 0}` shape; **state persists** (`run("cd /tmp && export FOO=bar")` then `run("echo $FOO $(pwd)")` sees both); a failing command's status captured; `timeout:` kills the in-flight command but the SESSION survives for the next run (document if instead the session restarts — pick the honest simple one: on timeout, kill and respawn the bash, stating so in the result); sessions are per-key (`shell.run(cmd, session: agent_id)`). Terminals: `open(name, argv)` → handle registered; `input(name, text)` + `read(name)` round-trip; `close(name)` reaps; opening past `max_terminals` (config, default 8) raises a `Tools::Failure`; `close_all_for(key)` exists (agent disposal hook—wired when the tools land).

- [ ] **Step 2: Implement.** Shell on subprocess's pty_spawn (a bash driven by sentinel: write `cmd; printf '\n<SENTINEL>%s\n' $?`, read until sentinel, parse status; sentinel is a random hex per session). Terminals: a keyed registry of pty handles with the cap, `close` idempotent. Both `service_key`ed (`:shell`, `:terminals`), `inject :subprocess`.

- [ ] **Step 3: Gates + commit**

```bash
git commit -m "Keep a shell and terminals alive per agent"
```

---
### Task 8: `terret-tools-std` — the file tools (`Read`, `Write`, `Edit`, `Glob`, `Grep`)

Scaffold the gem (terret-morph shape, zero deps, Gemfile row). One service registers the roster on the seams with honest metadata. **Claude Code names, exactly** (the recorded decision).

**Files:** Create `gems/terret-tools-std/terret-tools-std.gemspec`, `lib/terret/tools_std.rb`, `lib/terret/tools_std/files.rb`, `test/files_test.rb`.

- [ ] **Step 1: Failing tests.** Boot fs (workspace on a mktmpdir) + tools + the std files service; drive through `ctx[:tools].execute` (the pipeline, not the handlers directly — policy must see these calls). Cover: `Read` returns content and its Definition is `mutating: false, approval: :never`; `Read` on a path outside the workspace → error Result carrying the Denied message (Failure renders message-only); `Write` creates (metadata `mutating: true, approval: :policy` — under the approvals row that means it parks; test WITHOUT the approvals row here, metadata asserted from `fetch`); `Edit` uniqueness both ways; `Glob` and `Grep` return absolute-path listings (the recorded glob-shape decision: absolute, matching CC's Glob and the fs seam); `Grep` works with ripgrep absent (force the fallback via config `rg: false`) and present (skip-guard if `rg` missing); every Definition's name is the exact CC token (`Read`, not `read_file`) — assert the roster.

- [ ] **Step 2: Implement** `Terret::ToolsStd::Files < Hames::Service` (`service_key :tools_std_files`, `inject :tools, :fs`): `start` registers the five via `ctx[:tools].register(..., ctx: <the start ctx>)` with handlers delegating to `ctx[:fs]`; Grep: if `config.fetch(:rg, true)` and `rg` on PATH → spawn it through `ctx[:subprocess]`? No — Grep must not require subprocess (files-only task); implement rg via `ctx[:subprocess]` ONLY when that service is present (`ctx.service?(:subprocess)`), else pure-Ruby scan (File.foreach with a Regexp, workspace-globbed). Metadata table (also mirrored in docs/exec.md): Read/Glob/Grep `mutating: false, approval: :never`; Write/Edit `mutating: true, approval: :policy`; all `concurrency: :serial` except Read/Glob/Grep `:parallel` (declared for M8).

- [ ] **Step 3: Gates + commit**

```bash
git commit -m "Ship the standard file tools under policy"
```

---

### Task 9: `terret-tools-std` — `Bash` and the terminal tools

**Files:** Create `lib/terret/tools_std/bash.rb`, `lib/terret/tools_std/terminals.rb`, tests.

- [ ] **Step 1: Failing tests.** `Bash` executes through `ctx[:shell]` (state persists across two calls in one session — cwd carries); its Definition's `approval` is `:always` when `ctx[:sandbox].isolated?` is false and `:policy` when true (boot once with SandboxNone, once with a stub sandbox returning isolated? true, assert both) — and a `config/updated` swap of the sandbox row re-registers Bash with the new approval (listener test). `terminal_open/input/read/close` drive `ctx[:terminals]` end to end (open a `cat` PTY, write, read back, close); terminal tools are `mutating: true, approval: :policy`. Bash output truncation: results longer than `config[:max_output] || 30_000` bytes truncate with a marker line (post_execute is policy's seam; this is the tool's own honest cap).

- [ ] **Step 2: Implement** `Terret::ToolsStd::Bash` (`inject :tools, :shell, :sandbox`) and `Terret::ToolsStd::Terminals` (`inject :tools, :terminals`). Bash registration: `approval: @ctx[:sandbox].isolated? ? :policy : :always` (§13), with a `config/updated` listener that, when the sandbox row changes, disposes and re-registers (keep the returned disposer; the comment names the registration-time capture honestly). Session key = the call's session_id (each agent gets its own shell state).

- [ ] **Step 3: Gates + commit**

```bash
git commit -m "Put bash and terminals behind the sandbox-aware gate"
```

---

### Task 10: `terret-tools-std` — `WebFetch` with a domain policy row

**Files:** Create `lib/terret/tools_std/web_fetch.rb`, `test/web_fetch_test.rb`.

- [ ] **Step 1: Failing tests.** Injectable transport (terret-morph's pattern — `->(url) { [status, body] }`): fetch returns body text (truncated at `max_bytes`, default 100_000, marker appended); **domain policy**: config `{allow: [globs], deny: [globs]}` — deny wins over allow; empty allow list means deny-by-default (assert a fetch against an unlisted domain returns a Failure-rendered error result, nothing fetched — the transport must not be called); redirects followed to a cap of 5 and each hop re-checked against policy (a transport stub returning a 301 to a denied domain → refused mid-chain); non-http(s) schemes refused. Metadata: `mutating: false, approval: :policy`.

- [ ] **Step 2: Implement** with stdlib net/http as the default transport (timeouts floored like terret-morph's), `File.fnmatch` on the host for the allow/deny globs (consistent with the AllowList's semantics, case-sensitive, fail closed). §13's "web_fetch gets an allow and deny domain policy row" — the row is this service's own config.

- [ ] **Step 3: Gates + commit**

```bash
git commit -m "Fetch the web behind a domain policy"
```

---

### Task 11: Core — redaction at both layers

§13: "Credentials never enter the session log, enforced by redaction in `tools/post_execute` plus a log-append scrubber." The scrubber must live INSIDE the append boundary or the digest invariant trips — that is the trap this task is designed around.

**Files:** Modify `gems/terret-core/lib/terret/sessions.rb` (`register_scrubber`), create `gems/terret-core/lib/terret/redactor.rb`, modify `gems/terret-core/lib/terret.rb` (require), tests in `gems/terret-core/test/sessions_test.rb` + a new `redactor_test.rb`.

- [ ] **Step 1: Failing tests.**

Sessions layer:

```ruby
  def test_registered_scrubbers_rewrite_every_string_at_the_append_boundary
    ctx = sessions_ctx
    s = ctx[:sessions].create
    ctx.with_owner("scrub") do
      ctx[:sessions].register_scrubber(->(str) { str.gsub("sk-secret123", "[REDACTED]") })
    end
    ev = ctx[:sessions].append(s.id, "user/message", { text: "key is sk-secret123 ok" })
    assert_equal "key is sk-secret123 ok".gsub("sk-secret123", "[REDACTED]"), ev.payload[:text]
    # the projection sees the same bytes — the invariant holds by construction
    assert_equal "key is [REDACTED] ok",
                 ctx[:sessions].derive_messages(s.id).first.text
  end

  def test_scrubber_registration_is_a_reversible_effect
    ctx = sessions_ctx
    s = ctx[:sessions].create
    disposer = nil
    ctx.with_owner("scrub") do
      disposer = ctx[:sessions].register_scrubber(->(t) { t.gsub("x", "y") })
    end
    disposer.call
    ev = ctx[:sessions].append(s.id, "user/message", { text: "xx" })
    assert_equal "xx", ev.payload[:text]
  end
```

Redactor layer (redactor_test.rb, full harness with loop + tools): boot with `{ id: "redactor", plugin: Terret::Redactor, config: { patterns: ["sk-[a-z0-9]+"] } }`; a tool whose handler returns a secret → the durable `tool/result` payload carries `[REDACTED]` (post_execute rewrote the Result) AND a `user/message` containing the secret is scrubbed too (the append backstop); the turn completes with the invariant asserted (implicit); a non-String content (nil, number) passes through untouched.

- [ ] **Step 2: Implement.**

Sessions: `@scrubbers = []` in start; `register_scrubber(callable)` records via `@ctx.effect` (returns the disposer); inside `normalize_payload`'s String arm, after the UTF-8 validation, fold the string through `@scrubbers` (a comment: scrubbing here means both the stored log and every projection derived from it — including the digest's two sides — see identical bytes; §13's log boundary).

Redactor (`Terret::Redactor < Hames::Service`, `service_key :redactor`, `inject :sessions`): `start` compiles `config[:patterns]` (Regexp sources; `reconfigure` recompiles), registers a `tools/post_execute` waterfall listener rewriting `Result.content` when it's a String (`result.with(content: redact(result.content))`), and registers the same `redact` as a Sessions scrubber. Replacement token `config[:replacement] || "[REDACTED]"`.

- [ ] **Step 3: Gates + commit** (no new event; no catalog change):

```bash
git commit -m "Redact secrets at the pipeline and the log boundary"
```

---
### Task 12: `terret-sandbox-docker` — the one patch row

The container provider. A long-lived container per boot (image from config, default `ruby:slim` for tests — pick something CI-cached and state it), each workspace dir bind-mounted at the same absolute path, `--network none` unless config overrides, argv wrapped into `docker exec`. Shells out to the docker CLI via `ctx[:subprocess]`'s own spawn? No — bootstrap problem (subprocess wraps through sandbox). The provider spawns docker with plain `Process.spawn` internally and documents why (the sandbox is beneath the seam it serves).

**Files:** Create `gems/terret-sandbox-docker/terret-sandbox-docker.gemspec`, `lib/terret/sandbox/docker.rb`, `test/docker_test.rb`. Modify `Gemfile`.

- [ ] **Step 1: Failing tests** (every test opens with the gate: `skip "docker unavailable" unless system("docker info >/dev/null 2>&1")`). Cover: `isolated?` true; `wrap(["uname"], cwd: ws)` produces a `docker exec` argv carrying `-w <cwd>` and the container id; the container starts lazily on first wrap (`workspace_ready!`) with the workspace bind-mounted read-write at the same path — prove one world: write a file via plain File (host) inside the workspace, `docker exec cat` it through a real spawn, same bytes; **network none**: `wrap(["ruby", "-e", "require 'net/http'; Net::HTTP.get(URI('http://example.com'))"])`... keep it lighter: `docker exec getent hosts example.com` fails / times out under `--network none` (pick the most stable network-denial probe for the chosen image and state it); `stop(_ctx)` removes the container (assert `docker ps` no longer lists it — and this runs even after test failures via an ensure in the harness); a second `workspace_ready!` reuses the running container (no second container).

- [ ] **Step 2: Implement** `Terret::Sandbox::Docker < Hames::Service` (`service_key :sandbox`): config `{image:, network: "none", workspace: [dirs]}` — workspace comes from the same row value the fs service uses; boot wiring passes the same list to both (docs/exec.md's row example shows it). `workspace_ready!` runs `docker run -d --rm --network <net> -v ws:ws ... <image> sleep infinity`, records the container id; `wrap(argv, cwd:)` → `["docker", "exec", "-w", cwd || ws.first, @container, *argv]`; `isolated?` true; `stop` → `docker rm -f`. `reconfigure` warns (a live image swap is a remount — honest). PTY: `pty_spawn` through the wrap gives `docker exec` under a host PTY — line-driven tools work; full TTY semantics inside the container (`docker exec -t`) noted in docs as a known limit unless trivially added.

- [ ] **Step 3: Gates** (docker suite runs locally; skips clean when absent) + commit:

```bash
git commit -m "Move the execution world into a container with one row"
```

---

### Task 13: Core — cache the allow-list projection

`AllowList.current_patterns` reverse-scans the whole session log on EVERY tool call; std tools multiply call volume by an order of magnitude. Cache per session, invalidated the log-first way: a `session/event` listener updates the cache on `policy/updated`; misses still derive from the log.

**Files:** Modify `gems/terret-core/lib/terret/tools.rb`; test in `gems/terret-core/test/loop_test.rb`.

- [ ] **Steps**: TDD — a counting-store or instrumented-fetch test proving the second call for a session does NOT rescan (e.g., wrap `current_patterns`' scan in a counter hook, or assert via a Sessions#fetch spy — pick the least invasive observable and state it); correctness unchanged across update/replay (reuse the existing HotPolicyTest cases as the regression net). Implementation: `AllowList.install` builds a per-install cache `{}` + registers a `session/event` listener (`policy/updated` → cache[sid] = patterns) alongside the pre_execute listener, both disposed together (return a composite disposer). Cache read: `cache.fetch(sid) { cache[sid] = scan(sid) }`; unknown-session deny-all behavior preserved. Commit:

```bash
git commit -m "Stop rescanning the log on every tool call"
```

---

### Task 14: The soak lane

§14's sqlite/pty fiber-scheduler soak, owed since M2. One skip-guarded-slow test file proving the reactor survives real load: N agents (8), each running multi-step tool turns (Bash echo + Write/Read via std tools) concurrently under `Sync`, against BOTH the SQLite store (file) and JSONL, with 2 long-lived PTYs streaming throughout — assert: all turns complete, every session's seqs are unique and contiguous (the M6 append lock under real fire), no interleaved corruption in either store (re-read and verify), the PTYs stayed responsive (a final round-trip), wall-clock bounded (a generous ceiling proving no reactor stall). Gate behind `TERRET_SOAK=1` so CI's default lanes stay fast; add a CI job note in the ship task if trivial, else record.

**Files:** Create `gems/terret-exec/test/soak_test.rb`.

- [ ] **Steps**: write it, run it 3x locally (`TERRET_SOAK=1 mise exec -- bundle exec ruby gems/terret-exec/test/soak_test.rb`), report timings; full gates (it skips by default). Commit:

```bash
git commit -m "Soak the reactor with stores and terminals under load"
```

---

### Task 15: The acceptance — one patch row, zero tool changes

§12's criterion, literally. One test, two boots: identical rows (fs+subprocess+shell+terminals+sandbox-none+tools-std+loop+FakeAdapter script driving `Bash("uname")`, `Write`, `Read`, and a terminal round-trip), then THE SAME row array + one appended patch row `{ id: "sandbox", plugin: Terret::Sandbox::Docker, config: {...} }` — layered via a second `loader.layer` call, the §7 mechanism. Assert: local run's Bash result contains `Darwin` (or the host uname), docker run's contains `Linux`; the Write/Read round-trip works in both worlds on the same workspace file; the tool ROSTER and every Definition are object-identical between boots except Bash's sandbox-derived approval (`:always` local, `:policy` docker — assert exactly that difference, it's §13 made visible); zero tool code was touched (the test imports the same service classes — state it in a comment). Docker-gated skip.

**Files:** Create `gems/terret-sandbox-docker/test/acceptance_test.rb`.

- [ ] **Steps**: TDD (it fails until wired), run 3x, full gates. Commit:

```bash
git commit -m "Prove the M7 acceptance: one row moves the world"
```

---

### Task 16: Demo + ship

**Demo** (`examples/exec_demo.rb`): narrated, offline-safe: boot local world in a tmp workspace → Read/Write/Edit/Glob/Grep through the pipeline under a deny-then-allow policy flip (reusing M6's hot-policy story with real file tools), Bash showing `uname` + persistent cwd, a terminal round-trip, the redactor scrubbing a fake secret from a tool result; then, IF docker is available, the patch-row swap re-runs the Bash act inside the container (`uname` flips) — else print a clear "docker not available, skipping act 5". Exit 0 both ways.

**Ship**: docs sync — §12 M7 → SHIPPED (house voice; *Accepted:* the patch-row test + soak; *Deferred:* landlock/seatbelt, fs.watch, task/jobs/todo tools (M8), the tool barrier honoring `concurrency:` (M8), writer task (soak-gated), harness idempotency keys); §14 — mark the M6-recorded items this milestone paid (register bleed, reconfigure atomicity, O(n) allow-list scans, sqlite/pty soak) and add anything the gates defer; §13 already true — verify against docs/security.md; CLAUDE.md (eleven gems, three new bullets, exec_demo command, M0–M7); README (same); `rake events:catalog` clean. Full gates + ALL demos. Then the adversarial gates, both, exactly as M6 ran them: a fresh opus whole-milestone reviewer over the milestone diff (cross-cutting probes: workspace containment under symlink/traversal attack, sandbox-wrap bypass hunting — any spawn path that skips `sandbox.wrap` is a P1, redaction-vs-invariant, disposal hygiene with terminals open, the soak), and the `/codex challenge`; synthesize, fix batch, Final-gate fallout appended here (never staged), push `origin main`, `gh run watch`, milestone report.

```bash
git commit -m "Walk the execution world in a demo"   # demo commit
git commit -m "Mark M7 shipped across the roadmap and README"   # docs commit
```

---

## Mid-execution fallout notes (controller log; never staged)

- **Task 4 P1 paid** (`9d322d6`): the `fs/authorize` path-rewrite bypass is closed — listeners veto or admit only; a returned Hash's `:path` is ignored. Failing-first evidence showed the write direction was WORSE than the review recorded: a rewriting listener could clobber an arbitrary outside file with attacker content, not just redirect reads. Carry into Task 16's review synthesis.
- **Glob shape decided**: fs `glob` and the Task 8 `Glob` tool return ABSOLUTE paths (round-trips into read/edit unambiguously under multi-root workspaces; matches CC's Glob). Task 4/8 text updated.
- **Task 6 landed** (`5722ae0`) with approved extensions: `PTYHandle#read(max, timeout:)` bounded form added (Task 7 needs it; unbounded form still blocks/parks per spec). Open3 empirical correction: capture3 DOES cooperate with the fiber scheduler; the real objections are 3 threads per call + no deadline — code comment states the corrected rationale.
- **Recorded deferral (→ §14 at Task 16)**: a fiber cancelled mid-`spawn` (Async::Stop in-flight) orphans its child — ensure closes pipes but cannot reuse `reap!` (its sleep would re-raise inside ensure). Exposure today is low (M6 park/resume parks at approval gates, not mid-spawn; the `timeout:` path reaps correctly). Needs a design decision before M8's cancellation work. Point the whole-milestone reviewer at it.
- **Task 12 note**: subprocess does NOT call `sandbox.workspace_ready!`; the docker provider must ensure its container lazily from inside its own `wrap` (as its task text intends). Also: bind-mount paths must agree with fs AFTER realpath — feed both the same pre-realpath config string (Task 4's macOS /var symlink lesson).
- **Task 9 watch items**: (a) subprocess Results are force-encoded UTF-8 and may carry invalid bytes; `Sessions#normalize_payload` REFUSES invalid UTF-8 — the Bash tool must scrub (e.g. `String#scrub`) before its result reaches the append boundary, with a test proving a binary-emitting child doesn't poison the append. (b) A missing command raises `Errno::ENOENT` from the direct-spawn path — terminal_open must render it as a tool error, not crash the turn.

- **Task 7 landed** (`02c0430`): shell sessions keyed per owner, terminals registry keyed `[owner, name]` with per-owner cap (capability-leak rationale documented; `NoSuchTerminal` reads identically for never-opened/closed/not-yours so owners can't probe each other). Shell `run` → `Result(status, stdout, notice)` — `notice` carries restart/timeout facts SEPARATELY from stdout.
- **FIX REQUIRED in Task 6's file (escalated by Task 7, pending reviewer verdict before dispatch)**: `PTYHandle#close` can wedge the reactor — a SIGKILLed child with unread pty output sticks in macOS `E` state and the blocking `Process.wait2(pid)` (subprocess.rb ~:132) never returns. Measured: banner-pending bash wedged at 15s+; drained-first 2.01s; exit+EOF 0.00s. Fix: close the master/writer fds BEFORE reaping (or drain inside the reap loop) — likely also removes the full-term_grace burn on TERM-ignoring interactive bash (finding 2). Shell/Terminals already sidestep it in their own close paths; any future pty consumer inherits the trap until fixed.
- **Task 9 additional notes**: (c) Bash tool MUST render `Result.notice` (shell restarts after timeout are otherwise invisible to the model); (d) shell timeout uses ETX→SIGINT on the foreground pgroup — a child trapping SIGINT that never touches the terminal can outlive the killed session (documented limit in code, not papered over).
- **Task 12 additional note**: `docker exec` without `-t` has no tty — stty fails (suppressed), bash goes non-interactive, sentinel protocol still parses (marker regexp tolerates CR-LF). Whether the docker provider passes `-t` needs a deliberate decision in Task 12.
- **Cosmetic**: `IO::Buffer is experimental` warning surfaces from subprocess.rb pty writes under the scheduler in the plain lane — pre-existing, harmless, noisy; candidate for suppression at ship if trivial.

- **Task 7 review verdict: FIX_REQUIRED** (all findings probe-confirmed). P1: no per-session serialization on `Shell#run` — 4 fibers on one key: `run("echo one")` returned `status: 0, stdout: "four\n"` (another command's output, success-shaped); unreachable via today's sequential loop dispatch but `concurrency:` is unenforced metadata and `ctx[:shell]` is a public seam → fix: per-session in-flight guard raising a Tools::Failure. P2a: `Terminals#input` on a dead child raises raw `Errno::EIO` (fix: `TerminalGone < Tools::Failure`). P2b: backgrounded children (`cmd &`) survive every disposal path with the agent's authority; probed fix that works: `set +m` in HANDSHAKE puts bg jobs in bash's own pgid + pgroup KILL at disposal (^C path unaffected; `huponexit` does NOT work). P2c: no output cap — 11.4MB buffered in 3s, ~450MB possible at default timeout → seam-level `max_output` config, truncation stated in `notice`. P3s: dup `timeout ||=` line, spewing-child ~3s overshoot (comment), drain-budget bleed (comment), job-control notices in stdout (soften comment), shell has no session cap (document the decision), test gaps (concurrent-run guard, dead-terminal input, ShellUnavailable, double close_all), stale gemspec blurb. STRONG (don't re-probe): sentinel unforgeable, echo exact, status parsing exact incl pipefail, timeout recovery all paths, notice design, terminals ownership model. Subprocess#spawn shares the unbounded-buffer property → §14 note at ship.

- **PTYHandle wedge fixed** (`99783c5`): fds close BEFORE reap in `PTYHandle#close`; measured wedge-forever → 0.02s, and interactive bash no longer burns term_grace (SIGHUP on master close). Key finding written into the code: the wedged fiber parks in the scheduler's own process_wait hook — NOTHING in-reactor can rescue it (the test's watchdog is a plain Thread + join for exactly this reason, documented in-test).
- **Task 7 review fixes landed** (`63f6244` ShellBusy guard, `29b3cc4` set +m + pgroup sweep, `cdccb0f` max_output cap + TerminalGone): all P1/P2/P3 findings addressed with failing-first evidence; re-review pending. Notables: `#sweep` rescues EPERM too (Darwin answers EPERM when every remaining group member is a zombie — probed); `set +m` does NOT silence `[1] pid` job notices (pinned by test; "exact stdout" comment now defines exact as no-echo/no-prompt/no-injected-separator); max_output default 1MiB, truncation byte counts in `notice`, marker still found past the cap via a rolling window so oversized runs keep their real status.
- **Task 9 impact (append to watch items)**: (e) `ctx[:shell].run` can raise `ShellBusy`, `ctx[:terminals].input` can raise `TerminalGone` — both Tools::Failure, tools must let them render as refusals, not crashes; (f) `notice` now carries truncation as well as restarts — the Bash tool must render it.
- **Known shapes, accepted**: disposal during an in-flight run surfaces as `:eof` result + "session ended" notice (defending further would need the queue the P1 decision rejected); `max_output` bounds one run, not a session (kernel tty buffer self-limits between runs).

- **Re-review round 1**: ALL original P1/P2/P3 findings verified FIXED (4-fiber probe: zero wrong attributions in 5 trials; all six background-job/disposal combos reaped; blast-radius verified safe — PTY.spawn setsids so `-pgid` can only name the session's own group; in-flight flag provably releases on all six abnormal paths). TWO NEW confirmed P2s in cdccb0f's `collect` cap arithmetic: NEW-1 `kept.byteslice(0, cap)` cuts mid-UTF-8 → seam-manufactured invalid bytes → `JSON.generate` RAISES at the durable append boundary in both stores (fix: back off ≤3 bytes while the trailing sequence is incomplete, count them as dropped; NOT a blanket scrub — child-emitted invalid bytes stay preserved); NEW-2 marker straddling the cap (output length in `(cap-40, cap)`) leaks sentinel bytes into stdout AND makes `dropped` negative, suppressing the notice — sentinel leak defeats the protocol's forgery resistance mid-session (fix: clamp `out` to `min(cap, marker_abs)` via the window's absolute offset; negative dropped = bug, not `.positive?` fodder). Probed-clean, don't re-test: marker survives the rolling window under a concurrent 90KB background writer; close_all racing an in-flight run is benign+deterministic; a self-setsid child escapes the sweep by design (sandbox is the backstop).

- **Cap boundary P2s fixed** (`905cd48`, controller-verified + gates re-run green): `whole_characters` backs a seam-chosen cut off to the last whole UTF-8 character (narrow rule: never manufacture invalid bytes from valid ones; child garbage preserved verbatim); marker cut now taken at the marker's absolute stream offset (`marker_at`), sentinel can no longer leak; `dropped!` raises on negative counts. Approved scope extension: the same back-off applies to `:timeout`/`:eof` partial returns (equally seam-chosen cuts). TASK 7 CHAPTER CLOSED — shell 45 runs/118 assertions, terminals 26/46, all suites green both lanes. Task 9 reminder stands: child-emitted invalid bytes STILL round-trip (documented stance) — the Bash tool must scrub before append.

- **Task 8 landed** (`2de76b3`, controller-reviewed + gates verified 27/27): five file tools, CC names verbatim, pure seam delegation, JSON-Schema params (the wire convention, matching mcp Translate + demos), handlers are kwarg blocks (`d.handler.call(**c.args)`). Carry-forwards for the Task 16 milestone review: (1) live-rg lane is skip-guarded and UNPROVEN locally (no real rg binary here — check whether it ran on CI Linux at ship); (2) Grep output is UNCAPPED into the session log (shell got max_output for exactly this; plan didn't ask for Grep — reviewer should weigh a cap); (3) `**/*` Grep dispatches one fs/authorize waterfall per file (perf observation for the soak); (4) rg emits "binary file matches" notes where the Ruby scan silently skips binaries (deliberate: filtering rg stdout by shape would silently swallow on format drift); (5) `Read` has no offset/limit (fs seam has no partial read — M8 candidate); (6) tools-std gemspec declares terret-exec as a runtime dep (honest about mountability today, philosophically couples the roster to one provider — decide at the ship docs pass whether profiles should own that composition instead).

- **Task 9 design decision (controller-approved, option A of three)**: the registry did not expose the executing call's session to handlers (`d.handler.call(**c.args)` — args only). Fix: `Registry#execute` injects `session_id: c.session_id` into kwargs IFF the handler declares that keyword (checked across both `:key`/`:keyreq` proc parameter shapes). Merge order is security-relevant: the Call's value merges LAST so a model-forged `session_id` in args can never hijack another session's shell/terminals (spoof test required). Wire schema unchanged — session_id is harness-injected, never a params property. Rejected: fiber-local stash (implicit global, stale on veto), tools/execute providers (Definition handler becomes a decoy policy reads). Two commits: core (`Hand tools the session they run in`) then tools. Docs note for ship: exec.md §5 should mention the handler `session_id:` contract.

- **Task 9 landed** (`0ee5b04` core session injection + `6286abc` bash/terminal tools; reviewer verdict pending). Core: injection detection covers `:key`/`:keyreq` (verified per-shape on this Ruby; `**args` handlers deliberately get nothing), spoof merge-order test in place, wire schema asserted unchanged, standalone-SHA suite run in a detached worktree (green). Red-phase gap on the core commit honestly disclosed — mutation evidence accepted (both mutations re-failed the exact tests, then reverted). Tools: notice rendered below a `--- terret ---` separator with command bytes untouched above; scrub tests assert survival of a REAL Sessions#append; ms→s timeout conversion (CC convention); terminal_open exposes neither cwd nor env (uncontained cwd / env credential-laundering — row's decision); private helpers renamed away from `Kernel#open` shadowing. KEY FINDING (measured): loader emits config/updated OUTSIDE with_owner — a listener's naive re-registration belongs to NO row and survives unload!; fixed via one row-owned effect frame whose disposer calls the current registration. Accepted edge for docs at ship: a patch-row PLUGIN CLASS swap of the sandbox doesn't emit config/updated (that path re-boots and registers fresh) — worth a line in exec.md §5.

- **Task 9 review: FIX_REQUIRED on 6286abc** (0ee5b04 approved standalone). Confirmed: EACCES/ENOEXEC leak as "fork failed" (fix: widen rescue, NOT SystemCallError — exhaustion must crash loudly); model `timeout` unvalidated ("500"→NoMethodError; 0 is truthy → destroys the model's own session and reports "timed out after 0.0s"); empty/nil argv TypeError; `max_output: -1` crashes every call. CONTROLLER OVERRULE on P2-1: the approval derivation/listener STAY (§13 recorded contract) — but `requires_approval?` (`always || (policy && mutating)`) collapses the distinction for mutating tools, so exec.md's promised relaxation doesn't occur today: docs rewritten to declare it, pinning test added, consumer that distinguishes = M8 candidate. `terminal_read` KEEPS mutating: true for the honest reason: a PTY read consumes the stream (non-idempotent). LEDGER separator confirmed forgeable (fixed literal) — comment softened, mechanism unchanged (genuine remarks append after forged ones; remarks are data). Truncation counts measure scrubbed text stacked on the seam's 1 MiB cap — wording made honest. Stale-verdict-on-raising-isolated? noted in comment (load-bearing the day the collapse is fixed). Reviewer's strong list: effect hygiene perfect across 20 swaps (frame count constant, unload reaps all incl. the one ownerless frame); cross-session isolation real through the tools; mid-flight swap harmless by construction (`d` bound before handler; handler closes over @ctx, never @approval).

- **Task 9 CLOSED** (`7f84657` fix round, controller-verified, 30/30 suites green): all review items landed. Honest disclosures accepted: ENOEXEC unreachable on this platform (unrecognized-format 0755 file falls back to /bin/sh and SUCCEEDS — rescue declared, no fake test; needs a non-fallback platform to exercise); `Integer()` accepts `0x10`/`1_000` literal forms (harmless, wider than the message implies); max_output clamps rather than refusing (visible "kept the first 0 bytes" degradation over refuse-at-boot — hot-swap path has no validation hook). exec.md §5 now declares the approval collapse honestly with a pinning test in approvals_test.rb.

- **Task 10 CLOSED** (`f3df226`, controller-reviewed, 31/31 suites green): WebFetch behind deny-by-default hostname policy. Transport is a 3-tuple `[status, headers, body]` (the plan sketched 2 — Location must be visible to the per-hop policy check; redirects deliberately NOT followed inside the transport). Ports ride (hostname policy; port egress = sandbox row); userinfo refused not stripped; host lowercased before fnmatch (DNS case-insensitivity would otherwise be a fail-OPEN hole); refusal messages never echo the URL (may carry a password; lands in the durable log unscrubbed). Live lane caught two stub-invisible bugs, both pinned socket-free: Net::HTTP#request returns the RESPONSE not the block value; break-ing out of read_body corrupts every other chunked/gzipped page (`wrong chunk size line`) — fixed by draining and not KEEPING past the cap. Security assertions mutation-tested (per-hop admit!, downcase, redirect cap, drain). `concurrency: :serial` matches the exec.md table (a :parallel candidate for M8 — one-line table+tool change, deliberate).

- **Task 11 landed** (`0b0cd79`, reviewer verdict pending): scrubber folded in normalize_payload's String arm post-UTF-8-validation; zero-scrubbers fast path allocation-free; `ScrubberContractViolation` (plugin bug, names the offender via Proc#inspect source location) deliberately distinct from `NonPrimitivePayload` (data bug) — never the same rescue. Approved deviation: post_execute rewrites Result content AND error (Failure messages echo credentials; derive projects error) — exec.md §6 corrected accordingly. gsub BLOCK form pins away the `\0` paste-the-secret-back attack. Honest cost documented: a model's own tool-call args are stored redacted while executing live — resume replays [REDACTED] to the model (fails safe); over-broad patterns are config responsibility. Invariant verified end-to-end: step_loop appends BEFORE deriving, so digest compares scrubbed to scrubbed; real turn with leaked secret completes `:completed`.

- **Task 11 review: FIX_REQUIRED** (all CONFIRMED by probes). P1: streamed secrets land plaintext in durable assistant/chunk events — provider chunk boundaries defeat per-fragment scrubbing (authoritative assistant/message clean, digest fine, but SQLite + WS replay carry the secret) → FIX: carry buffer in step_loop (K=0 when no scrubbers; `scrub_carry` config default 256; re-chunking fine, concatenation byte-identical; secret>window = documented limitation). P2a: complete_dangling re-executes owed calls with [REDACTED] literally substituted — a DIFFERENT real command, silently → FIX: refuse + tool/result error when stored args carry the redactor's token (ctx[:redactor].replacement via service?). P2b: scrubber eats structural ids (duplicate tool_call ids = provider rejection; session/forked from: = lineage gone; append-only = permanently poisoned) → FIX: key-aware skip denylist threaded through normalize_payload. P2c: Symbol values bypass scrub AND UTF-8 normalization → one-line fix. P3s: register_scrubber ctx: kwarg (the Task 3 bleed shape); pin raising-scrubber/compactor/context-injected; 4 doc sentences (history not retro-redacted; Veto skips post_execute; ordering unpinned; carry window). Reviewer-verified strong: gsub block-form catch; equal?-not-== disposer; atomic reconfigure rollback; fast path allocation-free (0.001s/200 appends); compactor + mixed-log invariant hold.

- **Task 11 fix round landed** (`b2c0809` carry buffer, `d211b2c` structural exemption, `3608463` resume refusal; re-review pending). Carry buffer: 4 flush points (TextDelta hold-back, ToolCallEnd/MessageStop hold:0, post-stream hold:0 before assistant/message), character-boundary cuts, hold=0 when not scrubbing (delta-for-delta pinned); raising stream loses the held tail DELIBERATELY (ensure would mask adapter errors; that step's message never lands either, resume re-requests). Chunks pinned OUT of derive_messages/digest. DESIGN DIVERGENCE (approved): denylist is POSITIONAL (STRUCTURAL_KEYS valid only at payload top + inside parts containers, scope dies permanently entering content-bearing containers) — a flat name list would exempt model-supplied args[:name]/args[:content] (a Write's whole body). `patterns` on the list (a scrubbed allow list silently changes what an agent may run). FIFTH BUG found+fixed: Approvals#recorded_verdict compared LIVE args to STORED (redacted) payload → approved secret-bearing calls re-parked (2s wedge signature); fix routes both sides through public Sessions#stored_form. Honest edges: resume refusal recognizes only ctx[:redactor].replacement; a model literally writing [REDACTED] gets refused on resume (safe direction); all residual limits in exec.md §6 + security.md.

- **Task 11 re-review: carry buffer REJECTED (P1 not closed)** — append gets the flushed PREFIX only; held bytes scrub in a DIFFERENT append; steady-state chunks are byte-identical to provider deltas; leak rate 100% outside the final drain at EVERY window size; all tests passed because every message was <256B. META-LESSON for the ship gate: window-shaped fixes need window-straddling tests. FIX ROUND 2 (decided: reviewer option 2): when scrubbing, hold the ENTIRE text run, one chunk per run at run end — provably correct, trades live token streaming for the log guarantee under a mounted redactor (right default for autonomous workloads; chunks are replay/UI only); delete scrub_carry/windowing entirely. NEW P2: `name` OFF STRUCTURAL_KEYS (model-chosen; scrubbing a name fails safe as not-found, unlike ids) with the approvals name comparison through stored_form. NEW P3: stored_form NonPrimitivePayload → rescue in Approvals as "no recorded verdict" (park again, old behavior). Comment fix: raising-stream tail loss — run_turn closes on failure (no resume); claim held only for resume_turn. 8/9 original findings verified FIXED; child_scope survived every adversarial shadow; stored_form byte-compatible with pre-change verdicts.

- **Task 11 fix round 2 landed** (`a02fcb5` one-chunk-per-run, `28c7274` name-as-content): red evidence now indicts the mechanism (mid-stream secret in a delta-identical chunk); the old wrong-reason long-stream test DELETED not adapted; scrubbing? captured once per run (one run, one policy); windowing machinery deleted outright; verdict comparison hoisted out of the rindex scan (perf win); NonPrimitivePayload in stored_form → nil verdict (parks, never tears through the pipeline). One follow-up ordered: complete_dangling's refusal extends to redacted NAMES (resume contract: refuse whatever the log redacted; KeyError naming [REDACTED] is the "fork failed" misdiagnosis shape). Final reviewer pass after it lands.

- **Task 11 round 2 APPROVED** (P1 structurally closed: 0/601 leaking offsets at delta sizes 1/3/8/20/64, was 601/601; anatomy matches contract exactly; multi-run and raising-stream paths verified; name redaction end-to-end clean; mid-stream scrubber registration honors captured policy). Four P3s closing in one doc/comment polish commit: cross-run-split residual clause (secret straddling a run boundary via mid-credential tool call — narrow, authoritative message clean); stale exec.md:264 args-only sentence; name-safe replacement-token advice (default "[REDACTED]"'s brackets poison projected function names under over-broad patterns — permanent in an append-only log); approvals NonPrimitivePayload comment trimmed to truth (park's own raw append re-raises — PRE-EXISTING, unreachable from provider args → §14 note, not an M7 behavior change). After polish: TASK 11 CLOSED → dispatch Task 12.

- **TASK 11 CLOSED** (`bc4b6be` polish: cross-run residual named; :264 unstaled; token-charset advice; approvals comment truthed). Six commits total (0b0cd79, b2c0809, d211b2c, 3608463, a02fcb5, 28c7274, a07da25, bc4b6be — eight including polish), two adversarial rounds, one rejected fix, five bugs beyond the brief. §14 candidates from this task: park's raw append can raise on Ruby-synthesized non-primitive args (pre-existing); post_execute ordering contract (M8); a consumer that distinguishes :policy/:always (M8).
- **Task 12 dispatched** (docker sandbox; HEAD-guard bc4b6be): decided notes carried in — realpath mounts like fs, wrap ensures container lazily, `-i` yes / `-t` no (sentinel survives no-tty per Task 7 probe), env applies to the docker CLI not the container (documented), image ruby:slim (must carry bash), containers never survive the suite.

- **Task 12 landed** (`2925d04`, DONE_WITH_CONCERNS; reviewer verdict pending): `-i` mandatory (without it stdin never attaches — cat returned empty, bash EIO'd on handshake); **the recorded no-`-t` lean OVERTURNED by probe** — without `-t` the HOST pty echoes the request line INCLUDING THE SENTINEL into stdout (model learns the forgery-resistance value; measured through real ctx[:shell]); with `-t` on PTY spawns stdout is exact; `-t` on pipe spawns fails outright ("cannot attach stdin to a TTY-enabled container"). Gem ships `wrap(argv, cwd:, tty: false)` — seam contract unchanged today. APPROVED FOLLOW-UP (sequenced after reviewer verdict): 6 edits in terret-exec — pty_spawn passes `tty: true`, SandboxNone accepts-and-ignores, 4 test doubles. Network probe: getent hosts (fails FAST, 35ms — no interface beats DNS timeout) + ls /sys/class/net == ["lo"]. DECISIONS: CI runs the docker suite live (the plan intends the acceptance to run in CI; flake surface accepted, ship task watches); containers labeled terret-sandbox, teardown ASSERTS the sweep. **TASK 15 CRITICAL NOTES**: boot wiring must point shell/terminals cwd: at the workspace (Shell#cwd defaults to Dir.pwd = unmounted host repo path → Denied); wrap raises Sandbox::Denied on unmounted cwd (parallel to fs, never silently clamp); first wrap blocks the reactor for an image pull; workspace_ready! does no per-spawn liveness check (a dead container surfaces as the exec's failure); README/CLAUDE.md gem lists updated at ship (Task 16).

- **Task 12 review: FIX_REQUIRED.** NEW P1 (container-leak race): `@container ||= run_container!` — run_container!'s popen parks the fiber, so N concurrent first-wraps start N containers, orphan N-1 (unfindable by teardown; --rm never fires on sleep infinity). Reviewer-verified fix: `@lock = Mutex.new` (parks fiber under scheduler) + `workspace_ready! = @lock.synchronize { @container ||= run_container! }` → 1 container, 0 orphans. Task 14's 8-agent soak WOULD hit this. P1-2 (sentinel echo) UPGRADED to security regression: demonstrated LIVE forgery — model reads its own sentinel from echoed stdout, emits forged <sentinel><digits> to claim exit status + self-truncate + bleed into next call; also -icanon absent → 1024-byte MAX_CANON line truncation. tty:true follow-up verified sufficient. P2s: cancellation doesn't cross container (all kills hit the host docker CLI pid, not in-container bash — Shell#sweep's set+m guarantee void; document in gem + exec.md §2); dead container permanent (never clears @container → every spawn fails for process life; add restart!/clear-on-unknown); Grep breaks host-rg/image-no-rg (files.rb ripgrep fallback rescues only ENOENT, exec returns 127 — fix `return nil if [126,127].include?(result.status)`); root-in-container RW mount (Linux CI: container-written files root-owned, host fs can't edit — needs --user or doc). P3s: exec.md:125 stale argv (no -i/-t); no at_exit sweep net; IO::Buffer warning. STRONG: failure reporting (ContainerUnavailable < Tools::Failure), containment (-w outside ws → Denied), argv can't inject docker flags, network denial real 3 ways, realpath mount agrees with fs, Process.spawn bootstrap correct, teardown ASSERTS the sweep. TASK 15: land tty:true FIRST, then assert exact "Linux\n" + refute_match(/TERRET\h{32}/) so acceptance becomes the P1-2 regression net; shell/terminals cwd:ws required; pids host-side; cold pull needs generous deadline.

- **tty seam landed** (`e6c171e`): pty_spawn passes `tty: true`, SandboxNone accepts-and-ignores, 4 doubles updated; paired assertion `[false, true]` pins that -t rides the PTY path only, never pipe spawns. Both lanes green with a LIVE docker suite (16 runs, real containers, -t assertions exercised). Fix train stage 1 of 3 done. Stage 2 (docker P1 race + P2s) released to task12-docker guarding e6c171e; stage 3 (Grep 126/127) waits behind it. Confirmed: --user defaults ON (Process.uid:gid, nil-overridable); restart! not auto-clear (sandbox never sees exec result); no at_exit sweep.

- **Docker fixes landed** (`e0417b6` race, `923251f` restart!/--user; stage 2 of 3). Beyond brief (both correct): disposal shares the lock (a stop mid-run would clear an about-to-be-assigned id — mirror race); test teardown baselines label-containers in setup and sweeps the delta (old teardown swept only RECORDED ids = exactly what the race loses). --user ON verified: uid matches host, container-created file host-editable, PTY sentinel test passes unchanged (I have no name!/HOME=/ harmless under --norc). restart! recovers into a fresh container. End-to-end Task 15 rehearsal through real stack: "Linux\n501\n" exact, no sentinel, fs.edit succeeds on container-created file, loader unload removes container. exec.md rewritten from the landed commit. Grep fix (stage 3) released to task8-file-tools guarding 923251f. §14/ship notes: CI runs 21 live docker tests/push (gate behind env var? — decide at ship); README/CLAUDE.md gem list at ship.

- **TASK 12 CLOSED** — docker sandbox + full fix train (`2925d04` gem, `e6c171e` tty seam, `e0417b6` race, `923251f` restart!/--user, `d0233af` Grep fallback). Grep fix placed as `when 126,127 then nil` in the existing case (cleaner than a guard; approved). 33 suites green both lanes, 568 runs. Two latent CI-only bugs (Grep-under-docker, root-owned files) fixed before Task 15 could hit them painfully. Reviewer's Task 15 arming carried forward: assert exact "Linux\n" + refute_match(/TERRET\h{32}/), shell/terminals cwd:ws, pids host-side, cold-pull deadline.

- **Task 13 landed** (`eeed219`, controller-verified, both lanes green): AllowList cache is a per-install closure local (cross-agent-leak rationale in comment), log-first invalidation via a root `session/event` listener (found via parent-walk since session/event emits on the Sessions-mounting root, not the fork; owned by ctx.effect so fork.dispose! reaps it), composite disposer. KeyError (unknown session) NOT cached — deny-all never ossifies into allow (re-derives + re-warns each call). No-rescan observable = current_patterns call-counter via method redef; rescue moved from current_patterns to active_patterns (verified only caller is the miss path). Concurrency comment: no await between Hash touches → same-sid can't interleave, distinct sids independent, no lock.

- **SHIP-TASK CLEANUP (Task 16, before push):** commit `eeed219` is the ONLY M7 commit carrying Co-Authored-By/Claude-Session trailers (the other 31 are bare plain-sentence subjects per the house rule) — the Task 13 agent resolved the harness-mandates-trailers vs repo-no-trailers conflict the other way. Strip them at the pre-push history-hygiene pass (can't amend now — Task 14 is mid-flight guarding eeed219). Remind all remaining implementers: NO trailers/attribution in commit messages (already in every brief; reinforce).
- **Task 13 report accepted:** cross-session cache entries are inert-not-filtered (install isn't told its session id; filtering would change the public signature — M8 API-tightening candidate, harmless today since reads are by the call's own sid); current_patterns-is-pure-derivation verified no external caller depended on the old rescue.

- **Task 14 landed** (`08b0473`, controller-verified independently): soak passes 3/3 under TERRET_SOAK=1 (~0.6s, 422 assertions, 0 failures), skips clean in default lane (2 skips, fast), no leaked processes. Committed green rather than BLOCKED → no reactor stall found; M6 append lock holds under 8-agent concurrent fire against both SQLite + JSONL stores with PTYs streaming. (Report pending; independent verification stands.)

- **Task 14 soak report accepted** (real green, not tuned): the load-bearing design is a SECOND fiber per agent appending session/titled DURING the turn, so loop appends + titler race on one session's events.length — actually contends the M6 lock (single-fiber-per-session never fires it). Verified by re-reading a FRESH store on the same file: seq == (0...n) (lock failure would trip SQLite PK or JSONL gap), every row's session_id correct, no cross-agent content bleed. 8 agents × 9 tool calls × both stores + 2 streaming PTYs; ~0.1s healthy, 30s coarse near-hang ceiling; sharp detectors are PTY-round-trip-floor>3 and all-8-completed. §14/ship notes: (a) SQLite per-session writer-task deferral now EMPIRICALLY justified (single connection, sub-ms INSERTs, stays fast under this exact load) — was assumed; (b) no CI job wired for the soak (skips by default) — ship follow-up is an opt-in/scheduled TERRET_SOAK=1 job off the default lanes; (c) fs is one shared seam with all 8 workspace dirs (per-agent-isolated seams need separate boots, defeating the shared-lock point) — isolation verified in practice by the content checks.

- **Task 15 acceptance test landed** (`741af03`) — rigorous (source_location handler-identity proves the SAME block ran both worlds; field-for-field roster diff; exact uname; sentinel refute; PTY both worlds; one base_rows array layered by both). Passes on macOS (45 assertions). CONTROLLER-CAUGHT LATENT CI BUG (read the test, didn't trust the green): `refute_equal local[:bash], docker[:bash]` FAILS on Linux CI — host uname "Linux" == container uname "Linux", so the OS-name discriminator only works off-Linux. Fix ordered: discriminator becomes container-membership (/.dockerenv → ON-HOST vs IN-CONTAINER), OS-independent; keep the exact-uname + sentinel asserts. This is why the docker suite MUST be able to run on Linux (the CI-live decision) — a macOS-only-green acceptance is no acceptance. Fix pending; then Task 16.

- **TASK 15 CLOSED** (`741af03` + `1c612d3` discriminator fix, controller-verified 53 assertions): M7 ACCEPTANCE PROVEN. One appended sandbox row moves Bash/Read/Write/PTY into the container; roster field-for-field identical save Bash's approval (:always→:policy); handler source_location identical both worlds (same block ran). Discriminator is now /.dockerenv membership (ON-HOST vs IN-CONTAINER), OS-independent — agent proved via SIMULATE_LINUX that the old uname discriminator would have gone red on first CI run and the new one is green. Demo-honesty notes: fs runs host-side over the bind mount (one world, NOT fs-in-container); terminal round-trip proves PTY survival not location (demo can open a container terminal on os-release to show location); /.dockerenv is docker-specific (podman uses /run/.containerenv — future-provider note).

- **WHOLE-MILESTONE REVIEW: FIX_REQUIRED** (all 4 invariants HELD; engineering strong). P1 (cross-cutting, CONFIRMED): `dispose_agent` reaps the fork's REGISTRATIONS but not the RUNTIME process state tool calls created — `ctx[:shell]` sessions + `ctx[:terminals]` (root-mounted, keyed by session) survive disposal with backgrounded jobs still holding the agent's authority; no `agent/disposed` event exists for exec to hook (only per-turn agent/turn_stopping). Seam between M6 loop + M7 exec; the shell/terminals reviews checked close_all_for, the loop review checked fork disposal, the two never met. Plan §14 named this as THE M7 memory-lifecycle concern. FIX: declare `agent/disposed` emit event, dispose_agent emits with session_id after fork.dispose!, Shell + Terminals register listeners → close(session:)/close_all_for(session:). Keeps core decoupled from optional exec gem. Boundary of invariant 4: reversibility holds for registrations; runtime resources are tied to no registration. P2 (docs, CONFIRMED): WebFetch egresses HOST-side via Net::HTTP, NOT governed by sandbox network:none — coherent two-surface model but web_fetch.rb:35 SSRF pointer + security.md:46 + exec.md:173 misdescribe it; fix the prose. P3 (CONFIRMED primitive, OUT of threat model): fs realpath-then-open TOCTOU window — only reachable under mutually-untrusted shared-workspace agents (security.md declares out of scope); §14 hardening candidate (O_NOFOLLOW/openat), not a blocker. Suite 22252 runs 0 failures. Strong: redaction/invariant seam (holds by construction), sandbox-wrap one-funnel-one-exception, docker self-documentation.

- **Demo CLOSED** (`8b90829`): exec_demo.rb, exits 0 both offline and docker paths, no leaks. 6 acts: loop turn / file tools under a hot deny-then-allow flip / persistent shell cwd / PTY round-trip / redactor scrubs a fake secret / docker patch-row swap (uname→Linux, /.dockerenv→IN-CONTAINER, getent→NO-NETWORK, reads act-2's host-edited notes.txt from inside the container). Honest: fs stays host-side (not wrapped), only Bash+PTY move. DOCS-SYNC ANCHOR: exec.md bind-mount section could cite the notes.txt cross-world read as the concrete "one world" proof. No rough public API.

## SHIP-GATE FIX BATCH (both adversarial gates synthesized; opus review + Codex challenge)

**MUST-FIX before push (P1, reachable security/correctness):**
1. **Dangling-symlink containment escape** (fs.rb `contain`, CONFIRMED by controller probe — wrote outside the workspace, no race). `File.exist?` follows symlinks and returns FALSE for a dangling symlink (target absent), so contain treats `/ws/link` as a to-be-created path, validates the lexical parent (in-workspace), returns it — then `File.write`/`read`/`edit` FOLLOWS the symlink and escapes. Agent plants it with `ln -s /outside/x /ws/link` then `Write("/ws/link",...)`; under docker the symlink rides the bind mount and the HOST-side fs service follows it = container escape. Codex found it; opus rated only the racy TOCTOU variant out-of-scope. FIX (TDD the exploit as failing test first): reject a symlink at any component even when its target is absent — walk up treating `File.symlink?` as a stop, or `O_NOFOLLOW` on the final open + lstat-check the prefix; the existing symlink-target-EXISTS test must still Deny, and the dangling case must now Deny too.
2. **Agent disposal leaks shells + terminals** (both gates P1). dispose_agent reaps registrations, not the shell/terminal PROCESS state. FIX: declare `agent/disposed` emit event, dispose_agent emits with session_id after fork.dispose!, Shell + Terminals register listeners → close(session:)/close_all_for(session:). rake events:catalog + commit docs/events.md.
3. **WebFetch SSRF vs network:none** (opus P2-docs, Codex P1-metadata-exfil). WebFetch egresses HOST-side; an allowlisted hostname resolving to 127.0.0.1/169.254.169.254 exfils host/cloud creds despite --network none. FIX: (a) docs correction (web_fetch.rb:35 SSRF pointer + security.md:46 + exec.md:173 — WebFetch is host-side, only its allowlist governs it); (b) refuse loopback + link-local (169.254/16, ::1, 127/8) AFTER DNS resolution — kills the metadata vector cheaply; private-range blocking = config knob (M8). TDD.

**SHOULD-FIX (cheap, high-value; same batch):**
4. Shell sentinel forgeable via `printf(){...}` override (Codex P2, probe-confirmed) → use `builtin printf` in the sentinel emission (shell.rb ~:239). One word, restores the integrity claim.
5. Docker `wrap` returns bare `"docker"` → PATH-hijack if a workspace dir is on the harness PATH (Codex P1; reachability needs operator misconfig, but fix is trivial) → resolve docker to an absolute path at boot (or `docker_bin` config). Same for the internal system/IO.popen calls.
6. Docker `discard!` clears @container BEFORE `docker rm -f` and ignores status (Codex P2) → rm first / check status, so a transient failure doesn't lose the id with `sleep infinity` running.
7. Hash KEYS not scrubbed (Codex P1, reachable): `{"sk-secret" => "x"}` as tool args → key symbolized into the log unscrubbed. FIX: fold string keys through the scrubber in normalize_payload (respect the structural exemption).

**DEFER to §14 (document honestly at docs sync, don't fix now):**
- Read/Grep host-OOM: FS#read + Subprocess#capture + Grep unbounded → a huge file/line OOMs the HOST harness (kills every agent, not just one). Task 8 already flagged Grep uncapped. §14 + consider a read/grep cap in M8 (host-OOM severity noted).
- Mid-spawn / mid-close cancellation orphans children (Task 6 known + Codex PTYHandle @closed-before-reap refinement) → M8 cancellation model.
- WebFetch no total wall-clock deadline (Codex P2 slowloris on the reactor) → §14/M8.
- Docker no --memory/--cpus/--pids limits (Codex P1) → deployment-hardening config passthrough, M8.

## Acceptance (M7, from plan §12)

- [ ] One patch row moves Bash, Read, Write, and PTY into a container with zero tool changes (Task 15, docker-gated; the roster diff is exactly Bash's sandbox-derived approval).
- [ ] Workspace scoping contains every fs op — traversal and symlink escapes fail closed (Task 4).
- [ ] Every argv passes the sandbox seam; `none` is explicit opt-in; docker defaults `--network none` (Tasks 5, 6, 12).
- [ ] Std tools carry Claude Code's names with honest `mutating`/`approval`/`concurrency` metadata; Bash's approval derives from sandbox isolation (Tasks 8, 9; §13).
- [ ] WebFetch behind a deny-by-default domain policy row (Task 10).
- [ ] Credentials redacted at `tools/post_execute` AND the log-append boundary, with the invariant intact (Task 11).
- [ ] The sqlite/pty soak passes under the one-reactor rule (Task 14); M6's append lock holds under real fire.
- [ ] M6 §14 debts paid: register-on-root bleed, reconfigure atomicity, allow-list scan caching (Tasks 2, 3, 13).
- [ ] docs/exec.md + docs/security.md written first; both adversarial gates run; catalog current; README updated in the ship push.


