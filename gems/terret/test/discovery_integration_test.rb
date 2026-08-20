# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/terret/boot"

# The extension story, tested in-tree: a stranger's gem, shipping nothing but a
# gemspec metadata key and a bundle file, joins an agent's boot and its tool
# becomes callable. This is docs/cookbook/adding-a-tool.md and
# docs/cookbook/adding-a-bundle.md proven end to end — discovery reads the
# metadata, a profile stacks the bundle by name, boot requires the code and
# mounts the row, and the deny-by-default allow list gates the tool until the
# profile permits it.
#
# It builds its own fixture gem on disk (a real bundle.yml plus the Service the
# row mounts) and never depends on any gem being installed, so it runs offline
# on Memory rows with the model and sandbox swapped out.
class DiscoveryIntegrationTest < Minitest::Test
  C = Terret::Composition

  # The base roster the floor names (docs/cookbook/adding-a-tool.md §5). A
  # profile that permits `fortune` restates this WHOLESALE and appends it; one
  # that does not leaves the stranger's tool denied.
  ROSTER = %w[Read Write Edit Glob Grep Bash WebFetch Task TodoWrite
              terminal_open terminal_read terminal_input terminal_close
              job_start job_collect job_stop].freeze

  # The stranger's gem name — the key discovery files it under and the name a
  # profile stacks it by. Deliberately not "terret-fortune": this fixture is a
  # stranger, not the sibling gem.
  STRANGER = "terret-stranger"

  # The fixture's vendored list, mirrored here so the test can assert the exact
  # line a seed selects.
  FORTUNES = %w[fortune-a fortune-b fortune-c fortune-d].freeze

  def setup
    @home_dir  = Dir.mktmpdir("terret-home")
    @workspace = Dir.mktmpdir("terret-workspace")
    @gem_dir   = Dir.mktmpdir("terret-stranger-gem")
    @prev_home = ENV["TERRET_HOME"]
    ENV["TERRET_HOME"] = @home_dir
    @booted = []
    @added_specs = []
    write_stranger_gem
  end

  def teardown
    @booted.each { |ctx| Terret::Boot.shutdown(ctx) }
    # The global-gemspec test registers a spec; leaving it behind would leak
    # this stranger into every later test in the same process.
    @added_specs.each { |s| Gem::Specification.remove_spec(s) }
    ENV["TERRET_HOME"] = @prev_home
    [@home_dir, @workspace, @gem_dir].each { |d| FileUtils.remove_entry(d) if d && File.directory?(d) }
  end

  # -- the fixture gem on disk ----------------------------------------------

  def write(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  # A real fortune-shaped gem: the Service its row mounts, and a config/bundle.yml
  # shaped exactly like terret-fortune's — metadata points at "config/bundle.yml",
  # the file names the row and the requires its constant needs. The Service is
  # the cookbook's shape reduced to a fixture: it injects ctx[:tools] and
  # registers a `fortune` Definition with honest metadata, made deterministic
  # under a seed: config so the assertion can be exact, and namespaced so it is
  # unmistakably a stranger.
  def write_stranger_gem
    @service_file = write(File.join(@gem_dir, "lib", "stranger_fortune.rb"), <<~RUBY)
      # frozen_string_literal: true
      module StrangerFortune
        class Tool < Hames::Service
          service_key :fortune
          inject :tools
          config_schema seed: { type: Integer, doc: "index into FORTUNES, taken mod its length" }
          FORTUNES = %w[fortune-a fortune-b fortune-c fortune-d].freeze
          def start(ctx)
            @ctx = ctx
            @seed = config[:seed] || 0
            @ctx[:tools].register(name: "fortune",
                                  description: "Return one fortune from a vendored list.",
                                  params: {}, mutating: false, approval: :never,
                                  concurrency: :parallel, ctx: @ctx) do
              FORTUNES[@seed % FORTUNES.length]
            end
          end
        end
      end unless defined?(StrangerFortune::Tool)
    RUBY

    # The STRING metadata form is what ships; requires: names the file to load
    # before the constant resolves. A shipped gem names a load-path feature
    # (terret-fortune uses `terret/fortune`); a fixture names the file's own
    # absolute path, so the test needs neither a gem install nor a $LOAD_PATH
    # mutation to make the code available.
    write(File.join(@gem_dir, "config", "bundle.yml"), <<~YAML)
      name: #{STRANGER}
      requires:
        - #{@service_file.delete_suffix('.rb')}
      rows:
        - id: fortune
          plugin: StrangerFortune::Tool
    YAML
  end

  # A gemspec shaped like terret-fortune's: the terret metadata is the string
  # path, and full_gem_path points at the fixture on disk. Mirrors
  # composition_test.rb's fixture_spec.
  def fixture_spec(name = STRANGER, dir = @gem_dir, bundle_path = "config/bundle.yml")
    spec = Gem::Specification.new do |g|
      g.name = name
      g.version = "0.1.0"
      g.summary = "fixture"
      g.authors = ["t"]
      g.files = []
    end
    spec.metadata = { "terret" => bundle_path }
    spec.define_singleton_method(:full_gem_path) { dir }
    spec
  end

  # -- the offline profile ---------------------------------------------------

  # terret-base with the three rows that reach the network or the disk swapped
  # for their offline equivalents, the fortune row's seed set, and the allow
  # list restated (wholesale) to permit — or withhold — the stranger's tool.
  def offline_patch(permit_fortune:, seed:)
    permitted = permit_fortune ? ROSTER + ["fortune"] : ROSTER
    <<~YAML
      rows:
        - id: session_store
          plugin: Terret::Store::Memory
          config: {}
        - id: openrouter
          disabled: true
        - id: llm
          config:
            roles:
              main: fake/scripted
        - id: sandbox
          plugin: Terret::Exec::SandboxNone
          config: {}
        - id: fortune
          config:
            seed: #{seed}
        - id: allow_list
          config:
            patterns: [#{permitted.join(', ')}]
    YAML
  end

  def stranger_profile(name = "stranger", permit_fortune: true, seed: 3)
    write(File.join(@home_dir, "profiles", name, "profile.yml"), <<~YAML)
      bundles: [terret, #{STRANGER}]
      settings:
        workspace:
          - #{@workspace}
        store: { path: unused }
        model: { main: fake/scripted }
        sandbox: { image: unused }
    YAML
    write(File.join(@home_dir, "profiles", name, "patch.yml"), offline_patch(permit_fortune: permit_fortune, seed: seed))
    name
  end

  # discover -> resolve -> boot, the exact call graph Terret.boot composes
  # (boot.rb: Boot.new(Composition.resolve(...)).boot!), with the fixture spec
  # handed to discovery explicitly because a stranger's gemspec cannot be put on
  # the global Gem::Specification without mutating it (that path is exercised on
  # its own, below).
  def boot_stranger(name, specs:)
    catalog = C.discover_bundles(specs: specs)
    resolved = C.resolve(profile: name, bundles: catalog)
    ctx = Terret::Boot.new(resolved).boot!
    @booted << ctx
    ctx
  end

  def run_fortune(ctx, session_id:)
    session = ctx[:sessions].create(id: session_id)
    ctx[:tools].execute(
      Terret::Tools::Call.new(id: "c1", name: "fortune", args: {}, session_id: session.id), ctx: ctx
    )
  end

  def tool_names(ctx) = ctx[:tools].schemas.map { |s| s[:name] }

  # -- the chain -------------------------------------------------------------

  def test_discovery_reads_the_strangers_bundle_off_its_gemspec_metadata
    found = C.discover_bundles(specs: [fixture_spec])
    assert found.key?(STRANGER), "a gem shipping terret metadata must be discovered"
    assert_equal STRANGER, found[STRANGER].name
    assert_equal %w[fortune], found[STRANGER].rows.map { |r| r[:id] }
    assert_nil found[STRANGER].error, "a well-formed bundle is not a broken entry"
  end

  def test_a_strangers_gem_is_discovered_stacked_booted_and_its_tool_runs
    name = stranger_profile(permit_fortune: true, seed: 3)
    ctx = boot_stranger(name, specs: [fixture_spec])

    assert_includes tool_names(ctx), "fortune",
                    "the stranger's row must have mounted and registered its tool"
    result = run_fortune(ctx, session_id: "s1")
    assert_nil result.error, "a permitted tool runs"
    assert_equal FORTUNES[3 % FORTUNES.length], result.content,
                 "the row's seed: config reached the handler through the whole boot"
  end

  # Mounting the tool does not make it callable: the deny-by-default floor gates
  # it until a profile restates the allow list to include it
  # (docs/cookbook/adding-a-tool.md §5).
  def test_the_strangers_tool_is_denied_until_the_profile_permits_it
    name = stranger_profile("locked", permit_fortune: false)
    ctx = boot_stranger(name, specs: [fixture_spec])

    assert_includes tool_names(ctx), "fortune",
                    "the tool is mounted; it is the allow list, not the mount, that gates it"
    result = run_fortune(ctx, session_id: "locked1")
    assert_match(/fortune is not on the allow list/, result.error.to_s)
  end

  # The public entry point, verbatim. Terret.boot walks the global
  # Gem::Specification for bundles; inject the stranger there and boot through
  # Terret.boot itself, so the mounted-through-discovery path is proven end to
  # end rather than through a hand-assembled catalog.
  def test_terret_boot_mounts_a_stranger_discovered_through_the_global_gemspec
    spec = fixture_spec
    Gem::Specification.add_spec(spec)
    @added_specs << spec
    name = stranger_profile("global", permit_fortune: true, seed: 2)

    ctx = Terret.boot(profile: name)
    @booted << ctx

    assert_includes tool_names(ctx), "fortune",
                    "Terret.boot must discover and mount a stranger off the global gemspec"
    result = run_fortune(ctx, session_id: "global1")
    assert_nil result.error
    assert_equal FORTUNES[2 % FORTUNES.length], result.content
  end
end
