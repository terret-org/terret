# Terret Cookbook

Worked, end-to-end recipes for building on Terret. Each one starts from the
kernel primitives (`docs/hames-primer.md`) and ends at a running piece of a
Terret — a real gem, real metadata, a real test — rather than a snippet in
isolation. Where a recipe touches a contract, it points at the normative
document for the contract and stays a how-to itself.

- **[adding-a-tool.md](adding-a-tool.md)** — an empty gem to a registered
  tool with honest mutating/approval/concurrency metadata and a test. The
  running example is `terret-fortune`, a `fortune` tool returning one line
  from a vendored list. Reference: `docs/exec.md` §5 (the roster and the
  metadata), `gems/terret-core/lib/terret/tools.rb` (the registry).

- **[adding-a-provider.md](adding-a-provider.md)** — implementing a
  sole-provider seam, using `ctx[:summarizer]` as the model because Terret
  ships two implementations of it. Covers the seam contract, the
  sole-provider refusal, an injectable transport so tests need no network,
  and nil-on-failure discipline where it applies. Reference:
  `gems/terret-morph` (the worked provider), `docs/lifecycle.md`
  (compaction).

- **[adding-a-bundle.md](adding-a-bundle.md)** — the gemspec metadata that
  declares a gem a bundle, the `bundle.yml` shape, the discovery mechanism
  (`Composition.discover_bundles`), and profile stacking. Reference and
  contract: `docs/composition.md`.

New to the kernel these build on? Read `docs/hames-primer.md` first — a
tool provider and a seam provider are both ordinary Hames services, and a
bundle is ordinary config rows.
