# frozen_string_literal: true

require "yaml"
require_relative "home"

module Terret
  # Bundles ship rows, profiles stack bundles, patches adjust rows
  # (docs/composition.md). Resolution here is pure: YAML in, ordered rows plus
  # provenance out, nothing mounted and no constant resolved. That separation
  # is what lets dump-config and doctor report on a composition they never
  # boot, on a machine with no Docker daemon and no API key.
  module Composition
    Error = Class.new(StandardError)

    # The three tags that make config dynamic without making it code (§5).
    TAGS = %w[env setting ruby].freeze

    # YAML's own types, which Psych's restricted schema handles safely and
    # which a config is welcome to use. Anything outside these lists and TAGS
    # is refused by name — including the ruby/* family, which the restricted
    # class loader would also refuse, but later and less clearly.
    #
    # Split by node kind because Psych ignores a core tag that does not suit
    # the node it is on (`!!map hello` is the string "hello") or dies inside
    # its own schema handler (`!!str` on a mapping). Both are the silent drop
    # this reader exists to refuse, one type system down.
    CORE_SCALAR_TAGS = %w[null bool int float str binary].freeze
    CORE_COLLECTION_TAGS = %w[map seq].freeze
    CORE_TAGS = (CORE_SCALAR_TAGS + CORE_COLLECTION_TAGS).freeze

    YAML_SCHEMA = "tag:yaml.org,2002:"

    # One tag, four spellings. `!env`, `!!env`, `!<tag:yaml.org,2002:env>` and a
    # `%TAG ! !!` directive over a plain `!env` all reach the visitor as
    # different strings, and a reader that only recognises the first drops the
    # other three on the floor — which is the silent-drop this whole visitor
    # exists to prevent, reintroduced one spelling down. So every non-nil tag
    # gets classified, and nothing falls through unclassified.
    #
    #   nil                -> untagged
    #   [:local, "env"]    -> !env
    #   [:core, "str"]     -> !!str, tag:yaml.org,2002:str
    #   [:foreign, raw]    -> anything else, including bare "x-private:env"
    def self.tag_kind(raw)
      return nil if raw.nil?
      return [:core, raw.delete_prefix(YAML_SCHEMA)] if raw.start_with?(YAML_SCHEMA)
      return [:core, raw.delete_prefix("!!")] if raw.start_with?("!!")
      return [:local, raw.delete_prefix("!")] if raw.start_with?("!")

      [:foreign, raw]
    end

    # A tag left standing. Resolution keeps these unevaluated so dump-config
    # can print `!env OPENROUTER_API_KEY` as written — the resolved value never
    # appears in that output at all. Boot materializes them; nothing else does.
    Tagged = Data.define(:tag, :argument) do
      def to_s = "!#{tag} #{argument}"
    end

    # One resolved row plus the layers that answer for it. Provenance is per
    # row rather than per key, and that falls straight out of wholesale config
    # replacement: exactly one layer is responsible for what a service receives.
    #
    # plugin_layer is tracked separately from config_layer because a patch may
    # swap plugin: without touching config:, and that swap is the single most
    # consequential edit the format allows — it is how the sandbox gets turned
    # off. Attributing it to the bundle that shipped the row would hide it.
    Row = Data.define(:id, :plugin, :config, :disabled, :row_layer, :plugin_layer, :config_layer)

    # A gem's config/bundle.yml, parsed. `requires` is this implementation's
    # answer to §2's "it has to make that code available": Bundler puts the
    # dependency on the load path, and these are the files that pull it in
    # before a row's constant has to resolve.
    #
    # `error` is set instead of raising when discovery cannot parse the file:
    # one third-party gem shipping a broken bundle must not break every profile
    # on the machine, only the profiles that name it.
    Bundle = Data.define(:name, :gem_name, :path, :requires, :rows, :error) do
      def self.broken(gem_name:, path:, error:)
        new(name: gem_name, gem_name: gem_name, path: path, requires: [], rows: [], error: error)
      end
    end

    Resolved = Data.define(:profile, :home, :rows, :settings, :plugins, :requires) do
      # Rows in the shape Hames::Loader#layer wants, tags evaluated. `plugin`
      # is still the class NAME: resolving the constant is boot's job, because
      # a row whose constant does not resolve is something doctor reports
      # rather than something a dump-config discovers halfway through.
      def materialize(allow_config_ruby: false)
        values = Composition.materialize_settings(settings, allow_config_ruby: allow_config_ruby)
        rows.map do |r|
          { id: r.id, plugin: r.plugin, disabled: r.disabled,
            config: Composition.materialize(r.config, settings: values,
                                                      allow_config_ruby: allow_config_ruby,
                                                      where: "row #{r.id.inspect} (config from #{r.config_layer})") }
        end
      end

      def row(id) = rows.find { |r| r.id == id.to_s }
    end

    # -- parsing ---------------------------------------------------------------

    # YAML.safe_load DROPS a local tag silently: permitted_classes gates
    # Ruby-object tags like !ruby/object:Foo, not application tags like !env,
    # so a document loaded that way comes back with the tag gone and the bare
    # scalar in its place — `!env OPENROUTER_API_KEY` would resolve to the
    # STRING "OPENROUTER_API_KEY" and boot a service with a literal nonsense
    # key. So resolution is explicit: parse to the node tree, then walk it and
    # resolve our three tags by tag, refusing every other one. The class loader
    # stays restricted throughout, so this is safe_load's safety with our tags
    # intercepted before Psych can drop them. YAML.load appears nowhere.
    class Visitor < Psych::Visitors::ToRuby
      def self.load(text, label:)
        stream = Psych.parse_stream(text)
        docs = stream.children
        if docs.length > 1
          raise Error, "#{label}: #{docs.length} YAML documents; a Terret config is one " \
                       "document, and the rest would be dropped without saying so"
        end
        return nil if docs.empty?

        value = new(label).accept(docs.first)
        Composition.assert_acyclic!(value, label)
        value
      rescue Error
        raise
      rescue StandardError => e
        # Psych's own exceptions, and the ArgumentError/FrozenError/NoMethodError
        # its schema handlers raise on input they cannot honour. Whatever it is,
        # the operator needs the file name more than the class.
        raise Error, "#{label}: #{e.class}: #{e.message}"
      end

      def initialize(label)
        loader = Psych::ClassLoader::Restricted.new([], [])
        super(Psych::ScalarScanner.new(loader), loader, symbolize_names: true)
        @label = label
      end

      def visit_Psych_Nodes_Scalar(node)
        tag = terret_tag(node, CORE_SCALAR_TAGS) or return super

        register(node, Tagged.new(tag: tag, argument: node.value))
      end

      # A collection carrying one of our tags is refused rather than silently
      # dropped, which is what the parent visitor does with one.
      def visit_Psych_Nodes_Mapping(node)
        refuse_collection_tag!(node)
        super
      end

      def visit_Psych_Nodes_Sequence(node)
        refuse_collection_tag!(node)
        super
      end

      private

      # nil for "not ours, and safe to hand to Psych's schema"; the tag name for
      # one of ours; an exception for everything else.
      def terret_tag(node, core_allowed)
        kind, name = Composition.tag_kind(node.tag)
        return nil if kind.nil?
        return name if kind == :local && TAGS.include?(name)
        return nil if kind == :core && core_allowed.include?(name)

        raise Error, refusal(name, node.tag, core_allowed)
      end

      def refuse_collection_tag!(node)
        name = terret_tag(node, CORE_COLLECTION_TAGS) or return

        raise Error, "#{@label}: !#{name} tags a scalar, not a collection"
      end

      def refusal(name, raw, core_allowed)
        hint =
          if TAGS.include?(name) then " — !#{name} is the tag you want, and #{raw} is a different one"
          elsif CORE_TAGS.include?(name) then " — !!#{name} does not describe this kind of node"
          else ""
          end
        "#{@label}: unknown config tag #{raw}#{hint}. Here a Terret config may use " \
          "!env, !setting and !ruby, and YAML's own #{core_allowed.join('/')}."
      end
    end

    # An alias can point at a node that contains it, and Psych builds the
    # self-referential Hash without complaint. Everything downstream walks the
    # structure, so the first walk would be the last thing the process did.
    #
    # `path` is the ancestor chain, which is what makes this a cycle check
    # rather than a sharing check — the same anchor twice as siblings is
    # legitimate YAML. `cleared` is what keeps it linear: without it, an alias
    # graph is walked once per PATH, and a two-dozen-line file whose aliases
    # each reference the previous one twice has 2^24 paths through 24 nodes.
    def self.assert_acyclic!(value, label, path = [], cleared = {}.compare_by_identity)
      return unless value.is_a?(Hash) || value.is_a?(Array)
      return if cleared.key?(value)
      raise Error, "#{label}: an alias cycle — a node that contains itself" if path.any? { |seen| seen.equal?(value) }

      path.push(value)
      (value.is_a?(Hash) ? value.values : value).each { |child| assert_acyclic!(child, label, path, cleared) }
      path.pop
      cleared[value] = true
    end

    def self.parse_file(path, label: nil)
      label ||= path
      raise Error, "#{label}: no such file" unless File.file?(path)

      Visitor.load(File.read(path), label: label) || {}
    end

    # Every file that carries rows carries them the same way. A patch that is a
    # bare list looks reasonable and is not: `rows:` is what distinguishes a
    # patch from the bundle format, which does accept one.
    def self.rows_in(doc, label)
      return [] if doc.nil?
      raise Error, "#{label}: expected a mapping with a rows: list, got #{doc.class}" unless doc.is_a?(Hash)

      rows = doc[:rows]
      return [] if rows.nil?
      raise Error, "#{label}: rows: must be a list, got #{rows.class}" unless rows.is_a?(Array)

      rows
    end

    # -- materialization -------------------------------------------------------

    # Walks a resolved structure and evaluates the tags left standing. `where`
    # is the row and layer this value came from: a refusal that cannot say
    # which of thirty rows it is about is a refusal an operator cannot act on,
    # and the !ruby refusal in particular is a consent prompt.
    def self.materialize(value, settings:, allow_config_ruby:, where: nil)
      case value
      when Tagged then resolve_tag(value, settings:, allow_config_ruby:, where:)
      when Hash
        value.to_h do |k, v|
          raise Error, "#{where}: #{k} is a tag in key position, which is never resolved" if k.is_a?(Tagged)

          [k, materialize(v, settings:, allow_config_ruby:, where:)]
        end
      when Array then value.map { |v| materialize(v, settings:, allow_config_ruby:, where:) }
      else value
      end
    end

    # settings: is resolved first and on its own terms — !env and !ruby are
    # fair game inside it, but a !setting there would be reaching into the map
    # it is part of, so it is refused rather than half-defined.
    def self.materialize_settings(settings, allow_config_ruby:)
      raise Error, "a profile's settings: must be a mapping, got #{settings.class}" unless settings.is_a?(Hash)

      materialize(settings, settings: nil, allow_config_ruby: allow_config_ruby,
                            where: "the profile's settings")
    end

    def self.resolve_tag(tagged, settings:, allow_config_ruby:, where: nil)
      case tagged.tag
      when "env" then read_env(tagged.argument, where)
      when "setting" then dig_setting(settings, tagged.argument, where)
      when "ruby" then eval_ruby(tagged.argument, allow_config_ruby, where)
      end
    end

    # nil rather than raising when unset, because "no key configured" is a
    # state a service should be allowed to have an opinion about. A name the OS
    # will not accept at all is a different thing and says so.
    def self.read_env(name, where)
      ENV[name]
    rescue StandardError => e
      raise Error, "#{where}: !env #{name.inspect}: #{e.message}"
    end

    # The asymmetry with !env is intentional (§5): an unset environment
    # variable is an ordinary deployment state, while a !setting pointing at
    # nothing is a typo in a file the profile author controls.
    def self.dig_setting(settings, path, where)
      raise Error, "#{where}: !setting #{path} may not appear inside a profile's own settings:" if settings.nil?

      keys = path.to_s.split(".").map(&:to_sym)
      raise Error, "#{where}: !setting with an empty path" if keys.empty?

      keys.reduce(settings) do |node, key|
        unless node.is_a?(Hash) && node.key?(key)
          raise Error, "#{where}: !setting #{path} resolves to nothing in the profile's settings"
        end

        node[key]
      end
    end

    # Config that can execute arbitrary Ruby is code with a YAML extension, so
    # the flag is the consent. A clean binding, because a profile downloaded
    # from anywhere should not be reading this method's locals either.
    def self.eval_ruby(source, allow_config_ruby, where)
      unless allow_config_ruby
        raise Error, "#{where}: !ruby #{source} is refused; pass allow_config_ruby: true " \
                     "(trt --allow-config-ruby) to let this profile run Ruby"
      end

      Object.new.instance_eval { binding }.eval(source, "(!ruby)")
    end

    # -- bundles ---------------------------------------------------------------

    # A bundle file is either a bare list of rows (§2's "an ordered list of
    # rows") or a mapping carrying that list plus a name and its requires.
    def self.load_bundle(path, gem_name:)
      doc = parse_file(path, label: gem_name)
      doc = { rows: doc } if doc.is_a?(Array)
      raise Error, "#{gem_name}: #{path} must be a list of rows or a mapping with rows:" unless doc.is_a?(Hash)

      Bundle.new(name: (doc[:name] || gem_name).to_s, gem_name: gem_name, path: path,
                 requires: Array(doc[:requires]).map(&:to_s), rows: rows_in(doc, gem_name), error: nil)
    end

    # Discovery scans loaded gemspecs for the metadata key and parses the
    # referenced file. A third-party gem becomes discoverable by shipping
    # normally — nothing to register, nothing to symlink.
    #
    # The meta-gem's own terret-base is seeded from this checkout first, so a
    # monorepo run resolves `terret` with no gem installation; an installed
    # terret gemspec then overwrites it with its own copy.
    def self.discover_bundles(specs: Gem::Specification)
      found = {}
      own = File.expand_path("../../config/bundle.yml", __dir__)
      found["terret"] = load_bundle(own, gem_name: "terret") if File.file?(own)

      # Everything about a third-party gem is quarantined to that gem. A
      # malformed bundle, an unreadable file, a metadata value of the wrong
      # shape: each becomes a broken entry that only the profiles naming it
      # ever see. One bad gem in the Gemfile must not take out every profile
      # on the machine, which is the whole reason discovery does not raise.
      specs.each do |spec|
        file = nil
        found[spec.name] = begin
          rel = bundle_metadata(spec)
          next unless rel.is_a?(String)

          root = File.expand_path(spec.full_gem_path.to_s)
          file = File.expand_path(rel, root)
          # A gem describes its own bundle, not somebody else's file.
          next unless file.start_with?("#{root}/") && File.file?(file)

          load_bundle(file, gem_name: spec.name)
        rescue StandardError => e
          Bundle.broken(gem_name: spec.name, path: file || "(unresolved)", error: e)
        end
      end
      found
    end

    # RubyGems requires every metadata VALUE to be a String — a gemspec
    # carrying the nested hash docs/composition.md §2 shows will not build
    # ("metadata['terret'] value must be a String"). So the shipped form is the
    # path on its own, and the documented nested form is still accepted, both
    # as a real Hash (an in-memory spec) and as YAML in the string.
    def self.bundle_metadata(spec)
      meta = begin
        spec.metadata["terret"]
      rescue StandardError
        nil # an unreadable gemspec is not a bundle; it is also not our problem
      end

      case meta
      when Hash then meta["bundle"] || meta[:bundle]
      when String
        parsed = begin
          YAML.safe_load(meta)
        rescue StandardError
          nil
        end
        parsed.is_a?(Hash) ? parsed["bundle"] : meta
      end
    end

    # -- resolution ------------------------------------------------------------

    # The four layers of §4, in order: every bundle in the profile's list,
    # the profile's patch.yml, the home patch.yml, then --patch overlays.
    # Later layers win.
    def self.resolve(profile:, home: nil, patches: [], bundles: nil)
      home = Home.resolve(home)
      spec = load_profile(home, profile)
      catalog = bundles || discover_bundles

      named = Array(spec[:bundles]).map(&:to_s)
      if (dupes = named.tally.select { |_, n| n > 1 }.keys).any?
        raise Error, "profile #{profile.to_s.inspect} lists #{dupes.join(', ')} more than once; " \
                     "a bundle is layered where it is named, and twice is not twice as much"
      end

      stacked = named.map do |name|
        bundle = catalog[name] or raise Error, unknown_bundle_message(profile, name, catalog)
        if bundle.error
          raise Error, "profile #{profile.to_s.inspect} names #{name}, whose #{bundle.path} " \
                       "could not be read: #{bundle.error.message}"
        end

        bundle
      end

      layers = stacked.map { |b| [bundle_label(b, stacked), :bundle, b.rows] }
      requires = stacked.flat_map(&:requires)

      patch_files(home, profile, patches).each do |file, label|
        layers << [label, :patch, rows_in(parse_file(file, label: label), label)]
      end

      Resolved.new(profile: profile.to_s, home: home, rows: stack(layers),
                   settings: spec[:settings] || {},
                   plugins: Array(spec[:plugins]).map(&:to_s), requires: requires.uniq)
    end

    # A profile is a directory name under the home, not a path. Anything that
    # would leave profiles/ is a typo at best.
    PROFILE_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    def self.load_profile(home, profile)
      unless PROFILE_NAME.match?(profile.to_s)
        raise Error, "#{profile.to_s.inspect} is not a profile name; a profile is a " \
                     "directory under #{home.path}/profiles"
      end

      config, = home.profile_files(profile)
      unless config
        raise Error, "no profile #{profile.to_s.inspect} in #{home.path} " \
                     "(looked for #{home.profile_config(profile)}); " \
                     "profiles available: #{home.profile_names.join(', ')}"
      end

      doc = parse_file(config, label: home.label(config))
      raise Error, "#{home.label(config)}: a profile must be a mapping" unless doc.is_a?(Hash)

      settings = doc[:settings]
      unless settings.nil? || settings.is_a?(Hash)
        raise Error, "#{home.label(config)}: settings: must be a mapping, got #{settings.class}"
      end

      doc
    end

    # A bundle names itself, and dump-config prints that name — so two bundles
    # in one stack claiming the same name would make provenance a guess. When
    # that happens, both fall back to naming the gem, which is the part a gem
    # author cannot claim on someone else's behalf.
    def self.bundle_label(bundle, stacked)
      return bundle.name if stacked.count { |b| b.name == bundle.name } == 1

      "#{bundle.gem_name} (#{bundle.name})"
    end

    def self.patch_files(home, profile, patches)
      _, profile_patch = home.profile_files(profile)
      files = []
      files << [profile_patch, home.label(profile_patch)] if profile_patch
      files << [home.patch, home.label(home.patch)] if File.file?(home.patch)
      # A --patch overlay is labelled by the path as given: it is what this
      # invocation decided, and the operator typed it.
      Array(patches).each { |p| files << [p.to_s, p.to_s] }
      files
    end

    def self.unknown_bundle_message(profile, name, catalog)
      "profile #{profile.to_s.inspect} names unknown bundle #{name.inspect}. " \
        "Discovered: #{catalog.keys.sort.join(', ')}. " \
        "A bundle that is installed but not loaded will not appear here."
    end

    # Fold the layers into one ordered row list. A bundle's rows append in
    # listed order; a patch's row either targets an existing id or is an
    # insertion that has to say where it goes.
    def self.stack(layers)
      ordered = []
      index = {}
      layers.each do |label, kind, rows|
        Array(rows).each { |raw| apply_row(ordered, index, label, kind, raw) }
      end
      ordered
    end

    def self.apply_row(ordered, index, label, kind, raw)
      raise Error, "#{label}: a config row must be a mapping, got #{raw.class}" unless raw.is_a?(Hash)

      id = raw[:id].to_s
      raise Error, "#{label}: a config row must have an id" if id.empty?

      if (existing = index[id])
        replace(ordered, index, label, existing, raw)
      elsif kind == :bundle
        append(ordered, index, label, id, raw)
      else
        insert(ordered, index, label, id, raw)
      end
    end

    # A patch targeting an existing id replaces that row's config WHOLESALE.
    # It never deep-merges: deep merging makes unsetting a key inexpressible,
    # and makes the effective value of any key a function of the entire stack.
    def self.replace(ordered, index, label, existing, raw)
      if raw.key?(:before) || raw.key?(:after)
        raise Error, "#{label}: row #{existing.id.inspect} already exists " \
                     "(from #{existing.row_layer}); before:/after: only positions a new row"
      end

      updated = existing.with(
        plugin: raw.key?(:plugin) ? raw[:plugin].to_s : existing.plugin,
        plugin_layer: raw.key?(:plugin) ? label : existing.plugin_layer,
        config: raw.key?(:config) ? config_of(label, existing.id, raw) : existing.config,
        disabled: raw.key?(:disabled) ? boolean(label, existing.id, raw[:disabled]) : existing.disabled,
        config_layer: raw.key?(:config) ? label : existing.config_layer
      )
      ordered[ordered.index(existing)] = updated
      index[existing.id] = updated
    end

    def self.append(ordered, index, label, id, raw)
      row = build(label, id, raw)
      ordered << row
      index[id] = row
    end

    # Position matters for reasons the loader's dependency ordering does not
    # cover — two tools/pre_execute listeners have an order, and that order is
    # policy. So an insertion without an anchor, or with an anchor naming a row
    # that is not in the stack, fails closed rather than landing somewhere
    # plausible.
    def self.insert(ordered, index, label, id, raw)
      if raw.key?(:after) && raw.key?(:before)
        raise Error, "#{label}: row #{id.inspect} names both before: and after:; it goes in one place"
      end

      anchor_id, offset = if raw.key?(:after) then [raw[:after].to_s, 1]
                          elsif raw.key?(:before) then [raw[:before].to_s, 0]
                          end
      unless anchor_id
        raise Error, "#{label}: row #{id.inspect} is new and must say where it goes " \
                     "with before: or after: naming an existing row"
      end

      anchor = index[anchor_id]
      unless anchor
        raise Error, "#{label}: row #{id.inspect} anchors #{raw.key?(:after) ? 'after' : 'before'} " \
                     "#{anchor_id.inspect}, which is not in the stack"
      end

      row = build(label, id, raw)
      ordered.insert(ordered.index(anchor) + offset, row)
      index[id] = row
    end

    def self.build(label, id, raw)
      raise Error, "#{label}: row #{id.inspect} has no plugin:" unless raw[:plugin]

      Row.new(id: id, plugin: raw[:plugin].to_s, config: config_of(label, id, raw),
              disabled: boolean(label, id, raw[:disabled]), row_layer: label,
              plugin_layer: label, config_layer: label)
    end

    def self.config_of(label, id, raw)
      config = raw[:config]
      return {} if config.nil?
      raise Error, "#{label}: row #{id.inspect}: config: must be a mapping, got #{config.class}" unless config.is_a?(Hash)

      config
    end

    # A real boolean, not any truthy scalar. `disabled: "false"` reads as off
    # and would mean on, and this is the key that decides whether the approvals
    # row mounts.
    def self.boolean(label, id, value)
      return false if value.nil?
      return value if value == true || value == false

      raise Error, "#{label}: row #{id.inspect}: disabled: must be true or false, got #{value.inspect}"
    end
  end
end
