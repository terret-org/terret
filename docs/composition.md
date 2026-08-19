# Composing a Terret (v1)

Plan §7 is four bullets. This is those four bullets made normative, and it
is the contract `gems/terret` is built against when it stops being a
placeholder holding the name.

Everything in Terret is a plugin, which is a claim that only means
something if there is a way to say *which* plugins, in what order, with
what config, without editing Ruby. That is what this document describes:
bundles ship rows, profiles stack bundles, patches adjust rows, and
`Terret.boot` hands the result to the Hames loader. The model is a direct
port of dsh's (§2.2), YAML-native.

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
rows, plus the code those rows mount. It declares itself in its gemspec:

```ruby
s.metadata = { "terret" => { "bundle" => "config/bundle.yml" } }
```

That single line is the whole registration mechanism, and choosing gemspec
metadata over a registry file or a plugin directory is deliberate: `gem
install` is already the install step, `Gemfile` is already the manifest,
and Bundler already resolves versions. Discovery scans loaded gemspecs
(`Gem::Specification.each`) for the key and parses the referenced file. A
third-party gem becomes discoverable by shipping normally — nothing to
register, nothing to symlink, no directory to drop a file into. It is the
port of dsh's `package.json` `dsh` field (§5), and it is the mechanism
`docs/cookbook/adding-a-bundle.md` walks end to end.

A profile names bundles by **gem name**. A name that discovery did not
find fails closed, listing what *was* discovered — the failure mode here
is almost always a gem that is installed but not loaded, and printing the
found set turns a five-minute confusion into a five-second one.

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

  - id: llm.main
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
The cost is real and worth paying: restating a two-key config to change one
key is three seconds of typing, and `dump-config` (§10) is there for when
the current value is not obvious.

A patch may also swap `plugin:` on an existing id, which is the mechanism
docs/exec.md §4 leans on: one row swaps `Terret::Sandbox::None` for
`Terret::Sandbox::Docker` and every tool built on `ctx[:fs]` and
`ctx[:subprocess]` moves into the container, tool code untouched.

A row with an id that does not exist yet is an **insertion**, and it must
say where it goes with `before:` or `after:` naming an existing id.
Position matters for reasons the loader's dependency ordering does not
cover — two `tools/pre_execute` listeners have an order, and that order is
policy. An anchor naming an id that is not in the stack fails closed,
naming the id, rather than appending the row somewhere plausible: an audit
listener silently mounted at the end of the chain instead of in front of
the thing it was supposed to audit is exactly the failure that should
never be quiet.

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
having said so out loud. Parsing is `YAML.safe_load` with explicit
permitted tag classes throughout; `YAML.load` never appears, so an
untrusted profile cannot instantiate arbitrary objects even before
reaching the `!ruby` check.

## 6. `terret-base`, and secure by default

`terret-base` is a bundle **inside the meta-gem**
(`gems/terret/config/bundle.yml`), not a gem of its own — §5's layout
lists no such gem and §7 puts it inside `terret`. It is layer one of every
profile, and its rows are the answer to "what is a Terret":

| Row | Plugin | Note |
|---|---|---|
| `session_store` | `Terret::Store::SQLite` | durable log, WAL |
| `sessions`, `prompt`, `tools`, `loop` | terret-core | the harness itself |
| `llm` | `Terret::OpenRouter::Adapter` | model roles, `!env`-keyed |
| fs / subprocess / shell / terminals | terret-exec | the execution world |
| `sandbox` | `Terret::Sandbox::Docker` | **`network: none`** |
| std tools | terret-tools-std | the CC-named roster |
| `redactor` | terret-core | `tools/post_execute` + the append scrubber |
| `allow_list` | terret-core | the deny-by-default floor |
| `approvals` | terret-core | `disabled: true` — opt-in per M6 |

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
  #   plugin: Terret::Sandbox::None
  #   config: {}
```

A comment block is not a security control. What it is, is the difference
between a decision made and a default inherited, and §13 asks for exactly
that: `none` requires explicit per-profile opt-in. The template is where
the explicitness lives.

## 7. `Terret.boot`

```ruby
ctx = Terret.boot(profile: "headless",
                  patches: [],                # --patch overlays, in order
                  allow_config_ruby: false,
                  home: nil)                  # defaults to TERRET_HOME or ~/.terret
```

It resolves the layers (§4), hands the row list to the Hames loader, and
returns the booted context. That is the whole surface, and its shape is
the §1 embeddability goal made concrete: a Rails app calls `Terret.boot`
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

Non-interactive, optparse, no thor, no REPL, no TUI. §1's non-goals bar an
**interactive text CLI** — a human-facing terminal UI that is a way of
*talking to an agent*. They do not bar an executable. `trt boot` starts
the reactor and parks; `trt acp` serves an editor over stdio; the other
two print and exit. Nothing here is a chat window, and nothing here is a
second interface competing with the socket (§9 of the plan): every one of
these subcommands is a thin wrapper over `Terret.boot` or over pure
resolution.

## 9. `doctor` and `Hames::Schema`

`trt doctor` resolves a profile and validates every row's config against
its plugin's schema declaration, without booting anything.

`Hames::Schema` is a class-level declaration on `Hames::Service` — pure
stdlib, no dry-schema, because the kernel's zero-runtime-dependency
constraint is a design constraint rather than a coincidence (CLAUDE.md):

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
  `unschema'd` and moves on. Schemas arrive service by service; a doctor
  that failed on every un-annotated row would be a doctor nobody could run
  during the milestone that introduces schemas.
- **Extra keys warn rather than fail.** Config rows grow, and a row
  carrying a key from a newer version of a gem should be a warning about
  drift, not a boot that refuses.

Environment probes — is the Docker daemon up, does `OPENROUTER_API_KEY`
resolve — are printed as **informational lines and never as failures**.
Doctor validates config, not the world. A doctor that goes red on a laptop
with Docker Desktop closed is a doctor whose red means nothing within a
week, and the entire value of the command is that its exit status can be
trusted in CI. Exit status is 1 when a row's config is actually wrong, and
0 otherwise.

```
$ trt doctor --profile headless
row            plugin                        status
session_store  Terret::Store::SQLite         ok
sandbox        Terret::Sandbox::Docker       ok
llm            Terret::OpenRouter::Adapter   ok
audit          Acme::Audit                   error: sink must be a String, got nil
titler         Terret::Titler                unschema'd

info  docker daemon: reachable
info  OPENROUTER_API_KEY: set
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
```

Provenance is per **row**, not per key, and that falls straight out of §4:
because a patch replaces a config wholesale, there is no per-key blame to
assign — exactly one layer is responsible for what a service receives.
Wholesale replacement bought a debuggable tree, which is most of why it is
worth its ergonomic cost.

**Secrets render as their unresolved tag.** `api_key: !env
OPENROUTER_API_KEY` prints as written; the resolved value never appears in
`dump-config` output at all. The reason is not subtle: this output exists
to be pasted into an issue, a chat thread, or a support ticket, and a
command whose whole purpose is "show me what my config is" must be safe to
run in front of other people. A resolved credential printed once is a
credential rotated.
