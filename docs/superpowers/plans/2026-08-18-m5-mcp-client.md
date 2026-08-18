# M5: The MCP Client (`terret-mcp`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship M5 from `docs/terret-implementation-plan.md` §12: `terret-mcp` — stdio and streamable-HTTP MCP servers mounted as tool sources under a `mcp__<server>__<tool>` namespace, per-server approval policy, a strict mode, and the declarative per-agent allow list — accepted by an agent whose entire tool roster arrives from MCP servers, working under policy, driven over the M4 socket.

**Architecture:** `terret-mcp` is an interface gem that mounts the first-party **manceps** gem (`~> 1.0`, RubyGems) behind the existing tools seam. Discovered tools register into `ctx[:tools]` as ordinary `Definition`s whose handlers call `client.call_tool` — no new execution path; the pipeline, policy waterfalls, and the log see MCP tools exactly like local ones. The client is injectable (`client_factory` config) so unit tests run on fakes; one integration lane drives a real stdio subprocess fixture through real manceps. Two core preludes make policy real: kernel effect disposers become self-removing (M4 debt — MCP mounts/unmounts many tools), and `Registry#execute` learns to dispatch its waterfalls on the calling agent's context so a per-agent allow list actually rides the fork.

**Tech Stack:** Ruby 4.0.6, plain minitest via the Rakefile glob, manceps 1.0.1 (httpx + base64 transitively) in `terret-mcp` only — kernel and core stay stdlib-only. Target wire protocol: MCP 2025-11-25/2025-06-18 (the deployed "legacy" wire and manceps' default; the 2026-07-28 stateless revision is not yet deployed anywhere and is out of scope, recorded in §14).

---

## Context primer (read before any task)

- Repo: six gems under `gems/`; this plan adds `gems/terret-mcp`. Run everything through `mise exec --` (rbenv lacks 4.0.6). Full gates: `mise exec -- rake test` AND `mise exec -- bundle exec rake test`. `Gemfile.lock` is deliberately gitignored — never commit it.
- House rules: `# frozen_string_literal: true` everywhere, `Data.define` for values, strict TDD (failing test first, always report the failure mode), house-style commit subjects (plain evocative sentence, no prefixes, no AI attribution), one implementer commits at a time, `git log -1` HEAD-guard before every commit, NEVER stage `docs/superpowers/plans/*`.
- The tools seam (`gems/terret-core/lib/terret/tools.rb`): `Definition = Data.define(:name, :description, :params, :handler, :mutating, :approval)`; `Registry#register(name:, description:, params: {}, mutating: false, approval: :never, &handler)` records via `@ctx.effect` (reversible); `Registry#execute(call)` runs `tools/pre_execute` (Veto short-circuits) → `tools/execute` (base block: `fetch(name).handler.call(**args)`, rescuing to an error `Result`) → `tools/post_execute`.
- Empirical fork facts (verified): `agent.ctx[:tools]` IS the root registry (forks delegate service lookup to parent); `Registry#execute` currently waterfalls on the ROOT ctx, so fork-registered listeners never fire for tool calls — Task 2 fixes that. `Context#waterfall`/`listeners_for` chain parent-first, so dispatching on a fork sees root listeners then fork listeners.
- The manceps client API (verified from source; depend on `~> 1.0` from RubyGems):
  - `Manceps::Client.new(url_or_command, auth: Manceps::Auth::None.new, args: nil, env: nil, **)` — stdio when `args` given or not http(s)-URL; `Auth::Bearer.new(token)` for HTTP.
  - `client.connect` / `client.disconnect` / `client.reconnect!` / `client.connected?`.
  - `client.tools` → array of `Manceps::Tool` (`#name`, `#description`, `#input_schema` — a JSON-Schema Hash).
  - `client.call_tool(name, **arguments)` → `Manceps::ToolResult` (`#text`, `#error?`, `#structured_content`, `#content` array of `Manceps::Content`).
  - `client.on("notifications/tools/list_changed") { ... }` registers a notification handler; `client.listen` is a BLOCKING dispatch loop (run it in its own Async task).
  - `client.read_resource(uri)` → contents object with `#text`.
  - Errors: `Manceps::Error` base; `ConnectionError`, `TimeoutError`, `ProtocolError`, `ToolError`.
  - Fiber-safety is emergent, not contractual: both transports cooperate under the async scheduler (empirically verified), but nothing upstream tests it — Task 11's canary pins it at OUR boundary. stdio has NO timeout (a wedged server parks the calling fiber forever) — the Service wraps calls in `Async::Task#with_timeout`.
- Boot/test harness conventions: copy the `TerretTestHarness`-style `boot(script:, extra_rows: [])` module per test file; `FakeAdapter` scripts are arrays of step hashes (`{ text:, tool_calls: [Terret::LLM::ToolCall.new(id:, name:, args:)] }`); the WS acceptance harness lives in `gems/terret-ws/test/protocol_test.rb` (FakeSocket, `await` with child-stopping timeout, `connect`).
- Config precedent: multiple things in one row = keyed Hash (`roles:`, `tokens:`) — MCP servers follow as `servers: { "name" => {...} }`.
- **Do not relax the log invariant.** MCP results are appended as primitives via the normal `tool/result` path; anything non-primitive is translated first.

## File map

| File | Status | Responsibility |
|---|---|---|
| `gems/hames/lib/hames/context.rb` | modify | self-removing effect disposers (M4 debt) |
| `gems/hames/test/hames_test.rb` | modify | disposer-leak tests |
| `gems/terret-core/lib/terret/tools.rb` | modify | `execute(call, ctx:)` + `AllowList` |
| `gems/terret-core/lib/terret/loop.rb` | modify | loop passes `agent.ctx` to execute |
| `gems/terret-core/test/loop_test.rb` | modify | per-agent policy tests |
| `docs/mcp.md` | create | the terret↔MCP mapping primer |
| `gems/terret-mcp/terret-mcp.gemspec` | create | manceps dependency lives here |
| `gems/terret-mcp/lib/terret/mcp.rb` | create | gem entry (monorepo fallback requires) |
| `gems/terret-mcp/lib/terret/mcp/translate.rb` | create | Tool→Definition + ToolResult→primitives (stdlib-only) |
| `gems/terret-mcp/lib/terret/mcp/service.rb` | create | `ctx[:mcp]`: mount/unmount, namespacing, policy, timeouts, list_changed, resources |
| `gems/terret-mcp/test/translate_test.rb` | create | codec tests (no manceps needed) |
| `gems/terret-mcp/test/service_test.rb` | create | fake-client tests: mount, call, policy, timeout, re-sync |
| `gems/terret-mcp/test/fixtures/stdio_server.rb` | create | minimal legacy-wire stdio MCP server |
| `gems/terret-mcp/test/integration_test.rb` | create | real manceps ↔ fixture subprocess + fiber canary (skip-guarded) |
| `gems/terret-ws/test/protocol_test.rb` | modify | the socket-driven M5 acceptance test |
| `Gemfile` | modify | `gem "terret-mcp", path: "gems/terret-mcp"` |
| `examples/mcp_demo.rb` | create | fixture-server demo end to end |
| `CLAUDE.md`, `docs/terret-implementation-plan.md` | modify | M5 shipped (final task) |

---

### Task 1: Kernel — a disposed effect leaves no trace

M4 debt item 1 (plan §14): `Context#effect` records `[owner, disposer]` in `@effects` forever; calling the disposer runs the teardown but leaves the entry (and everything its closure captures) pinned. MCP mounts and unmounts tools through effects constantly, so pay this down first: disposers become self-removing and idempotent.

**Files:**
- Modify: `gems/hames/lib/hames/context.rb` (the `effect` method)
- Test: `gems/hames/test/hames_test.rb`

- [ ] **Step 1: Write the failing tests**

Add a test class at the bottom of `gems/hames/test/hames_test.rb`:

```ruby
class HamesEffectHygieneTest < Minitest::Test
  def setup
    Hames.reset_events!
    @ctx = Hames::Context.new
  end

  def effects_count = @ctx.instance_variable_get(:@effects).size

  def test_a_called_disposer_removes_its_own_effect_entry
    calls = 0
    disposer = @ctx.effect { -> { calls += 1 } }
    assert_equal 1, effects_count

    disposer.call
    assert_equal 1, calls
    assert_equal 0, effects_count, "a disposed effect must not stay pinned in @effects"
  end

  def test_a_disposer_is_idempotent
    calls = 0
    disposer = @ctx.effect { -> { calls += 1 } }
    disposer.call
    disposer.call
    assert_equal 1, calls
  end

  def test_dispose_owner_still_runs_everything_once_in_reverse
    order = []
    @ctx.with_owner("me") do
      @ctx.effect { -> { order << :a } }
      @ctx.effect { -> { order << :b } }
    end
    @ctx.dispose_owner!("me")
    assert_equal %i[b a], order
    assert_equal 0, effects_count
  end

  def test_manually_disposing_then_owner_disposal_does_not_double_run
    calls = 0
    disposer = nil
    @ctx.with_owner("me") { disposer = @ctx.effect { -> { calls += 1 } } }
    disposer.call
    @ctx.dispose_owner!("me")
    assert_equal 1, calls
  end

  def test_a_disposed_listener_leaves_no_effect_entry
    Hames.event "tick", mode: :emit
    seen = []
    disposer = @ctx.on("tick") { seen << 1 }
    assert_equal 1, effects_count

    disposer.call
    @ctx.emit("tick")
    assert_empty seen, "a disposed listener must not fire"
    assert_equal 0, effects_count, "a disposed listener must not stay pinned in @effects"
  end

  def test_a_listener_disposer_is_idempotent_across_owner_disposal
    Hames.event "tock", mode: :emit
    disposer = nil
    @ctx.with_owner("me") { disposer = @ctx.on("tock") { } }
    disposer.call
    @ctx.dispose_owner!("me") # must not double-run or raise
    disposer.call             # nor this
    assert_equal 0, effects_count
  end
end
```

Note: `Context#on` records its disposal by pushing a raw frame into `@effects`
directly, bypassing `effect` — the listener tests above fail until `on` is
refactored to route through `effect` (build the listener entry, then
`effect { <insertion>; -> { <removal> } }`, preserving `prepend:` semantics
and the undeclared-event `ContractError`, returning the wrapped disposer).
The M4 Codex finding behind this debt was specifically about LISTENER
disposers, so Task 1 is not done until `on` has the same hygiene.

- [ ] **Step 2: Run and verify failure**

Run: `mise exec -- ruby gems/hames/test/hames_test.rb`
Expected: FAIL — `effects_count` stays 1 after disposal; the idempotence test double-runs.

- [ ] **Step 3: Implement**

In `gems/hames/lib/hames/context.rb`, replace the `effect` method:

```ruby
    # Run a registration block that returns a disposer. The disposer handed
    # back is self-removing and idempotent: calling it runs the teardown once
    # and drops its own entry from @effects, so a long-lived context does not
    # pin every disposed registration (and whatever its closure captured).
    # The done flag lives on the frame (not presence in @effects) because
    # dispose_owner! removes frames from @effects BEFORE running them — a
    # presence check would silently skip the real teardown there.
    def effect(&block)
      disposer = block.call
      return disposer unless disposer

      frame = [@owner, nil, false]
      wrapped = lambda do
        next if frame[2]

        frame[2] = true
        @effects.delete(frame)
        disposer.call
      end
      frame[1] = wrapped
      @effects << frame
      wrapped
    end
```

Note the frame is now a 3-element array `[owner, wrapped_disposer, done]`; `dispose_owner!`'s destructuring (`|(_o, d)|`) ignores the extra element, and its partition-then-call flow works because the done FLAG (not @effects presence) guards re-entry. `dispose!` iterates `@effects.reverse_each` while wrapped disposers delete from the same array — replace its body to iterate a copy:

```ruby
    # Dispose the whole context (child scopes call this when they end).
    def dispose!
      @effects.dup.reverse_each { |(_o, d)| d.call }
      @effects.clear
    end
```

- [ ] **Step 4: Run tests**

`mise exec -- ruby gems/hames/test/hames_test.rb` green, then full `mise exec -- rake test` green (the terret-ws suites exercise disposers heavily — they must all still pass).

- [ ] **Step 5: Commit**

```bash
git add gems/hames
git commit -m "Make effect disposers self-removing so nothing pins a dead registration"
```

---

### Task 2: Tool waterfalls dispatch on the caller's context

Per-agent policy is currently impossible: `Registry#execute` waterfalls on the ROOT ctx, so a `tools/pre_execute` listener on an agent's fork never fires. Give `execute` a `ctx:` kwarg (defaulting to the registry's own) and have the loop pass `agent.ctx`. Fork listeners chain parent-first, so global policy still applies before per-agent policy.

**Files:**
- Modify: `gems/terret-core/lib/terret/tools.rb` (`Registry#execute`)
- Modify: `gems/terret-core/lib/terret/loop.rb` (the `ctx[:tools].execute` call site)
- Test: `gems/terret-core/test/loop_test.rb`

- [ ] **Step 1: Write the failing test**

Add to `gems/terret-core/test/loop_test.rb`:

```ruby
  def test_a_pre_execute_listener_on_the_agents_fork_fires_for_that_agent_only
    ctx, = boot(script: two_step_script)
    register_weather(ctx)
    session_a = ctx[:sessions].create
    session_b = ctx[:sessions].create
    agent_a = ctx[:loop].spawn_agent(session_id: session_a.id)
    agent_b = ctx[:loop].spawn_agent(session_id: session_b.id)

    agent_a.ctx.with_owner("policy-a") do
      agent_a.ctx.on("tools/pre_execute") do |call, _next_|
        Terret::Tools::Veto.new(reason: "agent A may not use tools")
      end
    end

    assert_equal :completed, ctx[:loop].run_turn(agent_a, "weather?")
    vetoed = session_a.events.find { |e| e.type == "tool/result" }
    assert_equal "agent A may not use tools", vetoed.payload[:error]

    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(two_step_script))
    assert_equal :completed, ctx[:loop].run_turn(agent_b, "weather?")
    fine = session_b.events.find { |e| e.type == "tool/result" }
    assert_equal "22C in CDMX", fine.payload[:content]
  end

  def test_execute_refuses_to_run_without_a_context
    ctx, = boot(script: [{ text: "hi" }])
    register_weather(ctx)
    assert_raises(ArgumentError) do
      ctx[:tools].execute(Terret::Tools::Call.new(id: "t", name: "weather", args: {}, session_id: "s"))
    end
  end
```

- [ ] **Step 2: Run and verify failure**

`mise exec -- ruby gems/terret-core/test/loop_test.rb`
Expected: FAIL — agent A's tool executes normally (`22C in CDMX`), because the fork-registered veto never fires.

- [ ] **Step 3: Implement**

In `gems/terret-core/lib/terret/tools.rb`, change `execute`'s signature and every internal waterfall to use the passed context:

```ruby
      # Execution runs the three-waterfall pipeline: pre_execute (validate /
      # veto / rewrite) -> execute (a provider may replace execution
      # wholesale) -> post_execute (truncate / redact). Waterfalls dispatch
      # on `ctx`, which callers set to the AGENT's forked context so
      # per-agent policy listeners ride the fork (root listeners still run
      # first — fork dispatch chains parent-first). ctx is required — a
      # forgotten kwarg must fail loudly, not silently skip per-agent policy.
      def execute(call, ctx:)
        admitted = ctx.waterfall("tools/pre_execute", call)
        return Result.new(id: call.id, content: nil, error: admitted.reason) if admitted.is_a?(Veto)

        result = ctx.waterfall("tools/execute", admitted) do |c|
          d = fetch(c.name)
          begin
            Result.new(id: c.id, content: d.handler.call(**c.args), error: nil)
          rescue => e
            Result.new(id: c.id, content: nil, error: "#{e.class}: #{e.message}")
          end
        end
        ctx.waterfall("tools/post_execute", result)
      end
```

In `gems/terret-core/lib/terret/loop.rb`, the call site inside `run_turn`'s `calls.each` becomes:

```ruby
            result = ctx[:tools].execute(
              Tools::Call.new(id: tc.id, name: tc.name, args: tc.args, session_id: sid),
              ctx: ctx
            )
```

(`ctx` there is already `agent.ctx` — first line of `run_turn`'s body.)

- [ ] **Step 4: Run tests**

Target file green (including the pre-existing veto/replacement/unload tool tests — root-registered listeners must keep working), then full `mise exec -- rake test`.

- [ ] **Step 5: Commit**

```bash
git add gems/terret-core
git commit -m "Dispatch tool waterfalls on the calling agent's context"
```

---

### Task 3: The declarative allow list

Plan §6.3: a deny-by-default allow list with wildcards (`mcp__nexus__*`), implemented as a `tools/pre_execute` listener, installable per-agent on the fork (Task 2 made that real) or globally on the root.

**Files:**
- Modify: `gems/terret-core/lib/terret/tools.rb` (add `AllowList` inside `module Tools`)
- Test: `gems/terret-core/test/loop_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
  def test_the_allow_list_denies_unlisted_tools_and_globs_namespaces
    ctx, = boot(script: two_step_script)
    register_weather(ctx)
    agent, session = spawn(ctx)
    Terret::Tools::AllowList.install(agent.ctx, ["mcp__nexus__*"])

    assert_equal :completed, ctx[:loop].run_turn(agent, "weather?")
    denied = session.events.find { |e| e.type == "tool/result" }
    assert_equal "weather is not on the allow list", denied.payload[:error]
  end

  def test_the_allow_list_admits_matching_tools_and_is_reversible
    ctx, = boot(script: two_step_script)
    register_weather(ctx)
    agent, session = spawn(ctx)
    disposer = Terret::Tools::AllowList.install(agent.ctx, %w[weather])

    assert_equal :completed, ctx[:loop].run_turn(agent, "weather?")
    fine = session.events.find { |e| e.type == "tool/result" }
    assert_equal "22C in CDMX", fine.payload[:content]

    disposer.call # removing the list removes the gate entirely
    assert_kind_of Proc, disposer
  end
```

- [ ] **Step 2: Run and verify failure** — `NameError: uninitialized constant Terret::Tools::AllowList`.

- [ ] **Step 3: Implement**

Add inside `module Tools` in `gems/terret-core/lib/terret/tools.rb` (after `Veto`):

```ruby
    # Deny-by-default allow list (plan §6.3): a tools/pre_execute listener,
    # not a registry special case, so a per-agent list rides the agent's
    # forked context (Registry#execute dispatches on the caller's ctx).
    # Patterns are File.fnmatch globs, e.g. "mcp__nexus__*". Returns the
    # listener's disposer.
    module AllowList
      def self.install(ctx, patterns)
        patterns = Array(patterns).map(&:to_s)
        ctx.on("tools/pre_execute") do |call, next_|
          if patterns.any? { |p| File.fnmatch(p, call.name) }
            next_.(call)
          else
            Veto.new(reason: "#{call.name} is not on the allow list")
          end
        end
      end
    end
```

- [ ] **Step 4: Run tests** — file, then full gate, green.

- [ ] **Step 5: Commit**

```bash
git add gems/terret-core
git commit -m "Gate tools behind a deny-by-default allow list"
```

---

### Task 4: Write docs/mcp.md

Primer-first. Create the file with EXACTLY this content:

```markdown
# Terret and MCP (v1)

`terret-mcp` mounts Model Context Protocol servers as tool sources. It is a
client only, built on the manceps gem, and it invents no execution path: a
discovered MCP tool registers into `ctx[:tools]` as an ordinary definition
whose handler calls the server, so the pipeline, the policy waterfalls, the
approval metadata, and the session log treat MCP tools exactly like local
ones. Tool results are data (see docs/terret-implementation-plan.md §13);
nothing a server returns is executed except through the model.

## Wire target

The deployed MCP ecosystem speaks the "legacy" wire (protocol revisions
2025-11-25 / 2025-06-18): the `initialize` handshake, `Mcp-Session-Id`, and
JSON-or-SSE POST responses. That is what manceps implements and what v1
targets. The 2026-07-28 stateless revision is not deployed anywhere yet and
is out of scope (recorded in the plan's §14). Deprecated-in-current-spec
features (sampling, elicitation, roots) are not used.

## Configuration

One config row, servers as a keyed hash (the `roles:`/`tokens:` idiom):

    { id: "mcp", plugin: Terret::MCP::Service, config: {
        servers: {
          "nexus" => { url: "https://nexus.example/mcp",
                       bearer: ENV["NEXUS_TOKEN"],
                       approval: :policy, timeout: 30 },
          "files" => { command: "npx",
                       args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
                       approval: :always }
        },
        strict: false } }

Per-server keys: `url:` (streamable HTTP) or `command:` + `args:`/`env:`
(stdio) — exactly one of url/command; `bearer:` (HTTP auth); `approval:`
(`:never` | `:policy` | `:always`, default `:policy`) stamped onto every
tool the server contributes; `timeout:` seconds per call (default 30).

Connecting is explicit and happens after boot, inside the reactor:

    ctx[:mcp].mount!            # all configured servers
    ctx[:mcp].mount!("nexus")   # one
    ctx[:mcp].unmount!("nexus") # reverses every registration it made

## Namespacing

A tool `search` from server `nexus` registers as `mcp__nexus__search`. The
double-underscore namespace is the same convention orchestrator allow lists
already use, so `mcp__nexus__*` in an allow list means "everything this
server offers". Server names must match `/\A[a-z0-9_-]+\z/`.

## Policy

Three layers, all existing seams:

1. **Per-server approval** — the `approval:` config value lands on each
   `Definition`; the approval machinery that consumes it is M6.
2. **The allow list** — `Terret::Tools::AllowList.install(ctx, patterns)`
   installs a deny-by-default `tools/pre_execute` veto; installed on an
   agent's forked context it governs that agent alone (tool waterfalls
   dispatch on the calling agent's context).
3. **Strict mode** — `strict: true` refuses to mount any server that did
   not come from this config row. Today all servers come from the config
   row, so strict changes nothing observable; it exists so that when
   profile/home-level ambient config arrives (plan §7), a strict row is
   already contractually closed to it.

## Calls, timeouts, failures

A tool call round-trips through manceps inside the agent's turn fiber; IO
yields to the reactor, so other agents proceed. Every call is wrapped in
`Async::Task#with_timeout` (per-server `timeout:`): a timeout returns an
error `tool/result` ("mcp timeout after Ns") and tears the connection down
for a reconnect on next use, because the stdio transport has no timeout of
its own and correlates responses by ordering, not ids — a late reply to an
abandoned request must never be misread as the answer to the next one.
Server-side tool failures (`isError`) and transport errors also come back
as error results; they never raise into the loop.

## Results

`ToolResult#structured_content` wins when present (already primitives);
otherwise the text content items joined by newlines. Image/audio/resource
items degrade to a text placeholder naming the type and mime type — v1
carries no binary payloads into the log.

## Change notifications

When a server declares `tools.listChanged`, the service runs a listener
task; on `notifications/tools/list_changed` it re-lists and reconciles:
new tools register, vanished tools dispose, changed schemas re-register.

## Resources

`ctx[:mcp].register_resource_section(server, uri, name:, priority: 100)`
reads the resource once and registers its text as a prompt section (an
effect — disposing unregisters). Live refresh on `resources/updated` is
deferred until a consumer needs it.
```

- [ ] **Step 2: Commit**

```bash
git add docs/mcp.md
git commit -m "Write the MCP mapping primer ahead of the implementation"
```

---

### Task 5: terret-mcp skeleton and the translation layer

The gem shell plus `Translate` — stdlib-only, duck-typed against manceps' value objects so its tests need no manceps.

**Files:**
- Create: `gems/terret-mcp/terret-mcp.gemspec`, `gems/terret-mcp/lib/terret/mcp.rb`, `gems/terret-mcp/lib/terret/mcp/translate.rb`, `gems/terret-mcp/test/translate_test.rb`
- Modify: `Gemfile` (add `gem "terret-mcp", path: "gems/terret-mcp"` after the terret-ws line; then `mise exec -- bundle install` — resolves manceps 1.0.1 from RubyGems; report BLOCKED with the error if resolution fails; never commit Gemfile.lock)

- [ ] **Step 1: Write the failing test**

Create `gems/terret-mcp/test/translate_test.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret/mcp/translate"

class TranslateTest < Minitest::Test
  T = Terret::MCP::Translate

  FakeTool = Struct.new(:name, :description, :input_schema)
  FakeContent = Struct.new(:type, :text, :mime_type)
  FakeResult = Struct.new(:content, :structured_content, keyword_init: true) do
    def error? = false
  end
  FakeError = Struct.new(:content, keyword_init: true) do
    def error? = true
    def structured_content = nil
    def text = content.map(&:text).compact.join("\n")
  end

  def test_namespaces_and_maps_a_tool_definition
    tool = FakeTool.new("search", "Find things", { "type" => "object", "properties" => {} })
    reg = T.definition_args(server: "nexus", tool: tool, approval: :policy)

    assert_equal "mcp__nexus__search", reg[:name]
    assert_equal "Find things", reg[:description]
    assert_equal({ "type" => "object", "properties" => {} }, reg[:params])
    assert_equal :policy, reg[:approval]
    assert reg[:mutating], "unknown remote effects default to mutating"
  end

  def test_rejects_bad_server_names
    assert_raises(ArgumentError) { T.assert_server_name!("no spaces") }
    assert_raises(ArgumentError) { T.assert_server_name!("Upper") }
    assert_equal "ok-name_1", T.assert_server_name!("ok-name_1")
  end

  def test_structured_content_wins_and_is_returned_as_primitives
    result = FakeResult.new(content: [FakeContent.new("text", "ignored", nil)],
                            structured_content: { "total" => 3 })
    assert_equal({ "total" => 3 }, T.result_content(result))
  end

  def test_text_items_join_and_binary_items_degrade_to_placeholders
    result = FakeResult.new(content: [
      FakeContent.new("text", "line one", nil),
      FakeContent.new("image", nil, "image/png"),
      FakeContent.new("text", "line two", nil)
    ], structured_content: nil)
    assert_equal "line one\n[image image/png]\nline two", T.result_content(result)
  end

  def test_an_error_result_maps_to_the_error_channel
    err = FakeError.new(content: [FakeContent.new("text", "boom", nil)])
    assert_nil T.result_content(err)
    assert_equal "boom", T.result_error(err)
  end
end
```

- [ ] **Step 2: Run and verify failure** — `cannot load such file .../translate`.

- [ ] **Step 3: Implement**

`gems/terret-mcp/lib/terret/mcp/translate.rb`:

```ruby
# frozen_string_literal: true

module Terret
  module MCP
    # Pure translation between MCP shapes and terret shapes (docs/mcp.md).
    # Duck-typed against manceps' value objects so it needs no manceps at
    # test time and no network ever.
    module Translate
      NAME_RE = /\A[a-z0-9_-]+\z/

      module_function

      def assert_server_name!(name)
        name = name.to_s
        raise ArgumentError, "server name must match #{NAME_RE.inspect}, got #{name.inspect}" unless name.match?(NAME_RE)

        name
      end

      def tool_name(server, tool) = "mcp__#{server}__#{tool}"

      # Keyword args for Registry#register. Remote tools default to
      # mutating: we cannot see their effects, so policy assumes the worst.
      def definition_args(server:, tool:, approval:)
        { name: tool_name(server, tool.name), description: tool.description.to_s,
          params: tool.input_schema || {}, mutating: true, approval: approval }
      end

      # structured_content wins (already primitives); else text items join,
      # binary/resource items degrade to a typed placeholder. nil for errors.
      def result_content(result)
        return nil if result.error?
        return result.structured_content if result.structured_content

        result.content.map do |item|
          item.type == "text" ? item.text : "[#{item.type} #{item.mime_type || item.type}]"
        end.join("\n")
      end

      def result_error(result)
        return nil unless result.error?

        text = result.text.to_s
        text.empty? ? "tool failed with no message" : text
      end
    end
  end
end
```

`gems/terret-mcp/lib/terret/mcp.rb`:

```ruby
# frozen_string_literal: true

begin
  require "terret"
rescue LoadError
  require_relative "../../../terret-core/lib/terret" # monorepo path source
end

require_relative "mcp/translate"
require_relative "mcp/service"
```

(`service.rb` arrives in Task 6 — create it now as a placeholder so the require resolves:)

```ruby
# frozen_string_literal: true

module Terret
  module MCP
  end
end
```

`gems/terret-mcp/terret-mcp.gemspec` (the established template):

```ruby
Gem::Specification.new do |s|
  s.name = "terret-mcp"
  s.version = "0.1.0"
  s.summary = "MCP client plugin for the Terret agent harness"
  s.description = "Mounts Model Context Protocol servers (stdio and streamable " \
                  "HTTP, via the manceps client) as namespaced tool sources " \
                  "behind ctx.tools, with per-server approval policy, per-call " \
                  "timeouts, and live tool-list reconciliation."
  s.authors = ["Obie Fernandez"]
  s.email = ["obiefernandez@gmail.com"]
  s.homepage = "https://terret.org"
  s.license = "MIT"
  s.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb"] }
  s.required_ruby_version = ">= 4.0"
  s.add_dependency "terret-core", "~> 0.1"
  s.add_dependency "manceps", "~> 1.0"
  s.metadata = {
    "homepage_uri" => "https://terret.org",
    "source_code_uri" => "https://github.com/terret-org/terret",
    "bug_tracker_uri" => "https://github.com/terret-org/terret/issues",
    "rubygems_mfa_required" => "true"
  }
end
```

- [ ] **Step 4: Run tests** — translate_test green; `mise exec -- bundle install` resolves manceps; both full gates green.

- [ ] **Step 5: Commit**

```bash
git add gems/terret-mcp Gemfile
git commit -m "Add the terret-mcp gem with the translation layer"
```

---

### Task 6: The Service — mount, namespace, unmount

`ctx[:mcp]`: config parsing, client construction through an injectable factory, tools/list discovery, namespaced registration with per-server approval, reversible unmount, strict mode.

**Files:**
- Replace: `gems/terret-mcp/lib/terret/mcp/service.rb`
- Modify: `gems/terret-core/lib/terret/tools.rb` (`Registry#register` returns its disposer)
- Create: `gems/terret-mcp/test/service_test.rb`

- [ ] **Step 1: Write the failing tests**

Create `gems/terret-mcp/test/service_test.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret/mcp"

class MCPServiceTest < Minitest::Test
  FakeTool = Struct.new(:name, :description, :input_schema)

  # Duck-typed manceps client: canned tools, scripted results, call journal.
  class FakeClient
    attr_reader :calls, :connected, :disconnected

    def initialize(tools:, results: {})
      @tools = tools
      @results = results
      @calls = []
      @handlers = {}
      @connected = false
      @disconnected = false
    end

    def connect = @connected = true
    def disconnect = @disconnected = true
    def reconnect! = @connected = true
    def tools(*) = @tools
    def on(method, &block) = @handlers[method] = block
    def notify!(method) = @handlers.fetch(method).call({})
    def listen = nil

    Result = Struct.new(:content, :structured_content, :err, keyword_init: true) do
      def error? = err
      def text = content.to_s
    end

    def call_tool(name, **args)
      @calls << [name, args]
      spec = @results.fetch(name) { { structured: nil, text: "ok:#{name}", error: false } }
      Result.new(content: spec[:text], structured_content: spec[:structured], err: spec[:error] || false)
    end
  end

  def boot(servers:, strict: false, factory:)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "mcp",      plugin: Terret::MCP::Service,
        config: { servers: servers, strict: strict, client_factory: factory } }
    ])
    loader.boot!
  end

  def test_mount_registers_namespaced_tools_with_per_server_approval
    fake = FakeClient.new(tools: [FakeTool.new("search", "Find", { "type" => "object" })])
    ctx = boot(servers: { "nexus" => { url: "https://x/mcp", approval: :always } },
               factory: ->(_name, _cfg) { fake })

    ctx[:mcp].mount!
    assert fake.connected
    names = ctx[:tools].schemas.map { |s| s[:name] }
    assert_includes names, "mcp__nexus__search"
    d = ctx[:tools].fetch("mcp__nexus__search")
    assert_equal :always, d.approval
    assert d.mutating
  end

  def test_unmount_reverses_every_registration_and_disconnects
    fake = FakeClient.new(tools: [FakeTool.new("a", "", {}), FakeTool.new("b", "", {})])
    ctx = boot(servers: { "s" => { url: "https://x/mcp" } }, factory: ->(*) { fake })
    ctx[:mcp].mount!
    assert_equal 2, ctx[:tools].schemas.size

    ctx[:mcp].unmount!("s")
    assert_equal 0, ctx[:tools].schemas.size
    assert fake.disconnected
  end

  def test_calling_a_mounted_tool_round_trips_through_the_client
    fake = FakeClient.new(tools: [FakeTool.new("echo", "", {})],
                          results: { "echo" => { structured: { "said" => "hi" } } })
    ctx = boot(servers: { "s" => { url: "https://x/mcp" } }, factory: ->(*) { fake })
    ctx[:mcp].mount!

    result = ctx[:tools].execute(
      Terret::Tools::Call.new(id: "t1", name: "mcp__s__echo", args: { text: "hi" }, session_id: "x"),
      ctx: ctx
    )
    assert_nil result.error
    assert_equal({ "said" => "hi" }, result.content)
    assert_equal [["echo", { text: "hi" }]], fake.calls
  end

  def test_a_server_side_tool_error_maps_to_the_error_channel
    fake = FakeClient.new(tools: [FakeTool.new("bad", "", {})],
                          results: { "bad" => { text: "kaboom", error: true } })
    ctx = boot(servers: { "s" => { url: "https://x/mcp" } }, factory: ->(*) { fake })
    ctx[:mcp].mount!

    result = ctx[:tools].execute(
      Terret::Tools::Call.new(id: "t1", name: "mcp__s__bad", args: {}, session_id: "x"),
      ctx: ctx
    )
    assert_equal "kaboom", result.error
    assert_nil result.content
  end

  def test_strict_mode_refuses_servers_outside_the_config_row
    ctx = boot(servers: { "s" => { url: "https://x/mcp" } }, strict: true, factory: ->(*) { FakeClient.new(tools: []) })
    err = assert_raises(ArgumentError) { ctx[:mcp].mount!("ambient") }
    assert_match(/strict/, err.message)
  end

  def test_bad_server_names_and_missing_transport_are_refused_at_boot
    assert_raises(ArgumentError) do
      boot(servers: { "No Good" => { url: "https://x/mcp" } }, factory: ->(*) { FakeClient.new(tools: []) })
    end
    assert_raises(ArgumentError) do
      boot(servers: { "s" => { approval: :policy } }, factory: ->(*) { FakeClient.new(tools: []) })
    end
  end
end
```

- [ ] **Step 2: Run and verify failure** — `NoMethodError`/`NameError` on `Terret::MCP::Service`.

- [ ] **Step 3: Implement**

Replace `gems/terret-mcp/lib/terret/mcp/service.rb`:

```ruby
# frozen_string_literal: true

require_relative "translate"

module Terret
  module MCP
    # ctx[:mcp] — mounts MCP servers as namespaced tool sources (docs/mcp.md).
    # The client is injectable (client_factory config) so tests run on fakes;
    # the default factory builds a manceps client, lazily required so nothing
    # here needs manceps until something actually connects.
    class Service < Hames::Service
      service_key :mcp
      inject :tools, :prompt

      DEFAULT_TIMEOUT = 30

      def start(ctx)
        @ctx = ctx
        @strict = !!config[:strict]
        @factory = config[:client_factory] || method(:default_client)
        @servers = {}
        @mounted = {} # name => { client:, disposers:, tool_names: }
        (config[:servers] || {}).each do |name, cfg|
          name = Translate.assert_server_name!(name)
          unless cfg[:url].nil? ^ cfg[:command].nil?
            raise ArgumentError, "server #{name}: exactly one of url:/command: required"
          end

          @servers[name] = cfg
        end
      end

      def stop(_ctx) = @mounted.keys.each { |n| unmount!(n) }

      def mounted = @mounted.keys

      def mount!(*names)
        names = @servers.keys if names.empty?
        names.each { |n| mount_one(n.to_s) }
      end

      # Reverses every registration the server contributed and disconnects.
      def unmount!(name)
        entry = @mounted.delete(name.to_s) or return
        entry[:disposers].reverse_each(&:call)
        begin
          entry[:client].disconnect
        rescue StandardError
          nil
        end
      end

      private

      def mount_one(name)
        cfg = @servers[name] or
          raise ArgumentError, @strict ? "strict mode: server #{name.inspect} is not in this row's config" :
                                         "unknown server #{name.inspect}"
        return if @mounted.key?(name)

        client = @factory.call(name, cfg)
        client.connect
        entry = { client: client, disposers: [], tool_names: [] }
        @mounted[name] = entry
        sync_tools(name, entry, cfg)
        entry
      end

      def sync_tools(name, entry, cfg)
        approval = cfg[:approval] || :policy
        timeout = cfg[:timeout] || DEFAULT_TIMEOUT
        entry[:disposers].reverse_each(&:call)
        entry[:disposers].clear
        entry[:tool_names].clear

        entry[:client].tools.each do |tool|
          args = Translate.definition_args(server: name, tool: tool, approval: approval)
          remote = tool.name
          @ctx.with_owner("mcp:#{name}") do
            entry[:disposers] << @ctx[:tools].register(**args) do |**call_args|
              call_remote(name, entry, remote, call_args, timeout)
            end
          end
          entry[:tool_names] << args[:name]
        end
      end

      def call_remote(name, entry, remote, call_args, timeout)
        result = with_timeout(timeout) { entry[:client].call_tool(remote, **call_args) }
        error = Translate.result_error(result)
        raise error if error

        Translate.result_content(result)
      rescue *transport_errors => e
        raise "mcp #{name}: #{e.class}: #{e.message}"
      end

      def with_timeout(seconds, &block)
        task = defined?(Async) ? Async::Task.current? : nil
        return yield unless task

        task.with_timeout(seconds) { block.call }
      rescue Async::TimeoutError
        raise "mcp timeout after #{seconds}s"
      end

      def transport_errors
        defined?(Manceps::Error) ? [Manceps::Error] : [IOError]
      end

      def default_client(name, cfg)
        require "manceps"
        if cfg[:url]
          auth = cfg[:bearer] ? Manceps::Auth::Bearer.new(cfg[:bearer]) : Manceps::Auth::None.new
          Manceps::Client.new(cfg[:url], auth: auth)
        else
          Manceps::Client.new(cfg[:command], args: cfg[:args] || [], env: cfg[:env])
        end
      end
    end
  end
end
```

**Design notes for the implementer (do not skip):**
- Tool errors surface by RAISING inside the handler — `Registry#execute`'s base block already rescues handler exceptions into an error `Result`, so a raise IS the error channel. That is why `call_remote` raises the translated error string.
- This task includes a one-line core change: `Registry#register` in `gems/terret-core/lib/terret/tools.rb` currently ends with a trailing `d`, discarding the effect's disposer. Delete that trailing `d` so `register` RETURNS the disposer (which Task 1 made self-removing and idempotent), and add a comment line above the method: `# Returns the registration's disposer.` No existing caller uses the old return value (verify with a grep and say so in your report); the service's `sync_tools` relies on the new one.
- If a test fails against this code, report the analysis; where this sketch conflicts with the real seams, the seams win.

- [ ] **Step 4: Run tests** — service_test green (7 runs), translate_test still green, both full gates green.

- [ ] **Step 5: Commit**

```bash
git add gems/terret-mcp gems/terret-core
git commit -m "Mount MCP servers as namespaced tool sources"
```

---

### Task 7: Timeouts tear down and reconnect

The stdio transport correlates responses by ordering, not ids — a late reply to an abandoned request must never answer the next one. So a timeout must poison the connection: error result now, `reconnect!` before the next call.

**Files:**
- Modify: `gems/terret-mcp/lib/terret/mcp/service.rb`
- Test: `gems/terret-mcp/test/service_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  class SleepyClient < FakeClient
    attr_reader :reconnects

    def initialize(**)
      super
      @reconnects = 0
      @slow = true
    end

    def reconnect!
      @reconnects += 1
      @slow = false # healthy after reconnect
      super
    end

    def call_tool(name, **args)
      sleep 5 if @slow
      super
    end
  end

  def test_a_timeout_returns_an_error_result_and_reconnects_before_the_next_call
    require "async"
    fake = SleepyClient.new(tools: [FakeTool.new("slow", "", {})])
    ctx = boot(servers: { "s" => { url: "https://x/mcp", timeout: 1 } }, factory: ->(*) { fake })
    ctx[:mcp].mount!

    Sync do
      first = ctx[:tools].execute(
        Terret::Tools::Call.new(id: "t1", name: "mcp__s__slow", args: {}, session_id: "x"),
        ctx: ctx
      )
      assert_match(/mcp timeout after 1s/, first.error)

      second = ctx[:tools].execute(
        Terret::Tools::Call.new(id: "t2", name: "mcp__s__slow", args: {}, session_id: "x"),
        ctx: ctx
      )
      assert_nil second.error
      assert_equal 1, fake.reconnects, "the poisoned connection must reconnect exactly once"
    end
  end
```

(Add `require "async"`-guarded skip at the top of the test class setup if async is unavailable, following the terret-ws convention.)

- [ ] **Step 2: Run and verify failure** — first call errors (good) but `fake.reconnects` stays 0.

- [ ] **Step 3: Implement**

In `service.rb`, track poisoning per entry. In `call_remote`, on the timeout path mark `entry[:poisoned] = true` before raising; at the top of `call_remote`, heal first:

```ruby
      def call_remote(name, entry, remote, call_args, timeout)
        if entry[:poisoned]
          entry[:client].reconnect!
          entry[:poisoned] = false
        end
        result = with_timeout(timeout) { entry[:client].call_tool(remote, **call_args) }
        error = Translate.result_error(result)
        raise error if error

        Translate.result_content(result)
      rescue Async::TimeoutError
        entry[:poisoned] = true
        raise "mcp timeout after #{timeout}s"
      rescue *transport_errors => e
        entry[:poisoned] = true
        raise "mcp #{name}: #{e.class}: #{e.message}"
      end
```

and simplify `with_timeout` to NOT rescue (let `Async::TimeoutError` reach `call_remote`):

```ruby
      def with_timeout(seconds, &block)
        task = defined?(Async) ? Async::Task.current? : nil
        return yield unless task

        task.with_timeout(seconds) { block.call }
      end
```

(Transport errors poison too — a dead subprocess or dropped socket needs the same reconnect-on-next-use.)

- [ ] **Step 4: Run tests** — file green, full gates green.

- [ ] **Step 5: Commit**

```bash
git add gems/terret-mcp
git commit -m "Poison a timed-out MCP connection and reconnect on next use"
```

---

### Task 8: Live tool-list reconciliation

`notifications/tools/list_changed` → re-list and reconcile. The listener runs in a per-server Async task when a reactor is present; without one, notifications are skipped (documented).

**Files:**
- Modify: `gems/terret-mcp/lib/terret/mcp/service.rb`
- Test: `gems/terret-mcp/test/service_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  def test_list_changed_reconciles_the_registered_tools
    fake = FakeClient.new(tools: [FakeTool.new("a", "", {})])
    ctx = boot(servers: { "s" => { url: "https://x/mcp" } }, factory: ->(*) { fake })
    ctx[:mcp].mount!
    assert_equal ["mcp__s__a"], ctx[:tools].schemas.map { |s| s[:name] }

    # the server's roster changes: a vanishes, b appears
    fake.instance_variable_set(:@tools, [FakeTool.new("b", "changed", {})])
    fake.notify!("notifications/tools/list_changed")

    names = ctx[:tools].schemas.map { |s| s[:name] }
    assert_equal ["mcp__s__b"], names
  end
```

- [ ] **Step 2: Run and verify failure** — `KeyError` (no handler registered) or stale roster.

- [ ] **Step 3: Implement**

In `mount_one`, after `sync_tools`, subscribe and start the listener:

```ruby
        entry[:client].on("notifications/tools/list_changed") do |_params|
          sync_tools(name, entry, cfg)
        end
        start_listener(entry)
```

```ruby
      # manceps' listen is a blocking dispatch loop; give it its own task
      # when a reactor exists. Without one there is nothing to run it on —
      # notifications are skipped (docs/mcp.md documents this).
      def start_listener(entry)
        task = defined?(Async) ? Async::Task.current? : nil
        return unless task

        entry[:listener] = task.async do
          entry[:client].listen
        rescue StandardError => e
          warn "terret-mcp: listener died: #{e.class}: #{e.message}"
        end
      end
```

and in `unmount!`, stop it: `entry[:listener]&.stop` before disconnecting. Note `sync_tools` was written in Task 6 to be re-entrant (it disposes and re-registers) — verify that holds; the FakeClient's `notify!` invokes the handler synchronously in the test, no reactor needed for the reconcile itself.

- [ ] **Step 4: Run tests** — file green (the unmount test must still pass with the listener line), full gates green.

- [ ] **Step 5: Commit**

```bash
git add gems/terret-mcp
git commit -m "Reconcile the tool roster when a server announces changes"
```

---

### Task 9: Resources as prompt sections

**Files:**
- Modify: `gems/terret-mcp/lib/terret/mcp/service.rb`
- Test: `gems/terret-mcp/test/service_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  def test_a_resource_registers_as_a_prompt_section
    fake = FakeClient.new(tools: [])
    def fake.read_resource(uri)
      Struct.new(:text).new("resource body for #{uri}")
    end
    ctx = boot(servers: { "s" => { url: "https://x/mcp" } }, factory: ->(*) { fake })
    ctx[:mcp].mount!

    disposer = ctx[:mcp].register_resource_section("s", "doc://guide", name: "guide", priority: 5)
    assert_includes ctx[:prompt].render, "resource body for doc://guide"

    disposer.call
    refute_includes ctx[:prompt].render, "resource body"
  end
```

- [ ] **Step 2: Run and verify failure** — `NoMethodError: register_resource_section`.

- [ ] **Step 3: Implement**

```ruby
      # Reads the resource once and registers its text as a prompt section
      # (docs/mcp.md); live refresh on resources/updated is deferred until a
      # consumer needs it. Returns the section's disposer.
      def register_resource_section(server, uri, name:, priority: 100)
        entry = @mounted.fetch(server.to_s) { raise ArgumentError, "server #{server.inspect} is not mounted" }
        body = entry[:client].read_resource(uri).text.to_s
        @ctx.with_owner("mcp:#{server}") do
          @ctx[:prompt].register_section(name, priority: priority) { body }
        end
      end
```

(Check what `Prompt#register_section` returns — it returns the effect disposer via `@ctx.effect`; confirm and rely on it. If it doesn't return the disposer, fix `register_section` to return it — one line in terret-core, reported as a deviation with its own test assertion.)

- [ ] **Step 4: Run tests** — file, then full gates, green.

- [ ] **Step 5: Commit**

```bash
git add gems/terret-mcp gems/terret-core
git commit -m "Serve MCP resources as prompt sections on demand"
```

---

### Task 10: The stdio fixture server

A minimal legacy-wire MCP server as a plain Ruby script — the integration substrate. Speaks newline-delimited JSON-RPC on stdio: `initialize` (echoes the client's protocolVersion), `notifications/initialized` (ignored), `tools/list` (two tools), `tools/call` (echo + slow), everything else → method-not-found.

**Files:**
- Create: `gems/terret-mcp/test/fixtures/stdio_server.rb`

- [ ] **Step 1: Write the fixture (no TDD — it IS test infrastructure; Task 11 proves it)**

```ruby
# frozen_string_literal: true

# Minimal legacy-wire (2025-06-18/2025-11-25) MCP stdio server used by
# terret-mcp's integration tests. Newline-delimited JSON-RPC: initialize,
# tools/list (echo + slow), tools/call. Deliberately tiny and dependency-free.

require "json"

$stdout.sync = true

TOOLS = [
  { "name" => "echo", "description" => "Echoes its input",
    "inputSchema" => { "type" => "object", "properties" => { "text" => { "type" => "string" } } } },
  { "name" => "slow", "description" => "Sleeps then answers",
    "inputSchema" => { "type" => "object", "properties" => { "seconds" => { "type" => "number" } } } }
].freeze

def reply(id, result) = $stdout.puts(JSON.generate(jsonrpc: "2.0", id: id, result: result))
def fail_rpc(id, code, msg) = $stdout.puts(JSON.generate(jsonrpc: "2.0", id: id, error: { code: code, message: msg }))

while (line = $stdin.gets)
  msg = JSON.parse(line) rescue next
  id = msg["id"]
  case msg["method"]
  when "initialize"
    reply(id, { "protocolVersion" => msg.dig("params", "protocolVersion"),
                "capabilities" => { "tools" => { "listChanged" => false } },
                "serverInfo" => { "name" => "terret-fixture", "version" => "1.0" } })
  when "notifications/initialized", "notifications/cancelled" then next
  when "ping" then reply(id, {}) if id
  when "tools/list"
    reply(id, { "tools" => TOOLS })
  when "tools/call"
    name = msg.dig("params", "name")
    args = msg.dig("params", "arguments") || {}
    case name
    when "echo"
      reply(id, { "content" => [{ "type" => "text", "text" => "echo: #{args['text']}" }], "isError" => false })
    when "slow"
      sleep(args.fetch("seconds", 3))
      reply(id, { "content" => [{ "type" => "text", "text" => "finally" }], "isError" => false })
    else
      reply(id, { "content" => [{ "type" => "text", "text" => "no such tool #{name}" }], "isError" => true })
    end
  else
    fail_rpc(id, -32_601, "method not found: #{msg['method']}") if id
  end
end
```

- [ ] **Step 2: Sanity-run it by hand**

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | mise exec -- ruby gems/terret-mcp/test/fixtures/stdio_server.rb
```

Expect two JSON lines: the initialize result echoing `2025-11-25`, then the two-tool list.

- [ ] **Step 3: Commit**

```bash
git add gems/terret-mcp
git commit -m "Add a minimal stdio MCP server fixture for integration tests"
```

---

### Task 11: Real-manceps integration and the fiber canary

Prove the whole stack against a real subprocess through real manceps — and pin the emergent fiber-cooperation property manceps itself never tests.

**Files:**
- Create: `gems/terret-mcp/test/integration_test.rb`

- [ ] **Step 1: Write the tests** (skip-guarded like the terret-ws suites)

```ruby
# frozen_string_literal: true

require "minitest/autorun"

MANCEPS_AVAILABLE = begin
  require "manceps"
  require "async"
  true
rescue LoadError
  false
end

require_relative "../lib/terret/mcp" if MANCEPS_AVAILABLE

class MCPIntegrationTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/stdio_server.rb", __dir__)

  def setup
    skip "manceps/async not installed" unless MANCEPS_AVAILABLE
  end

  def boot
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "mcp",      plugin: Terret::MCP::Service,
        config: { servers: { "fix" => { command: RbConfig.ruby, args: [FIXTURE], timeout: 2 } } } }
    ])
    loader.boot!
  end

  def test_discovers_and_calls_tools_on_a_real_stdio_server
    ctx = boot
    Sync do
      ctx[:mcp].mount!
      names = ctx[:tools].schemas.map { |s| s[:name] }.sort
      assert_equal %w[mcp__fix__echo mcp__fix__slow], names

      result = ctx[:tools].execute(
        Terret::Tools::Call.new(id: "t1", name: "mcp__fix__echo", args: { text: "hi" }, session_id: "x"),
        ctx: ctx
      )
      assert_nil result.error
      assert_equal "echo: hi", result.content
    ensure
      ctx[:mcp].unmount!("fix")
    end
  end

  def test_a_slow_server_call_yields_the_reactor_and_times_out_cleanly
    ctx = boot
    Sync do |task|
      ctx[:mcp].mount!
      ticks = 0
      ticker = task.async { 10.times { ticks += 1; sleep 0.1 } }

      result = ctx[:tools].execute(
        Terret::Tools::Call.new(id: "t1", name: "mcp__fix__slow", args: { seconds: 30 }, session_id: "x"),
        ctx: ctx
      )
      assert_match(/mcp timeout after 2s/, result.error)
      ticker.wait
      assert_equal 10, ticks, "the reactor must keep scheduling while MCP IO waits (fiber canary)"

      # poisoned connection heals: next call reconnects and succeeds
      again = ctx[:tools].execute(
        Terret::Tools::Call.new(id: "t2", name: "mcp__fix__echo", args: { text: "back" }, session_id: "x"),
        ctx: ctx
      )
      assert_nil again.error
      assert_equal "echo: back", again.content
    ensure
      ctx[:mcp].unmount!("fix")
    end
  end
end
```

- [ ] **Step 2: Run** — `mise exec -- bundle exec ruby gems/terret-mcp/test/integration_test.rb`. These may pass immediately (Tasks 6-7 shipped the behavior) or surface real seams-vs-manceps mismatches (e.g. `Manceps::Client.new` signature drift, connect semantics). Fix the SERVICE (or report NEEDS_CONTEXT), never weaken the tests. Note: after the timeout test, the fixture subprocess from the poisoned connection may linger sleeping — verify `reconnect!` respawns (manceps `Stdio#open` respawns on reconnect) and that `unmount!` reaps; if orphans persist, kill them in the test's ensure and report it as a manceps gap.
- [ ] **Step 3: Run across seeds 1-3, then both full gates.**
- [ ] **Step 4: Commit**

```bash
git add gems/terret-mcp
git commit -m "Prove the MCP stack against a real subprocess with a fiber canary"
```

---

### Task 12: The M5 acceptance test — a full MCP roster over the socket

Plan §12 M5 accept: "an agent whose entire tool roster arrives from MCP servers works under policy, driven over the socket." Extends the WS protocol harness with an `mcp` row (fake client — the real transport is Task 11's job), an allow list on the agent's fork, and a scripted turn calling one admitted and one denied MCP tool.

**Files:**
- Test: `gems/terret-ws/test/protocol_test.rb`

- [ ] **Step 1: Write the test**

Add to `ProtocolTest` (its `boot` already takes `extra_rows:`; requires terret-mcp via `require_relative "../../terret-mcp/lib/terret/mcp"` at the top of the file, guarded by the existing ASYNC_AVAILABLE constant):

```ruby
  class RosterClient
    Tool = Struct.new(:name, :description, :input_schema)
    Result = Struct.new(:structured_content, keyword_init: true) do
      def error? = false
      def content = []
    end

    def connect = true
    def disconnect = true
    def reconnect! = true
    def on(*) = nil
    def listen = nil
    def tools(*) = [Tool.new("lookup", "", {}), Tool.new("wipe", "", {})]
    def call_tool(name, **args) = Result.new(structured_content: { "did" => name, "args" => args })
  end

  def test_an_all_mcp_roster_works_under_policy_over_the_socket
    script = [
      { text: "Using tools.", tool_calls: [
        Terret::LLM::ToolCall.new(id: "t1", name: "mcp__nexus__lookup", args: { q: "x" }),
        Terret::LLM::ToolCall.new(id: "t2", name: "mcp__nexus__wipe", args: {})
      ] },
      { text: "Done." }
    ]
    ctx = boot(script: script, extra_rows: [
      { id: "mcp", plugin: Terret::MCP::Service,
        config: { servers: { "nexus" => { url: "https://x/mcp" } },
                  client_factory: ->(*) { RosterClient.new } } }
    ])
    ctx[:mcp].mount!
    agent, session = spawn_agent(ctx)
    Terret::Tools::AllowList.install(agent.ctx, ["mcp__nexus__lookup"])

    Sync do |task|
      sock, = connect(ctx, agent, task)
      sock.client_send(type: "subscribe", from_seq: 0)
      sock.client_send(type: "inject", text: "go", wake: true)
      await { sock.event_types.include?("turn/end") }

      results = session.events.select { |e| e.type == "tool/result" }
      lookup = results.find { |e| e.payload[:id] == "t1" }
      wipe   = results.find { |e| e.payload[:id] == "t2" }
      assert_equal({ did: "lookup", args: { q: "x" } }, lookup.payload[:content])
      assert_nil lookup.payload[:error]
      assert_equal "mcp__nexus__wipe is not on the allow list", wipe.payload[:error]
      assert_equal "completed", sock.events.last[:payload][:status]
      sock.client_close
    end
  end
```

Note on the `lookup.payload[:content]` assertion: the structured content `{ "did" => ..., "args" => {...} }` passes through `normalize_payload`, which symbolizes string KEYS — hence the symbol-keyed expectation. If the actual round-trip differs (e.g. nested arg keys), adjust the ASSERTION to the observed normalized form and explain the normalization chain in your report — the invariant that matters is lossless primitives, not the exact key class.

- [ ] **Step 2: Run** — may pass immediately; failures here are integration truth, investigate rather than patch the test. Seeds 1-3.
- [ ] **Step 3: Both full gates.**
- [ ] **Step 4: Commit**

```bash
git add gems/terret-ws
git commit -m "Prove the M5 acceptance: an all-MCP roster under policy over the socket"
```

---

### Task 13: Demo, docs, and the M5 gate

**Files:**
- Create: `examples/mcp_demo.rb`
- Modify: `CLAUDE.md`, `docs/terret-implementation-plan.md`

- [ ] **Step 1: The demo** — `examples/mcp_demo.rb`: boots the harness with the FakeAdapter scripting two calls against the FIXTURE stdio server (real manceps, real subprocess), an allow list admitting only `mcp__fix__echo`, prints the event stream showing one admitted call round-tripping and one denied. Structure it like `examples/ws_demo.rb` (self-contained, `Warning[:experimental] = false`, requires via monorepo paths, runs under `bundle exec`). Keep it under ~80 lines; the fixture path is `gems/terret-mcp/test/fixtures/stdio_server.rb`. Run it and paste its output in your report.

- [ ] **Step 2: Docs**
- `CLAUDE.md`: add the `gems/terret-mcp` bullet ("the MCP client (M5): manceps-backed stdio and streamable-HTTP servers mounted as `mcp__<server>__<tool>` sources behind `ctx[:tools]`, per-server approval, per-call timeouts, the allow list in terret-core; mapping in `docs/mcp.md`"), update "covers M0–M4" → "M0–M5" (tail gains "and the MCP client"), add `bundle exec ruby examples/mcp_demo.rb   # MCP tools from a local stdio fixture` to Commands.
- `docs/terret-implementation-plan.md` §12: M5 → SHIPPED in the M0-M4 voice: what landed (manceps-backed client, both transports with the legacy wire target, namespaced registration with per-server approval metadata, timeout-poison-reconnect policy, list_changed reconciliation, resources as prompt sections, the allow list + caller-ctx waterfall dispatch in core, kernel disposer hygiene) and what deferred (approval machinery M6; the 2026-07-28 stateless wire until deployment exists).
- `docs/terret-implementation-plan.md` §14: mark Codex-debt item 1 (disposer leak) paid; add one line noting the modern-MCP-wire deferral and that fiber-safety of manceps is pinned by our canary, not upstream contract.
- Status line (line 6): "M0–M5 are shipped".

- [ ] **Step 3: The full gate**

```bash
mise exec -- rake test && mise exec -- bundle exec rake test
mise exec -- bundle exec rake events:catalog && git diff --exit-code docs/events.md
```

- [ ] **Step 4: Commit**

```bash
git add examples/mcp_demo.rb CLAUDE.md docs/terret-implementation-plan.md
git commit -m "Mark M5 shipped with a live MCP demo"
```

---

## Acceptance (M5, from plan §12)

- [ ] stdio and streamable-HTTP servers mount as namespaced tool sources (Tasks 6, 11 — HTTP path exercised via fake client + manceps' own webmock-tested transport; stdio proven live).
- [ ] Per-server policy (approval metadata) and strict mode (Task 6).
- [ ] Declarative per-agent allow list with wildcards (Task 3, proven per-agent by Task 2's dispatch fix).
- [ ] An agent whose entire tool roster arrives from MCP servers works under policy, driven over the socket (Task 12).
- [ ] Both gates green, events catalog current, no invariant relaxed.
