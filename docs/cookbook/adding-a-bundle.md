# Cookbook: Adding a Bundle

A **bundle** is a gem that ships an ordered list of config rows, so a
profile can stack the capability by naming the gem instead of editing Ruby.
`docs/cookbook/adding-a-tool.md` built a `fortune` tool and
`docs/cookbook/adding-a-provider.md` built a seam implementation; both end
with "a profile mounts it," and a bundle is how a gem carries the rows that
mounting needs. This page is the how-to. **`docs/composition.md` is the
normative reference**, covering §2 on bundles, §3 on profiles, and §4 on
layer order; this page is the recipe drawn from it.

The running example stays `terret-fortune` from the tool cookbook, carried
the last mile into a running Terret.

## 1. Declare the gem a bundle

A gem announces itself a bundle with one line of gemspec metadata: the
**string** path to its bundle file.

```ruby
# terret-fortune.gemspec
s.metadata = {
  "terret" => "config/bundle.yml"
}
```

The value is the bare path **as a String**, and that spelling is not
optional. RubyGems validates every metadata value as a String, so a nested
hash there fails to build. Earlier drafts of the plan showed the form
`{ "bundle" => "config/bundle.yml" }`; RubyGems rejects it with
`metadata['terret'] value must be a String`. Discovery still *accepts*
richer forms on read (a real Hash on an in-memory spec, or a YAML mapping
inside the string), so a gem that later grows a second key does not break.
But what a bundle should **ship** is the path on its own
(`docs/composition.md` §2). The real meta-gem does exactly this; see the
`"terret" => "config/bundle.yml"` line in `gems/terret/terret.gemspec`.

Choosing gemspec metadata as the registration mechanism is deliberate:
`gem install` is already the install step and `Gemfile` is already the
manifest, so a bundle becomes discoverable by shipping normally, with
nothing to register and no directory to drop a file into
(`docs/composition.md` §2).

## 2. Depend on what the rows mount

This is the half that is easy to forget: **a bundle does not have to
contain the code its rows mount, but it has to make it available.** For a
Ruby gem that means depending on the gems the rows name, so Bundler puts
their classes on the load path (`docs/composition.md` §2):

```ruby
# terret-fortune.gemspec
s.add_dependency "terret-core", "~> 0.1"
```

`terret-fortune`'s one row mounts `Terret::Fortune::Tool`, which lives in
this same gem, and the tool needs `Terret::Tools::Registry` from
`terret-core`, so `terret-core` is a dependency. The meta-gem is the larger
illustration: `terret-base` ships rows that mount services from six other
gems, and `gems/terret/terret.gemspec` lists all six as dependencies for
exactly this reason. A bundle whose row names a class no dependency puts on
the load path fails when that constant has to resolve, which is what §3's
`requires:` is about.

## 3. Write the bundle file

The bundle file is an ordered list of rows, optionally wrapped in a mapping
that also names the layer and lists its requires:

```yaml
# config/bundle.yml
name: terret-fortune          # what dump-config calls this layer
requires:                     # loaded before any row's constant resolves
  - terret/fortune
rows:
  - id: fortune
    plugin: Terret::Fortune::Tool
```

Two fields carry weight beyond the rows:

- **`name:`** is the label `trt dump-config` attributes this layer's rows
  to. It defaults to the gem name when omitted.
- **`requires:`** is the working half of "make the code available."
  Depending on the gem (§2) puts it on the load path, but *a load path is
  not a `require`*. `Object.const_get("Terret::Fortune::Tool")` fails on a
  file nobody loaded. So the bundle lists the files its rows' classes live
  in, and boot requires them before resolving a single constant
  (`docs/composition.md` §2). The base bundle's `requires:` block in
  `gems/terret/config/bundle.yml` is the worked example: one entry per gem
  whose classes its rows name.

A row itself is the four fields the loader's unit always is: `id`,
`plugin`, `config`, `disabled` (`docs/hames-primer.md` §5,
`docs/composition.md` §1). `terret-fortune` needs only `id` and `plugin`; a
bundle with config-bearing rows writes them here, and a profile patches
them by `id` later (§5).

Remember `s.files` has to carry the bundle file: a gemspec globbing only
`lib/**/*.rb` ships no `config/bundle.yml`, and the gem is silently not a
bundle. `terret-fortune`'s glob is `Dir["lib/**/*", "config/*.yml"]` for
exactly this (and for the vendored fortune list; see the tool cookbook §2).

## 4. How discovery finds it

`Terret::Composition.discover_bundles`
(`gems/terret/lib/terret/composition.rb`) is the mechanism. It walks every
gemspec `Gem::Specification` knows about (under Bundler that is your
bundle; outside it, every gem installed on the machine, loaded or not),
reads the `terret` metadata key, resolves the path it points at, and
parses the file:

```ruby
Terret::Composition.discover_bundles
# => { "terret" => #<Bundle …>, "terret-fortune" => #<Bundle …>, ... }
#    keyed by gem name
```

Know three properties of discovery before you rely on it, all
grounded in the source of `discover_bundles`
(`gems/terret/lib/terret/composition.rb`):

- **A bundle that cannot parse becomes a broken entry, not a crash.** A
  gem whose `bundle.yml` does not parse (a `StandardError` inside
  `load_bundle`) is caught and turned into a `Bundle.broken` entry. It
  never propagates as an exception. A profile that never names it never
  sees it, and one that *does* name it fails closed at resolve with a
  "could not be read" error carrying the parse failure. One bad gem in
  the Gemfile must not take out every profile on the machine
  (`docs/composition.md` §2). This is pinned by
  `test_a_gemspec_that_makes_no_sense_is_not_a_bundle_and_not_a_crash`
  (which also allows a thoroughly malformed metadata value to be simply
  absent rather than broken; either way, it is never a usable bundle).
- **A path that resolves outside the gem's own directory is silently
  excluded, not broken.** The `next unless file.start_with?("#{root}/")`
  guard aborts the entry before it is added to the catalog, so a metadata
  value like `../outside.yml` leaves the gem *absent* from discovery,
  indistinguishable from a gem shipping no `terret` metadata at all. A
  profile naming it gets the generic "unknown bundle; discovered: …"
  message, not the broken-entry error. That is a different failure mode
  from the parse case above; do not confuse the two. Treat this as
  best-effort: it is a string-prefix check. It is not a security
  boundary, and full bundle-path containment is a known gap for a later
  security pass (Task 11) that **fails open today**. The case of a
  gemspec reporting no gem path at all is left `skip`ped in the suite
  (`test_a_gemspec_with_no_gem_path_is_not_a_bundle`, marked
  "bundle-path containment (this fails open today)").
- **The monorepo checkout is seeded first, then an installed gem wins.**
  `terret-base` is loaded from the checkout so a monorepo run resolves
  `terret` with no gem installation, and an installed `terret` gemspec
  overwrites it when both are present.

Discovery is pure: YAML in, a catalog of bundles out, nothing mounted.
`trt dump-config` and `trt doctor` can report on a composition they never
boot (`docs/composition.md` §7). You rarely call `discover_bundles`
directly; `Terret.boot` and the resolver call it for you (§5).

## 5. Stack it in a profile

A profile names bundles by **gem name**, in stack order, layer one always
`terret` (`docs/composition.md` §3):

```yaml
# ~/.terret/profiles/headless/profile.yml
bundles:
  - terret          # terret-base, always first
  - terret-fortune  # this gem, its rows layered on top
```

`Terret.boot(profile: "headless")` resolves the layers and hands the row
list to the Hames loader. The layer order is fixed and later layers win
(`docs/composition.md` §4): every bundle in `bundles:` order, then the
profile's own `patch.yml`, then the home `~/.terret/patch.yml`, then any
`--patch` overlays. A bundle naming a name discovery did not find fails
closed, listing what *was* discovered. The missing bundle is almost always
a gem that is not installed, not in this Gemfile, or ships no `terret`
metadata (`docs/composition.md` §2).

Two things from the other cookbooks land here:

- A row's config is patched by a profile **wholesale**: a patch that
  mentions one key drops the rest of that row's config
  (`docs/composition.md` §4). This is the single rule that surprises
  people most; when in doubt, `trt dump-config` shows what a row
  currently holds before you replace it.
- Mounting `terret-fortune` does **not** make `fortune` callable. The
  deny-by-default allow list denies it until a profile permits it, and
  that patch is `docs/cookbook/adding-a-tool.md` §5. A bundle ships rows;
  a profile still decides what the agent may do with them.

Not every gem should ship a bundle. A provider gem meant to be mounted by
a row someone else writes is discoverable as a *library*, not a bundle.
`terret-morph` is the example: it ships **no** `terret` metadata
(`docs/cookbook/adding-a-provider.md` §3), and a profile mounts it with a
`requires:` entry and a row. It never appears in `bundles:`. Ship a
bundle when your gem is a capability a profile should be able to stack by
name; skip it when your gem is one class a row elsewhere mounts.

## 6. What you have when this is done

A gem that declares itself a bundle in one line of metadata, depends on
what its rows mount, ships an ordered `bundle.yml` with the requires its
constants need, and is discoverable by shipping normally. A profile
stacks it by name, patches its rows wholesale, and, for tools, permits
them in the allow list. `docs/composition.md` is the reference this
recipe is drawn from, covering the rules behind every step here.
`docs/cookbook/adding-a-tool.md` and `docs/cookbook/adding-a-provider.md`
cover the two things a bundle usually carries.
