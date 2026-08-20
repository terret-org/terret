# The Hames Kernel (v1)

Hames is Terret's plugin kernel: services in a context, typed events with
four dispatch modes, reversible effects, and dependency-driven boot. It
knows nothing about LLMs, agents, sessions, or tools by design. Everything
in this primer is true of a kernel you could mount a build system, a job
runner, or a document pipeline on; Terret is one application composed out
of it, and this document describes the machine underneath without
reaching for a single word from that application's vocabulary.

The whole of it is four files: `context.rb`, `loader.rb`, `events.rb`,
and `schema.rb`, plus zero runtime dependencies beyond stdlib. The kernel
holds itself to that line by design. A dependency in the kernel is a
dependency in every application built on it, so `Hames::Schema` is
hand-written stdlib where a larger project would reach for dry-schema
(§5), and the event bus is a Hash of arrays where it might have been a
gem.

## 1. Context and services

A `Context` is a repository of services and an event bus. A **service** is
any object that responds to `apply(ctx)`; the ergonomic form is a subclass
of `Hames::Service` that names the key it claims and lists what it needs:

```ruby
class Store < Hames::Service
  service_key :store
  def start(_ctx) = (@data = [])
  def push(x) = @data << x
  def data = @data
end

class Feeder < Hames::Service
  inject :store
  def start(ctx) = ctx[:store].push(config[:value])
end
```

`service_key` names the one key this service registers under.
`Service#apply` registers the instance at that key and then calls `start`.
A subclass overrides `start`, not `apply`; everything after registration
belongs there. `inject` names the keys this service reads before
it can run. A service reaches another by its key, either as `ctx[:store]`
or, because `Context#method_missing` resolves a known key, as `ctx.store`.

**Boot order is derived, not declared.** The loader mounts in dependency
order computed from each service's `inject` list, so the order rows are
written in does not matter:

```ruby
loader = Hames::Loader.new
loader.layer([
  { id: "feeder", plugin: Feeder, config: { value: 42 } },
  { id: "store",  plugin: Store }
])
ctx = loader.boot!
ctx[:store].data # => [42]
```

`Feeder` is listed first and mounts second, because `boot!` mounts only
rows whose injected keys are already present, in repeated passes:
everything satisfiable this pass mounts, and the next pass sees what those
mounts registered. When a pass makes no progress and rows remain, that is
a missing provider or a dependency cycle, and the loader reports it as
one immediately. Without that check, the same problem would surface later
as a service resolving to `nil`:

```ruby
loader.layer([{ id: "feeder", plugin: Feeder }]) # no store anywhere
loader.boot! # raises Hames::CycleError: "cannot mount: feeder (needs store)"
```

The message names the row and the unmet need, because a boot failure that
cannot say which of thirty rows is stuck is one nobody can act on.
Declaring `inject` accurately matters more than it looks: it is the only
input to mount ordering, and a service that reads `ctx[:store]` in `start`
without injecting `:store` is a race waiting for a row reorder.

**A key has exactly one provider.** `register_service` refuses a second
claim on a key that is already taken:

```ruby
ctx.register_service(:store, first)
ctx.register_service(:store, second) # raises Hames::ContractError
```

`Service#apply` registers through that same method, so two rows claiming
the same `service_key` collide at boot with a `ContractError` naming the
key. That refusal makes a **sole-provider seam** a real guarantee: "what
is the store in this composition" has one answer for the whole context,
decided by which row mounts, and a second row cannot quietly win.
(`docs/cookbook/adding-a-provider.md` walks through
building a second implementation of such a seam, where the point is that
only one is ever mounted at a time.)

Resolution walks the parent chain: `ctx[:key]` returns this context's own
provider, then its parent's, and raises `Hames::ServiceMissingError`, a
message naming `ctx[:key]`, only when no context in the chain has one. The
parent chain is §3's forked scopes; a bare context has no parent and the
walk is a single lookup.

## 2. Plugins as reversible effects

Everything a plugin installs (a service registration, an event listener,
a prompt section an application defines on top of the kernel) installs
through `ctx.effect`, and `effect` hands back a **disposer** that undoes
exactly that one installation. Registration is reversible, and that one
mechanism is what the whole teardown story rests on.

```ruby
disposer = ctx.effect { -> { some_teardown } }
# ... later ...
disposer.call # runs some_teardown once
```

The block runs immediately and must return a disposer callable (or `nil`
for nothing to undo). The disposer that comes back is **idempotent and
self-removing**: calling it runs the teardown once and drops its own entry
from the context's effect list, so calling it twice is a no-op and a
long-lived context does not pin every registration it has ever disposed
(nor whatever that registration's closure captured).

`register_service` and `on` (§4) are both built on `effect`, so they are
reversible for free: registering a service records a disposer that
deletes the key, and registering a listener records one that removes it
from its bucket:

```ruby
hits = 0
ctx.with_owner("p1") { ctx.on("e") { hits += 1 } }
ctx.emit("e")            # hits => 1
ctx.dispose_owner!("p1")
ctx.emit("e")            # hits stays 1 — the listener is gone
```

**Effects are recorded against an owner.** `with_owner(id)` sets the id
that every `effect` inside the block is attributed to; the loader wraps
each mount in `with_owner(row.id)`, so every registration a service makes
during `start` belongs to that row. That ownership is what makes two
teardown operations possible:

- `dispose_owner!(id)` disposes everything one owner installed, in **reverse
  registration order**, and leaves every other owner's effects alone. This
  is what `Loader#unload!` calls to remove one row.
- `dispose!` disposes the whole context, also in reverse order. This is
  what a forked scope (§3) calls when it ends.

A consumer registered after the thing it depends on comes down before
it, so reverse order preserves the same dependency discipline the loader
applies to mount order, just run backwards.

**Unloading a row is exception-safe in both directions.** The M8
hardening made that guarantee explicit:

```ruby
def unload!(id)
  plugin = @mounted.fetch(id) { raise ArgumentError, "no mounted plugin #{id}" }
  begin
    plugin.stop(ctx) if plugin.respond_to?(:stop)
  ensure
    ctx.dispose_owner!(id)
  end
  @mounted.delete(id)
end
```

Two properties fall out of that shape. A `stop` hook that raises **still**
has its owner's effects disposed, because the `ensure` runs
`dispose_owner!` regardless, so a wedged teardown cannot strand a service
registration or a listener live with nothing left to remove it. The
`@mounted` entry is dropped only after a clean `stop`, so a `stop` that
raised keeps the row unloadable. A retry re-runs `stop` and finishes the
teardown, instead of the row vanishing behind a misleading "no mounted
plugin". The kernel's own tests pin both, including a flaky `stop` that
raises once and succeeds on retry.

Mounting has the mirror-image guarantee. If a service's `start` registers
something and *then* raises, whatever it registered before the raise is
owned by that row, but the row never lands in `@mounted`, so no
`unload!` and no shutdown could ever find those registrations to dispose
them. The
loader closes that by rolling the owner's effects back inside the mount's
own rescue before re-raising, so **a failed mount leaves nothing live**:

```ruby
class Exploder < Hames::Service
  service_key :exploder
  def start(ctx)
    ctx.on("boom") { }   # a listener, registered as an owner effect
    raise "start exploded"
  end
end

loader.layer([{ id: "exploder", plugin: Exploder }])
loader.boot! # raises "start exploded"
# afterward: ctx.service?(:exploder) is false, the listener is gone,
# and "exploder" is not in loader.mounted
```

A disposer that itself raises during that rollback is warned. That keeps
it from masking the failure that started the rollback: the exception that
gets out is always the one from `start`, never a secondary fault from the
cleanup itself.

## 3. Forked scopes

`ctx.fork` returns a child context whose parent is `ctx`. A child **sees**
its parent's services and listeners (service resolution walks up the
chain, per §1, and event dispatch runs the parent's listeners before the
child's own), but its own registrations dispose independently:

```ruby
ctx.on("e") { seen << :parent }
ctx.register_service(:store, { k: 1 })

child = ctx.fork
child.on("e") { seen << :child }
child.emit("e")   # => runs parent then child: [:parent, :child]
child[:store]     # => { k: 1 } — inherited from the parent

child.dispose!    # tears down only the child's own effects
ctx.emit("e")     # => [:parent] — the child's listener is gone,
                  #    the parent's is untouched
```

This is the isolation primitive an application uses to give one unit of
work its own registrations that vanish when the work ends, without
disturbing the shared services it inherited. Everything the child installs
is recorded on the child, so `child.dispose!` collects all of it and
nothing of the parent's. Dispatch is **parent-first**: a child listener
always runs after every parent listener for the same event. A child that
claims a key the parent already provides gets a fresh registration on the
child that shadows the parent for the child's own lookups; the parent's
provider stays untouched and reappears the moment the child is disposed.

## 4. Events and the four dispatch modes

Every event is **declared once**, with a dispatch mode, before anyone
listens on it or dispatches it. The bus refuses an undeclared event on both
sides, and refuses a declared event dispatched through the wrong mode:

```ruby
Hames.event "req", mode: :waterfall
ctx.on("nope") { }        # raises ContractError: undeclared event
ctx.emit("nope")          # raises ContractError: undeclared event
ctx.emit("req")           # raises ContractError: req is :waterfall, dispatched as :emit
```

Re-declaring an event with a conflicting mode raises too, so a mode is
fixed the first time it is declared and cannot be quietly changed out from
under existing listeners. This is the Ruby stand-in for a statically typed
event contract: the mode is part of an event's public API, and the runtime
holds the line the type system would in another language.

The four modes differ in what they do with listeners and return values:

**`:emit`** is fire-and-forget, in registration order, with no return
value. Listener failures are **isolated**: a raising listener is warned
and the rest still run.

```ruby
Hames.event "boom", mode: :emit
ctx.on("boom") { |_| raise "listener bug" }
ctx.on("boom") { |x| seen << x }
ctx.emit("boom", 1) # does not raise; seen => [1]; the bug is warned
```

The isolation is deliberate and specific to `:emit`. By the time `:emit`
listeners run, the producer's fact is already committed (in Terret, a
durable append emits *after* the store write), so a consumer bug must not
un-happen it. The other three modes raise through, because their results
are load-bearing.

**`:waterfall`** is around-middleware. Each listener receives the
arguments plus a `next_` callable. Calling `next_.(payload)` delegates to
the next listener (optionally rewriting the payload); returning
**without** calling `next_` short-circuits the rest of the chain. When
every listener delegates, the innermost `next_` returns the final
payload, or calls a base block if one was given to `waterfall`:

```ruby
Hames.event "req", mode: :waterfall
ctx.on("req") { |v, next_| next_.(v + "-a") }
ctx.on("req") { |v, next_| next_.(v + "-b") }
ctx.waterfall("req", "x")            # => "x-a-b"

# short-circuit: a listener that owns the decision skips downstream and base
ctx.on("veto") { |_v, _next_| :vetoed }   # no next_ call
ctx.on("veto") { |v, next_| next_.(v) }   # never reached
ctx.waterfall("veto", "x") { :base }      # => :vetoed
```

This is the mode for a pipeline that transforms or vetoes a value. An
application layers validation, rewriting, and access checks on one
event, and each listener decides whether to pass the value along.

**`:parallel`** means every listener observes the event, and dispatch
completes only when all of them have. With no reactor mounted, this runs
them in sequence but preserves that completion contract; under an async
runtime it maps onto a barrier. No return value.

```ruby
Hames.event "fan", mode: :parallel
ctx.on("fan") { hits << :a }
ctx.on("fan") { hits << :b }
ctx.parallel("fan") # both have run by the time this returns
```

**`:serial`** is ordered, single-decision. Listeners run in order and the
**first non-nil return value wins and stops dispatch**:

```ruby
Hames.event "decide", mode: :serial
ctx.on("decide") { |x| order << 1; nil }      # abstains
ctx.on("decide") { |x| order << 2; x + 1 }    # decides
ctx.on("decide") { |x| order << 3; x + 100 }  # never runs
ctx.serial("decide", 41) # => 42; order => [1, 2]
```

This is the mode for an ordered veto point where the first listener with an
opinion settles it and later ones are not consulted.

Listeners register with `on(name, prepend: false)`; `prepend: true` puts a
listener at the front of its bucket instead of the back, and dispatch still
runs parent-context listeners before the forking context's (§3). Because
`on` is built on `effect`, a listener is a reversible registration owned by
whoever registered it (§2).

**The catalog is generated from the declarations.** `Hames.catalog`
returns every declared event as `[name, mode, durable, doc]`, sorted by
name; an application's rake task renders that to a Markdown table (in
Terret, `docs/events.md` via `rake events:catalog`), and CI diffs the
committed file against a fresh render. Because the mode lives in the
declaration and the doc is generated from it, changing a mode shows up in
review as a diff to that file: dispatch mode is public contract. Terret's
own declarations are the worked example: one `Hames.event` call per line,
mode and durability explicit:

```ruby
# from Terret.declare_events!
Hames.event "tools/pre_execute", mode: :waterfall,
            doc: "validate, veto, or rewrite a call"
Hames.event "turn/end", mode: :emit, durable: true,
            doc: "turn closed with status"
```

`durable:` is a flag the kernel stores and reports but does not act on.
It is there for an application that keeps a subset of its events in a
log, and `Hames.catalog` surfaces it. The kernel itself declares no
events at all and stays application-agnostic (§6).

## 5. Config rows and reconfigure

The loader's unit is the **row**, a `Data.define` of four fields:

```ruby
Hames::Row = Data.define(:id, :plugin, :config, :disabled)
```

`id` is the row's stable name: what a later layer patches, what a
teardown addresses. `plugin` is the service class (or a functional plugin
object). `config` is the hash handed to the plugin wholesale. `disabled:
true` keeps a row present in the resolved tree but unmounted, which is
how a base composition can ship a row that a given profile simply never
turns on.

Rows arrive in **layers**, and a later layer whose row shares an id with
an earlier one **replaces that row's config wholesale, never a deep
merge**:

```ruby
loader.layer([{ id: "store", plugin: Store },
              { id: "feeder", plugin: Feeder, config: { value: 1, extra: true } }])
loader.layer([{ id: "feeder", config: { value: 99 } }]) # a patch
ctx = loader.boot!
ctx[:store].data  # => [99]
# the patched row's config is { value: 99 } — :extra is gone, not merged
```

A patch may also swap the `plugin:` on an existing id while keeping the
rest of the row, or leave `plugin:` unstated to keep the class and
replace only the config. The rule is uniform: a field a patch mentions is
replaced, a field it omits is inherited from the row it patches. Wholesale
replacement is a deliberate choice with a stated cost. It makes
*unsetting* a key expressible (there is no YAML for "and remove this
key" under a deep merge), and it makes one layer solely responsible for
what a service receives. `docs/composition.md` §4 argues it at length for
the application layer that sits on top of this.

**Reconfigure is a hot config swap, and it is atomic.**
`Loader#reconfigure!(id, config)` replaces the row's config wholesale (the
same discipline as layering), swaps the mounted service's config object,
and invokes the service's `reconfigure` hook:

```ruby
class Knobbed < Hames::Service
  service_key :knobbed
  attr_reader :knob
  def start(_ctx) = @knob = config[:knob]
  def reconfigure(config) = @knob = config[:knob]
end

loader.reconfigure!("knobbed", { knob: 2 })
ctx[:knobbed].knob    # => 2
ctx[:knobbed].config  # => { knob: 2 } — wholesale, any prior key gone
```

The hook runs under `with_owner(id)`, so anything it registers is owned
by the row (§2). Three guarantees follow:

- **A raising hook rolls back.** If `reconfigure` raises, the loader
  restores the row and the service's config to exactly what they were
  before the call and re-raises. The swap is atomic: there is no
  split-brain state where the config changed but the hook that was
  supposed to act on it did not.
- **`config/updated` is emitted only when the application declares it.**
  The loader emits `config/updated` (id, config) after a successful hook
  *iff* `Hames.declared?("config/updated")`. The kernel declares no such
  event itself, so an application that wants the notification declares
  it, and one that does not gets a reconfigure that simply does not
  emit. Neither raises.
- **A service with no hook warns.** The base `Service#reconfigure` warns
  that the class does not support hot-reconfigure and that the row needs
  a remount to take the change. A service running on stale knobs should
  say so. A service that *does* read its knobs live overrides
  `reconfigure` with a no-op and says why. Terret's summarizer and file
  tools both do this, because they read config per call.

## 6. `Hames::Schema`

`Hames::Schema` is the kernel's own config validator: a plain description of
a service's config keys, plus the code that checks a config hash against it
and reports what does not fit. It is pure stdlib, because the
zero-dependency rule (§intro) forbids reaching for dry-schema. A service
declares one with the `config_schema` class method:

```ruby
class Sandbox < Hames::Service
  service_key :sandbox
  config_schema image:   { type: String, required: true, doc: "container image" },
                network: { type: String, enum: %w[none bridge host], default: "none",
                           doc: "docker --network mode" },
                jobs:    { type: Integer, default: 4, doc: "parallel jobs" }
end
```

Each key carries a `type:` (a Class, or an array of Classes for a union:
`[TrueClass, FalseClass]` is how a boolean is spelled, since Ruby has no
Boolean class), whether it is `required:`, an optional `enum:` of legal
values, a `default:`, and a `doc:` string. `config_schema` **stores the
schema on the class** and registers it in a process-wide table
(`Hames::Schema.declared`) that a catalog generator walks.

Three semantics govern how the DSL behaves, each pinned by a kernel test:

- **The argument distinguishes a read from a declaration.**
  `config_schema` with no argument reads the stored schema (returning `nil`
  for a class that never declared one); `config_schema({})` declares an
  *empty* schema, which is a positive statement that the service takes no
  config; `config_schema(key: {...})` declares a populated one. The empty
  form matters downstream: a validator can tell "audited, reads no config"
  from "never declared a schema".
- **It is inherited.** A subclass that does not redeclare validates
  exactly like its parent: `SandboxVariant < Sandbox` returns the *same*
  schema object. This mirrors how `service_key` and `inject` inherit
  (§1), so a test double or a provider variant mounts and validates like
  the class it extends.
- **A functional plugin can carry one too.** A plugin that is only an
  object responding to `apply(ctx)`, not a `Hames::Service`, can
  `extend Hames::Schema::DSL` and be schema'd identically.

`validate(config, subject:, redact:)` checks a hash without mutating it and
returns a `Result` with `errors` and `warnings` (and `ok?`). The rules err
consistently toward not failing a boot over drift:

```ruby
schema = Sandbox.config_schema

schema.validate({ image: "ruby:slim", network: "none", jobs: 8 }).ok?  # => true

# a missing required key is an error, named by subject and key
schema.validate({ network: "none" }, subject: "sandbox").errors
# => ["sandbox: image is required but was not set"]

# a wrong type names the key and the expected type ("an Integer", not "a Integer")
schema.validate({ image: "x", jobs: "lots" }, subject: "sandbox").errors
# => [%q(sandbox: jobs must be an Integer, got "lots")]

# an out-of-enum value names the allowed set
schema.validate({ image: "x", network: "lan" }, subject: "sandbox").errors
# => [%q(sandbox: network must be one of "none", "bridge", "host", got "lan")]

# an EXTRA key WARNS rather than fails — config rows grow
r = schema.validate({ image: "x", surprise: 1 }, subject: "sandbox")
r.ok?       # => true
r.warnings  # => ["sandbox: surprise is not a known config key"]
```

Two behaviors are easy to assume wrong. **A default does not merge into
the config.** It documents what a service reads for a missing key at read
time; validation of a config that omits a defaulted key passes *without*
the schema injecting the default into the hash it was handed. **A key
that is absent or present-but-nil both count as unset**: a required unset
key is an error, a non-required one is fine (its default applies), so a
config value that resolved to `nil`, an environment variable that was not
set in the application layer, is an ordinary state.

`redact:` governs whether a rejected value's *content* may appear in the
message. It stays `false` for programmatic callers, whose config is plain
and whose messages are more useful for naming the bad value; a caller
validating already-materialized config (where a value may be a secret)
passes `true`, and the message then names the value's *type* only (as in
"must be an Integer, got a String"), never its content. For an enum
violation it says "the configured value is not" in the allowed set
instead of echoing it. The kernel test pins that a canary secret never
reaches a redacted message.

The declarations feed two consumers in an application built on the kernel:
a config validator that checks a composition without booting it, and a
catalog generator that renders every declared schema to a document the way
`Hames.catalog` renders events. In Terret those are `trt doctor` and
`docs/config-catalog.md`; `docs/composition.md` §9 is the normative account
of both.

## What hames deliberately is not

Hames is not an agent framework, and nothing above needed the word. It
has no knowledge of LLMs, models, sessions, tools, or prompts. Those
belong to Terret, defined in the layer above and mounted as services and
events like anything else. The kernel's entire vocabulary is *service*,
*context*, *effect*, *event*, *row*, *schema*, and it is reusable for any
plugin-composed application that wants dependency-ordered boot, reversible
registration, a typed event bus, and hot reconfigure.

A dependency-injection container resolves its whole graph eagerly, at
construction time. Hames resolves one key at a time, lazily, the moment
`ctx[:key]` is called (§1). The event bus is not a general pub/sub
system: every event is declared and mode-checked before anyone can listen
on it or dispatch it. Config layering has exactly one behavior: a later
row replaces an earlier one's config wholesale, never a deep merge. It
stops there, and the argument for *why* wholesale belongs to the
application (`docs/composition.md` §4).

Where the kernel could have grown a dependency to do a job more
comfortably (a schema library, an async primitive, a richer bus), it did
the job in stdlib instead. A kernel that reusable applications embed
cannot spend their dependency budget for them.

For building on it, see `docs/cookbook/`: `adding-a-tool.md`,
`adding-a-provider.md`, and `adding-a-bundle.md` each start from the
primitives here and end at a running piece of Terret.
