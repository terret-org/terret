# Composing a Terret (v1)

Plan §7 is four bullets. This is those four bullets made normative, and it
is the contract `gems/terret` is built against when it stops being a
placeholder holding the name.

Everything in Terret is a plugin, which is a claim that only means
something if there is a way to say *which* plugins, in what order, with
what config, without editing Ruby. That is what this document describes:
bundles ship rows, profiles stack bundles, patches adjust rows, and
`Terret.boot` hands the result to the Hames loader. The model is a direct
port of dsh's (plan §2.2), YAML-native.

## 1. The row is the unit

A running Terret is an ordered list of config rows, and the loader mounts
them in dependency order derived from each service's `inject` declarations
(CLAUDE.md). A row is four fields:

```yaml
- id: sandbox                        # unique; what a patch targets
  plugin: Terret::Sandbox::Docker    # the service class that mounts it
  config: { network: none }          # handed to the service wholesale
  disabled: false                    # present but not mounted
```

`id` is the addressing scheme for everything below — a patch names a row
by id, `dump-config` reports by id, `doctor` reports by id. `plugin` names
the Ruby class; a row whose constant does not resolve is exactly the kind
of thing `doctor` is for (§9), rather than something to discover halfway
through a boot. `disabled: true` keeps a row visible in the resolved tree
while leaving it unmounted, which is how the base bundle can ship an
approvals row that an autonomous profile simply never turns on (§6).

Everything else in this document is a way of producing that list.

## 2. Bundles

A **bundle** is a gem that ships `config/bundle.yml`, an ordered list of
rows. It does not have to contain the code those rows mount — it has to
make that code available, which for a Ruby gem means **depending on the
gems the rows name**. That distinction is what lets `terret-base` (§6)
live inside the meta-gem while mounting services from six other gems: it
ships the rows and declares the dependencies, and the classes resolve
because Bundler put them on the load path. A bundle declares itself in its
gemspec:

```ruby
s.metadata = { "terret" => "config/bundle.yml" }
```

The value is the path on its own because **RubyGems validates every
metadata value as a String** — a gemspec carrying a nested hash there does
not build at all (`metadata['terret'] value must be a String`). Discovery
still accepts the richer forms on read, both a real Hash and a YAML
mapping inside the string, so a gem that grows a second key later does not
break; but the path alone is what a bundle should ship.

That single line is the whole registration mechanism, and choosing gemspec
metadata over a registry file or a plugin directory is deliberate: `gem
install` is already the install step, `Gemfile` is already the manifest,
and Bundler already resolves versions. Discovery walks every gemspec
`Gem::Specification` knows about — under Bundler that is the bundle, and
outside it every gem installed on the machine, loaded or not — reads the
key, and parses the file it points at. A third-party gem becomes
discoverable by shipping normally — nothing to register, nothing to
symlink, no directory to drop a file into. It is the
port of dsh's `package.json` `dsh` field (plan §5), and it is the mechanism
`docs/cookbook/adding-a-bundle.md` walks end to end.

Discovery quarantines what it finds. A gem whose `bundle.yml` does not
parse, or whose metadata points outside its own gem directory, becomes a
broken entry that only a profile *naming* it ever sees — one bad gem in
the Gemfile must not take out every profile on the machine.

The bundle file itself is that ordered list of rows, optionally wrapped in
a mapping that also carries a name and its requires:

```yaml
name: terret-base                 # what dump-config calls this layer
requires:                         # loaded before any row's constant resolves
  - terret/store/sqlite
  - terret/exec
rows:
  - id: session_store
    plugin: Terret::Store::SQLite
```

`requires:` is the working half of "it has to make that code available".
Depending on the gem is what puts it on the load path; **a load path is
not a `require`**, and `Object.const_get("Terret::Store::SQLite")` fails
on a gem nobody has loaded. So a bundle lists the files its rows' classes
live in, and boot requires them before resolving a single constant. A
profile's `plugins:` (§3) does the same job for code that is not a bundle
at all.

A profile names bundles by **gem name**. A name that discovery did not
find fails closed, listing what *was* discovered — the failure mode here
is almost always a gem that is not installed in this environment, or not
in this Gemfile, or one that ships no `terret` metadata at all, and
printing the found set turns a five-minute confusion into a five-second
one.

## 3. Profiles

A **profile** is a named composition living in Terret home:

```
~/.terret/
├── patch.yml                      # applies to every profile (§4)
└── profiles/
    └── headless/
        ├── profile.yml
        └── patch.yml
```

```yaml
# ~/.terret/profiles/headless/profile.yml
bundles:
  - terret          # terret-base, always layer one
  - terret-fortune  # a third-party bundle
plugins:
  - terret/fortune  # out-of-tree requires, loaded before rows resolve
settings:
  sandbox:
    image: terret/sandbox:latest
  model:
    main: anthropic/claude-opus-4.5
```

`bundles:` is the stack, in order. `plugins:` names requires for code that
is not a bundle. `settings:` is a plain map with no schema of its own —
its only job is to be the target of `!setting` references (§5), so that a
value used by three rows is written once.

`patch.yml` sits beside `profile.yml` and applies after every bundle in
the stack (§4).

**`TERRET_HOME` overrides `~/.terret`** wholesale. That is what makes the
whole layer stack testable — every composition test points it at a tmpdir
— and what lets a deployment ship a home directory as an artifact rather
than as instructions for populating a user's dotfiles.

## 4. Layer order and patches

Four layers, applied in this order:

1. every bundle in the profile's `bundles:` list, in listed order
2. the profile's own `patch.yml`
3. `~/.terret/patch.yml` — the home-level patch, applying to every profile
4. `--patch FILE` overlays on the command line, in the order given

Later layers win. The ordering reads outward from shared to specific:
bundles are what a gem author decided, the profile patch is what this
composition decided, the home patch is what this machine decided, and a
`--patch` overlay is what this invocation decided.

A patch file is a list of rows:

```yaml
# ~/.terret/profiles/headless/patch.yml
rows:
  - id: sandbox
    config: { image: "terret/sandbox:latest", network: none }

  - id: llm
    config: { model: !setting model.main }

  - id: audit
    plugin: Acme::Audit
    after: tools
    config: { sink: !env AUDIT_URL }
```

**A patch targeting an existing id replaces that row's config wholesale.
It never deep-merges.** This is the same rule the kernel's reconfigure
contract already follows (CLAUDE.md: "Config layering replaces a row's
config wholesale. It is never a deep merge"), and the reason is worth
stating once rather than re-arguing per row. Deep merging makes *unsetting*
a key inexpressible — there is no YAML for "and remove `network`" — and it
makes the effective value of any key a function of the entire stack, so
reading one file never tells you what a service will get. Wholesale
replacement means the last layer that mentions a row is the answer, whole.

The `llm` row above is that rule biting, and it is left in rather than
tidied away: the base bundle's row carries an `api_key: !env …` alongside
its model, and a patch that mentions only `model:` **drops the key**. The
adapter then boots without one. This is the mode of failure to expect from
wholesale replacement, and the cure is to restate the whole config —
`dump-config` (§10) is there precisely to show what a row currently holds
before a patch replaces it.

A patch may also swap `plugin:` on an existing id, which is the mechanism
docs/exec.md §4 leans on: one row swaps `Terret::Exec::SandboxNone` for
`Terret::Sandbox::Docker` and every tool built on `ctx[:fs]` and
`ctx[:subprocess]` moves into the container, tool code untouched.

Swapping `plugin:` while saying nothing about `config:` **forwards the old
config to the new class**, whatever it held — an `!env`-resolved key, a
workspace list, a path — because replacement is per field and a patch that
mentions one field replaces one field. That is usually what you want and
occasionally very much not; `dump-config` reports the plugin and the config
layer separately (§10) so a row inheriting a config from a layer that never
meant it for this class is visible. A swap that should inherit nothing has
to say `config: {}` out loud.

A row with an id that does not exist yet is an **insertion**, and it must
say where it goes with `before:` or `after:` naming an existing id. An
anchor naming an id that is not in the stack fails closed, naming the id,
rather than appending the row somewhere plausible.

**What position controls is the tree, not the mount order and not listener
order.** These anchors decide where a row sits in the resolved list — which
is what `dump-config` prints, what a later patch reads, and what a human
reviews. The loader then mounts in dependency order derived from `inject`
(§1), so a row's position here does not decide when it mounts; and because
listeners register as their row mounts, it does not decide the order of two
`tools/pre_execute` listeners either. A profile that needs an audit
listener to run *in front of* the thing it audits cannot express that with
`before:` today. Deterministic listener ordering is a known gap rather than
a guarantee this format makes.

## 5. Tagged scalars

Config is data first. Three tags make it dynamic without making it code:

```yaml
config:
  api_key: !env OPENROUTER_API_KEY   # ENV fetch; nil when unset
  image:   !setting sandbox.image    # the profile's settings map
  weird:   !ruby "Etc.nprocessors"   # refused unless --allow-config-ruby
```

`!env` resolves at mount time and answers nil when the variable is unset —
nil rather than raising, because "no key configured" is a state a service
should be allowed to have an opinion about (the adapter that wants one
raises a better error than YAML can), and because `doctor` and
`dump-config` need to be runnable on a machine that holds no secrets at
all.

`!setting` takes a dotted path into the profile's `settings:` map and
**fails closed on a missing path**. The asymmetry with `!env` is
intentional: an unset environment variable is an ordinary deployment
state, while a `!setting` pointing at nothing is a typo in a file the
profile author controls.

`!ruby` is refused unless `--allow-config-ruby` is passed, and evaluated
in a clean binding when it is. The flag is the consent — config that can
execute arbitrary Ruby is code with a YAML extension, and a profile
downloaded from anywhere should not be able to run without the operator
having said so out loud.

How those three tags are actually read matters, because the obvious
implementation does not work. `YAML.safe_load` **drops a local tag
silently**: `permitted_classes:` gates Ruby-object tags like
`!ruby/object:Foo`, not application tags like `!env`, so a document loaded
that way comes back with the tag gone and the bare scalar in its place —
`!env OPENROUTER_API_KEY` would resolve to the *string*
`"OPENROUTER_API_KEY"` and boot a service with a literal nonsense key. So
resolution is explicit: `Psych.parse` to an AST, then a visitor that walks
it and resolves `!env`, `!setting`, and `!ruby` nodes by tag, refusing any
other tag it meets. Separately and still true: `YAML.load` never appears
anywhere in the path, so an untrusted profile cannot instantiate arbitrary
Ruby objects at parse time regardless of what the visitor does afterward.

## 6. `terret-base`, and secure by default

`terret-base` is a bundle **inside the meta-gem**
(`gems/terret/config/bundle.yml`), not a gem of its own — plan §5's layout
lists no such gem and plan §7 puts it inside `terret`. It is layer one of
every profile, and its rows are the answer to "what is a Terret":

| Row | Plugin | Note |
|---|---|---|
| `session_store` | `Terret::Store::SQLite` | durable log, WAL |
| `sessions`, `prompt`, `tools`, `loop` | terret-core | the harness itself |
| `llm` | `Terret::LLM::Service` | the role map — `main:` and whatever else a profile points somewhere |
| `openrouter` | `Terret::OpenRouter::Plugin` | registers the adapter under the provider name `openrouter`, `!env`-keyed |
| `fs` | `Terret::Exec::FS` | **`workspace:` — an empty or unconfigured list denies every fs op** |
| subprocess / shell / terminals / jobs | terret-exec | the rest of the execution world |
| `sandbox` | `Terret::Sandbox::Docker` | **`network: none`** |
| std tools | terret-tools-std | the CC-named roster |
| `subagents`, `std_task` | terret-core, terret-tools-std | `Task` delegation and the agents it spawns |
| `redactor` | terret-core | `tools/post_execute` + the append scrubber |
| `allow_list` | `Terret::Tools::AllowListFloor` | the deny-by-default floor: a thin service over the `AllowList` module, so the floor is a row like everything else |
| `approvals` | terret-core | `disabled: true` — opt-in per M6 |

The model seam is **two rows, not one**, and the split is not incidental.
`Terret::LLM::Service` is the seam — it holds the role map and it is what
`ctx.llm` resolves to. An adapter is not a service and mounts nothing;
`Terret::OpenRouter::Plugin` injects `:llm` and registers an
`OpenRouter::Adapter` into it under the provider name `openrouter`, which
is the `openrouter/` half of a role like `main: openrouter/anthropic/claude-sonnet-4.5`.
Swapping providers is therefore a second row, not a rewrite of the first —
and taking a profile offline is `disabled: true` on the adapter row plus a
role pointing somewhere else.

The sandbox row is the one to read twice. **The default is `docker` with
`network: none`** (plan §13, docs/security.md), so the trusted world is
something a profile opts into rather than something it forgets to opt out
of. The shipped `headless` profile template makes that opt-in look like
what it is:

```yaml
# ~/.terret/profiles/headless/patch.yml
rows:
  # ------------------------------------------------------------------
  # UNCOMMENT TO RUN TOOLS DIRECTLY ON THIS HOST, UNSANDBOXED.
  # Every Bash command, every spawned process, and every terminal this
  # agent opens runs as you, on your machine, with your network. A
  # prompt-injected instruction that reaches a tool call has nothing
  # between it and the host but the allow list. See docs/security.md.
  # ------------------------------------------------------------------
  # - id: sandbox
  #   plugin: Terret::Exec::SandboxNone
  #   config: {}
```

A comment block is not a security control. What it is, is the difference
between a decision made and a default inherited, and plan §13 asks for
exactly that: `none` requires explicit per-profile opt-in. The template is
where the explicitness lives.

The `fs` row deserves the same second read for the opposite reason: its
`workspace:` list is what every filesystem tool is contained to, and an
empty or unconfigured list **denies every fs operation** rather than
permitting them (docs/exec.md §3, docs/security.md). There is no
ungranted-but-permitted state, so a profile that forgets the row gets an
agent that cannot read a file — the safe failure, and a confusing one if
nobody says so in advance.

## 7. `Terret.boot`

```ruby
ctx = Terret.boot(profile: "headless",
                  patches: [],                # --patch overlays, in order
                  allow_config_ruby: false,
                  home: nil)                  # defaults to TERRET_HOME or ~/.terret
```

It resolves the layers (§4), hands the row list to the Hames loader, and
returns the booted context. That is the whole surface, and its shape is
plan §1's embeddability goal made concrete: a Rails app calls `Terret.boot`
in an initializer and holds the `ctx`, with no process to supervise and no
socket to speak. The `trt` executable is one caller of this method rather
than the way Terret is used.

Resolution itself is pure — YAML in, ordered rows plus provenance out,
nothing mounted. That separation is what lets `dump-config` and `doctor`
report on a composition they never boot, on a machine with no Docker
daemon and no API key.

## 8. `trt`

```
trt boot        --profile NAME [--patch FILE]... [--allow-config-ruby]
trt doctor      --profile NAME
trt dump-config --profile NAME
trt acp         --profile NAME          # docs/acp.md
```

Non-interactive, optparse, no thor, no REPL, no TUI. Plan §1's non-goals
bar an **interactive text CLI** — a human-facing terminal UI that is a way
of *talking to an agent* — and do not bar an executable. Nothing here is a
chat window and nothing here competes with the socket (plan §9): `trt
boot` starts the reactor and parks, `trt acp` serves an editor over stdio,
the other two print and exit, and every one of them is a thin wrapper over
`Terret.boot` or over pure resolution.

## 9. `doctor` and `Hames::Schema`

`trt doctor` resolves a profile and validates every row's config against
its plugin's schema declaration, without booting anything.

`Hames::Schema` is the kernel's own tiny config validator: a plain
description of a service's config keys — for each one a `type:`, whether
it is `required:`, an optional `enum:` of legal values, a `default:`, and
a `doc:` string — plus the code that checks a config hash against that
description and reports what does not fit. Services declare against it
with the `config_schema` class method, which stores the description on the
class (inherited by subclasses) where doctor and the catalog generator can
both read it. It is pure stdlib rather than dry-schema, because the
kernel's zero-runtime-dependency rule is a design constraint rather than a
coincidence (CLAUDE.md):

```ruby
class Docker < Hames::Service
  service_key :sandbox
  config_schema image:   { type: String, required: true, doc: "container image" },
                network: { type: String, enum: %w[none bridge host], default: "none",
                           doc: "docker --network mode" }
end
```

Two semantics govern how strict this is, and both err the same direction:

- **A service with no schema is reported, not failed.** Doctor marks it
  `unschema'd` and moves on. Every first-party service declares a schema —
  an empty one (`config_schema({})`) when it reads no config, which still
  reads as audited, `ok` — so `unschema'd` now carries real signal: an
  external or unaudited plugin that declared none. A doctor that failed on
  every un-annotated row would be a doctor nobody could run when a
  third-party bundle ships one.
- **Extra keys warn rather than fail.** Config rows grow, and a row
  carrying a key from a newer version of a gem should be a warning about
  drift, not a boot that refuses.

Environment probes are printed as **informational lines and never as
failures**. Doctor validates config, not the world. Concretely, it reports
each `!env` marker the composition reads and whether it resolves — the state
a machine holding no secrets is in — because a doctor that goes red on a
laptop without a key set is a doctor whose red means nothing within a week,
and the entire value of the command is that its exit status can be trusted in
CI. (A live daemon probe — is Docker up — is deliberately *not* run: it would
be slow and non-deterministic, and doctor validates config, not the world.)
Exit status is 1 when an enabled row's config is actually wrong, and 0
otherwise; a disabled row cannot mount, so its config never flips the status.

```
$ trt doctor --profile headless
row            plugin                        status
session_store  Terret::Store::SQLite         ok
sandbox        Terret::Sandbox::Docker       ok
llm            Terret::LLM::Service          ok
titler         Terret::Titler                ok
audit          Acme::Audit                   error: sink must be a String, got nil
metrics        Acme::Metrics                 unschema'd

info  OPENROUTER_API_KEY: unset
```

The same declarations generate `docs/config-catalog.md` via `rake
config:catalog`, which CI diffs exactly the way it diffs `docs/events.md`
— so a config key that changes shape shows up in review rather than in a
support thread.

## 10. `dump-config`

`trt dump-config` prints the resolved tree with **each row annotated by
the layer that contributed it**:

```yaml
# resolved: profile "headless"
rows:
  - id: session_store            # row: terret-base
    plugin: Terret::Store::SQLite
    config:                      # config: terret-base
      path: !setting store.path

  - id: sandbox                  # row: terret-base
    plugin: Terret::Sandbox::Docker
    config:                      # config: profiles/headless/patch.yml
      image: terret/sandbox:latest
      network: none

  - id: llm                      # row: terret-base
    plugin: Terret::OpenRouter::Adapter
    config:                      # config: ~/.terret/patch.yml
      api_key: !env OPENROUTER_API_KEY
      model: !setting model.main
```

That `llm` row is the §4 example after the cure. A patch repointing the
model has to carry the `api_key` along with it, because it replaces the
base row's config whole — and this output is how you would have caught it
had it not.

Provenance is per **row**, not per key, and that falls straight out of §4:
because a patch replaces a config wholesale, there is no per-key blame to
assign — exactly one layer is responsible for what a service receives.
Wholesale replacement bought a debuggable tree, which is most of why it is
worth its ergonomic cost.

A **swapped `plugin:` is attributed on its own line**, because a patch may
change what a row mounts without touching its config and those are two
different decisions by two possibly different layers:

```yaml
  - id: sandbox                  # row: terret-base
    plugin: Terret::Exec::SandboxNone
                                 # plugin: profiles/headless/patch.yml
    config: {}                   # config: profiles/headless/patch.yml
```

The annotation appears only where a layer actually swapped something, so
its presence means "somebody changed this" rather than being noise on
every row. That line is the one piece of provenance nobody can afford to
have wrong: it is how a reader sees that the sandbox got turned off, and
which file did it.

**Secrets render as their unresolved tag.** `api_key: !env
OPENROUTER_API_KEY` prints as written; the resolved value never appears in
`dump-config` output at all. The reason is not subtle: this output exists
to be pasted into an issue, a chat thread, or a support ticket, and a
command whose whole purpose is "show me what my config is" must be safe to
run in front of other people. A resolved credential printed once is a
credential rotated.
