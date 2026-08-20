# Cookbook: Adding a Tool

This is a complete worked example: an empty gem to a tool a Terret agent
can call, with honest metadata and a test. The running example is
`terret-fortune` — a `fortune` tool that returns one line from a vendored
list — and it is small on purpose, so the shape shows through. Everything
here is a real gem; `terret-fortune` ships as its own repository, and this
page is that repository made generic.

Read `docs/hames-primer.md` first if the words *service*, *effect*, and
*row* are not yet familiar — a tool provider is an ordinary Hames service,
and nothing here escapes the kernel's five nouns. The tool pipeline it
plugs into is `docs/exec.md` §5 and the roster it joins is
`gems/terret-tools-std`; the discovery mechanism that mounts it is
`docs/composition.md`, walked end to end in
`docs/cookbook/adding-a-bundle.md`.

## 1. What a tool actually is

A tool is a `Terret::Tools::Definition` sitting in `ctx[:tools]`, the
registry (`gems/terret-core/lib/terret/tools.rb`). You never build the
`Definition` yourself; you call `register` and hand it the parts:

```ruby
def register(name:, description:, params: {}, mutating: false,
             approval: :never, concurrency: :serial, ctx: @ctx, &handler)
```

- `name` — the string the model calls, and the string an allow list matches
  against (§5). Claude Code's spelling verbatim where CC has the tool,
  snake_case where it does not (`docs/exec.md` §5); `fortune` has no CC
  equivalent, so it is lowercase.
- `description` — what the model reads to decide whether to call it.
- `params` — a JSON-Schema object describing the arguments; `{}` for a tool
  that takes none.
- `mutating`, `approval`, `concurrency` — the honest metadata of §4.
- `ctx:` — **pass this explicitly** (§3). It is what ties the registration's
  lifetime to the mounting row.
- the block — the handler, receiving the model's arguments as keywords.

`register` returns the registration's disposer, because registering a tool
is an ordinary reversible effect (`docs/hames-primer.md` §2): unmount the
row and the tool goes with it.

## 2. The gem skeleton

A bundle is a gem that ships an ordered list of config rows and depends on
the code those rows name (`docs/composition.md` §2). For one tool that is a
small tree:

```
terret-fortune/
├── terret-fortune.gemspec
├── config/
│   └── bundle.yml
├── lib/
│   └── terret/
│       ├── fortune.rb              # entry: requires the service
│       └── fortune/
│           ├── tool.rb             # the service
│           └── fortunes.txt        # the vendored list
└── test/
    └── fortune_test.rb
```

The gemspec declares the gem a bundle with one line of metadata, and — this
is the half people forget — **depends on the gems its rows mount**. A
bundle does not have to contain the code it mounts, but it has to make it
available, and for a Ruby gem that means a dependency Bundler will put on
the load path (`docs/composition.md` §2):

```ruby
# terret-fortune.gemspec
Gem::Specification.new do |s|
  s.name    = "terret-fortune"
  s.version = "0.1.0"
  s.summary = "A fortune tool for Terret"
  s.authors = ["Your Name"]
  s.license = "MIT"
  # The vendored list is not a .rb file, so widen the glob to carry it.
  s.files   = Dir.chdir(__dir__) { Dir["lib/**/*", "config/*.yml"] }
  s.required_ruby_version = ">= 4.0"

  s.add_dependency "terret-core", "~> 0.1"

  s.metadata = {
    # How a gem declares itself a bundle: the STRING path to its bundle
    # file. RubyGems validates every metadata value as a String, so a nested
    # hash here does not build at all — the bare path is the shipped form
    # (docs/composition.md §2).
    "terret" => "config/bundle.yml"
  }
end
```

The entry file requires the service, and carries the monorepo-vs-installed
fallback the rest of the tree uses so a checkout runs without a `gem
install`:

```ruby
# lib/terret/fortune.rb
# frozen_string_literal: true

begin
  require "terret"
rescue LoadError
  require_relative "../../../terret-core/lib/terret" # monorepo path source
end

require_relative "fortune/tool"
```

## 3. The service

The service subclasses `Hames::Service`, injects `:tools`, declares a
schema, and registers the tool in `start`. This is the `terret-fortune`
service in full:

```ruby
# lib/terret/fortune/tool.rb
# frozen_string_literal: true

module Terret
  module Fortune
    # Registers the `fortune` tool: one random line from a vendored list.
    # An ordinary tool provider — a Hames service that injects ctx[:tools]
    # and registers a Definition in `start`, the shape gems/terret-tools-std
    # uses for the whole standard roster.
    class Tool < Hames::Service
      service_key :fortune
      inject :tools
      config_schema path: { type: String,
                            doc: "path to a newline-delimited fortune file; " \
                                 "defaults to the vendored list" }

      DEFAULT_FILE = File.expand_path("fortunes.txt", __dir__)

      DESCRIPTION = "Return a single fortune: one short, pithy line chosen at random."

      def start(ctx)
        @ctx = ctx
        @fortunes = load_fortunes(config[:path] || DEFAULT_FILE)
        register_fortune
      end

      # The list is read once at mount. A swapped `path:` needs a remount to
      # apply, and saying so beats letting the base class warn that a service
      # it thinks is stateful needs one (docs/hames-primer.md §5).
      def reconfigure(config)
        @fortunes = load_fortunes(config[:path] || DEFAULT_FILE)
      end

      private

      def register_fortune
        # `ctx:` is passed explicitly, exactly as the std roster does it. The
        # registry defaults it to the context the service was started in; a
        # provider mounted into a forked agent scope wants the registration
        # owned by that fork, so disposing the agent reaps the tool rather
        # than leaving it live on the root (gems/terret-core tools.rb).
        @ctx[:tools].register(name: "fortune", description: DESCRIPTION, params: {},
                              mutating: false, approval: :never, concurrency: :parallel,
                              ctx: @ctx) do
          @fortunes.sample
        end
      end

      def load_fortunes(path)
        lines = File.readlines(path, chomp: true).map(&:strip).reject(&:empty?)
        # A tool that would return nil on every call is a bug worth failing
        # at mount, not one call at a time.
        raise "no fortunes in #{path}" if lines.empty?

        lines
      end
    end
  end
end
```

Three things are worth reading twice:

**`inject :tools`.** That, and nothing more, is what orders this row after
the registry in the dependency-driven boot (`docs/hames-primer.md` §1). The
loader mounts `tools` first because this row says it needs it; get the
`inject` wrong and the row either races or fails to mount, both louder than
a silent misorder.

**`ctx:` is passed, not defaulted.** The comment in the code says why, and
it is the same reason the entire standard roster passes it: a tool carries
authority — even a harmless one occupies a name in the roster — and its
registration must die with the agent that made it, not outlive it on the
root context. Leave it off and the tool works, right up until a forked
agent scope disposes and its tool is still there.

**`params: {}`.** `fortune` takes no arguments, so its schema is the empty
object and its handler takes no keywords. A tool with arguments describes
them as a JSON-Schema object and receives them as keywords — see
`gems/terret-tools-std/lib/terret/tools_std/files.rb` for `Read`'s
`file_path:` and `Grep`'s `pattern:`/`glob:`, where the handler's keyword
signature matches the schema's `properties` and `required`.

## 4. Honest metadata

The three metadata fields are the tool telling the truth about what calling
it does. They are read by the loop's tool barrier and the approvals gate,
so a lie here is a lie those act on.

| Field | `fortune` | What it declares |
|---|---|---|
| `mutating` | `false` | The call changes nothing in the world. |
| `approval` | `:never` | The call never needs a human's consent. |
| `concurrency` | `:parallel` | The call may run alongside other `:parallel` calls in one message. |

`fortune` is a pure read with no side effect and no ordering dependency, so
all three are the permissive value *honestly*. Contrast the standard roster
(`docs/exec.md` §5): `Write` and `Edit` are `mutating: true`,
`approval: :policy`, `concurrency: :serial`, because they change files, may
warrant a human, and must not interleave. Set these to what your tool
actually does, not to what makes it convenient to call:

- **`mutating`** is true if the call changes state anything else can
  observe — a file, a process, a remote resource. The approvals gate's rule
  is `always || (policy && mutating)`, so `mutating: false` with
  `approval: :policy` never parks; a mutating tool is where `:policy` bites.
- **`approval`** is `:never`, `:policy`, or `:always`. `:never` skips the
  gate; `:always` asks every time; `:policy` asks only where an approvals
  row is mounted *and* the tool is mutating. Note the honest limit: in a
  profile with no approvals row, `:policy` reduces to the allow list alone —
  it is not a guarantee a human is watching (`docs/security.md`, "Approval
  defaults").
- **`concurrency`** is `:parallel` or `:serial` (the default). The loop
  runs a message's calls in maximal runs of `:parallel`-declared
  definitions under one barrier, and a `:serial` call runs alone
  (`docs/subagents.md` §5). Declare `:parallel` only for a call that is safe
  to run beside its siblings and whose result does not depend on ordering.

## 5. The allow list denies it until a profile says otherwise

This is the one thing that surprises people, so it goes in bold: **mounting
the tool does not make it callable.** Terret's tool policy is
deny-by-default (`gems/terret-core/lib/terret/tools.rb`, `AllowList`), and
the base floor names exactly the standard roster and nothing else
(`gems/terret/config/bundle.yml`). A `fortune` arriving from a third-party
bundle is denied — "fortune is not on the allow list" — until a profile
adds it:

```yaml
# in a profile's patch.yml — see docs/composition.md §4
rows:
  - id: allow_list
    config:
      patterns:
        - Read
        - Write
        - Edit
        - Glob
        - Grep
        - Bash
        - fortune          # the new tool, now permitted
        # ... restate the rest: a patch replaces the row's config WHOLESALE
```

Two properties of that list are the ones to internalize. It is
**wholesale-replaced**, like every patch (`docs/composition.md` §4), so the
patch above must restate every pattern the floor had — a patch that mentions
only `fortune` drops the standard roster with it. And the patterns are
`File.fnmatch` globs, case-sensitive, where `*` does not match a leading
dot — both failing closed. That deny-by-default floor is exactly what
deny-by-default buys: a tool from a bundle you added cannot run until a
profile decides it may, which is the point.

An agent can also widen its own live policy at runtime through
`AllowList.update` (a durable `policy/updated` in its session), and that
takes effect on the very next call and survives a restart. The floor is the
fallback for a session that never updated. See `docs/lifecycle.md`,
"Hot-reloadable permissions", for the running-agent story;
`docs/composition.md` §6 for the floor as a config row.

## 6. The test

A tool test boots the service through the loader and drives the registry's
`execute` pipeline, the same path a real call takes. This mirrors the
harness a real gem ships (`gems/terret-tools-std/test/`), pared to the one
tool:

```ruby
# test/fortune_test.rb
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret/fortune"

class FortuneToolTest < Minitest::Test
  def setup
    Hames.reset_events!
    Terret.declare_events! # the tool pipeline dispatches declared events
  end

  def boot
    loader = Hames::Loader.new
    loader.layer([
      { id: "tools",   plugin: Terret::Tools::Registry },
      { id: "fortune", plugin: Terret::Fortune::Tool }
    ])
    loader.boot!
  end

  def call(ctx, name, args = {})
    call = Terret::Tools::Call.new(id: "c1", name: name, args: args, session_id: "s1")
    ctx[:tools].execute(call, ctx: ctx)
  end

  def test_it_registers_under_its_name
    ctx = boot
    names = ctx[:tools].schemas.map { |s| s[:name] }
    assert_includes names, "fortune"
  end

  def test_it_returns_one_of_the_vendored_lines
    ctx = boot
    fortunes = File.readlines(Terret::Fortune::Tool::DEFAULT_FILE, chomp: true)
                   .map(&:strip).reject(&:empty?)
    result = call(ctx, "fortune")
    assert_nil result.error
    assert_includes fortunes, result.content
  end

  def test_its_metadata_is_honest
    ctx = boot
    d = ctx[:tools].fetch("fortune")
    refute d.mutating
    assert_equal :never, d.approval
    assert_equal :parallel, d.concurrency
  end
end
```

`Terret::Tools::Call` and the `execute(call, ctx:)` signature are the real
ones (`gems/terret-core/lib/terret/tools.rb`); `execute` runs the
three-waterfall pipeline — `pre_execute` (where the allow list would veto,
if one were mounted), `execute`, `post_execute` — and returns a
`Terret::Tools::Result` with `content` and `error`. The test above mounts
no allow list, so the call is not gated; a test that wanted to prove the
deny-by-default behavior would mount `Terret::Tools::AllowListFloor` with an
empty `patterns:` and assert the result's `error` names the allow list.

## 7. Mounting it in a profile

The gem carries its own one-row bundle so a profile can stack it by name.
That row, the metadata that makes it discoverable, and how a profile names
the bundle are `docs/cookbook/adding-a-bundle.md` — this page ends where the
tool is registered and tested; that one carries it into a running Terret.
The bundle file is one row:

```yaml
# config/bundle.yml
name: terret-fortune
requires:
  - terret/fortune          # loaded before the row's constant resolves
rows:
  - id: fortune
    plugin: Terret::Fortune::Tool
```

And a profile that wants it stacks the bundle and — because of §5 — permits
the tool:

```yaml
# ~/.terret/profiles/headless/profile.yml
bundles:
  - terret          # terret-base, always layer one
  - terret-fortune  # this gem
```

That is the whole path: a gem with one tool, honest about what it does,
discoverable by shipping normally, denied until a profile says otherwise,
and mounted by naming it. For the seam-implementation cousin of this
recipe — a provider claiming a sole-provider key rather than adding a tool —
see `docs/cookbook/adding-a-provider.md`.
