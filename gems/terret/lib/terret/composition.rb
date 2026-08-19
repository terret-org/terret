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

    # A tag left standing. Resolution keeps these unevaluated so dump-config
    # can print `!env OPENROUTER_API_KEY` as written — the resolved value never
    # appears in that output at all. Boot materializes them; nothing else does.
    Tagged = Data.define(:tag, :argument) do
      def to_s = "!#{tag} #{argument}"
    end

    # One resolved row plus the layers that answer for it. Provenance is per
    # row rather than per key, and that falls straight out of wholesale config
    # replacement: exactly one layer is responsible for what a service receives.
    Row = Data.define(:id, :plugin, :config, :disabled, :row_layer, :config_layer)

    # A gem's config/bundle.yml, parsed. `requires` is this implementation's
    # answer to §2's "it has to make that code available": Bundler puts the
    # dependency on the load path, and these are the files that pull it in
    # before a row's constant has to resolve.
    Bundle = Data.define(:name, :gem_name, :path, :requires, :rows)

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
                                                      allow_config_ruby: allow_config_ruby) }
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
        node = Psych.parse(text)
        return nil unless node

        new(label).accept(node)
      rescue Psych::Exception => e
        raise Error, "#{label}: #{e.class}: #{e.message}"
      end

      def initialize(label)
        loader = Psych::ClassLoader::Restricted.new([], [])
        super(Psych::ScalarScanner.new(loader), loader, symbolize_names: true)
        @label = label
      end

      def visit_Psych_Nodes_Scalar(node) # rubocop:disable Naming/MethodName
        tag = local_tag(node) or return super

        register(node, Tagged.new(tag: tag, argument: node.value))
      end

      # A collection carrying a local tag is refused rather than silently
      # dropped, which is what the parent visitor does with one.
      def visit_Psych_Nodes_Mapping(node) # rubocop:disable Naming/MethodName
        refuse_collection_tag!(node)
        super
      end

      def visit_Psych_Nodes_Sequence(node) # rubocop:disable Naming/MethodName
        refuse_collection_tag!(node)
        super
      end

      private

      # nil for "no tag of ours here, let Psych's safe schema have it"; the tag
      # name for one of ours; an exception for anything else, including
      # !ruby/object:Foo, which is refused by name before the class loader
      # would have refused it by class.
      def local_tag(node)
        raw = node.tag
        return nil if raw.nil? || !raw.start_with?("!") || raw.start_with?("!!")

        name = raw.delete_prefix("!")
        return name if TAGS.include?(name)

        raise Error, "#{@label}: unknown config tag !#{name}; a Terret config " \
                     "may only use !env, !setting and !ruby"
      end

      def refuse_collection_tag!(node)
        raw = node.tag
        return if raw.nil? || !raw.start_with?("!") || raw.start_with?("!!")

        name = raw.delete_prefix("!")
        raise Error, "#{@label}: #{TAGS.include?(name) ? "!#{name} tags a scalar, not a collection" : "unknown config tag !#{name}"}"
      end
    end

    def self.parse_file(path, label: nil)
      label ||= path
      raise Error, "#{label}: no such file" unless File.file?(path)

      Visitor.load(File.read(path), label: label) || {}
    end

    # -- materialization -------------------------------------------------------

    # Walks a resolved structure and evaluates the tags left standing.
    def self.materialize(value, settings:, allow_config_ruby:)
      case value
      when Tagged then resolve_tag(value, settings: settings, allow_config_ruby: allow_config_ruby)
      when Hash   then value.to_h { |k, v| [k, materialize(v, settings:, allow_config_ruby:)] }
      when Array  then value.map { |v| materialize(v, settings:, allow_config_ruby:) }
      else value
      end
    end

    # settings: is resolved first and on its own terms — !env and !ruby are
    # fair game inside it, but a !setting there would be reaching into the map
    # it is part of, so it is refused rather than half-defined.
    def self.materialize_settings(settings, allow_config_ruby:)
      materialize(settings, settings: nil, allow_config_ruby: allow_config_ruby)
    end

    def self.resolve_tag(tagged, settings:, allow_config_ruby:)
      case tagged.tag
      when "env" then ENV[tagged.argument]
      when "setting" then dig_setting(settings, tagged.argument)
      when "ruby" then eval_ruby(tagged.argument, allow_config_ruby)
      end
    end

    # The asymmetry with !env is intentional (§5): an unset environment
    # variable is an ordinary deployment state, while a !setting pointing at
    # nothing is a typo in a file the profile author controls.
    def self.dig_setting(settings, path)
      raise Error, "!setting #{path} may not appear inside a profile's own settings:" if settings.nil?

      keys = path.to_s.split(".").map(&:to_sym)
      raise Error, "!setting with an empty path" if keys.empty?

      node = settings
      keys.each do |k|
        raise Error, "!setting #{path} resolves to nothing in the profile's settings" unless node.is_a?(Hash) && node.key?(k)

        node = node[k]
      end
      node
    end

    # Config that can execute arbitrary Ruby is code with a YAML extension, so
    # the flag is the consent. A clean binding, because a profile downloaded
    # from anywhere should not be reading this method's locals either.
    def self.eval_ruby(source, allow_config_ruby)
      unless allow_config_ruby
        raise Error, "!ruby #{source} is refused; pass allow_config_ruby: true " \
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
                 requires: Array(doc[:requires]).map(&:to_s), rows: Array(doc[:rows]))
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

      specs.each do |spec|
        rel = bundle_metadata(spec) or next
        file = File.expand_path(rel, spec.full_gem_path)
        found[spec.name] = load_bundle(file, gem_name: spec.name) if File.file?(file)
      end
      found
    end

    # RubyGems requires every metadata VALUE to be a String — a gemspec
    # carrying the nested hash docs/composition.md §2 shows will not build
    # ("metadata['terret'] value must be a String"). So the shipped form is the
    # path on its own, and the documented nested form is still accepted, both
    # as a real Hash (an in-memory spec) and as YAML in the string.
    def self.bundle_metadata(spec)
      meta = spec.metadata["terret"]
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
    rescue StandardError
      nil
    end

    # -- resolution ------------------------------------------------------------

    # The four layers of §4, in order: every bundle in the profile's list,
    # the profile's patch.yml, the home patch.yml, then --patch overlays.
    # Later layers win.
    def self.resolve(profile:, home: nil, patches: [], bundles: nil)
      home = Home.resolve(home)
      spec = load_profile(home, profile)
      catalog = bundles || discover_bundles

      layers = []
      requires = []
      Array(spec[:bundles]).map(&:to_s).each do |name|
        bundle = catalog[name] or raise Error, unknown_bundle_message(profile, name, catalog)
        layers << [bundle.name, :bundle, bundle.rows]
        requires.concat(bundle.requires)
      end

      patch_files(home, profile, spec, patches).each do |file, label|
        layers << [label, :patch, Array(parse_file(file, label: label)[:rows])]
      end

      Resolved.new(profile: profile.to_s, home: home, rows: stack(layers),
                   settings: spec[:settings] || {},
                   plugins: Array(spec[:plugins]).map(&:to_s), requires: requires.uniq)
    end

    def self.load_profile(home, profile)
      config, = home.profile_files(profile)
      unless config
        raise Error, "no profile #{profile.to_s.inspect} in #{home.path} " \
                     "(looked for #{home.profile_config(profile)}); " \
                     "profiles available: #{home.profile_names.join(', ')}"
      end

      doc = parse_file(config, label: home.label(config))
      raise Error, "#{home.label(config)}: a profile must be a mapping" unless doc.is_a?(Hash)

      doc
    end

    def self.patch_files(home, profile, _spec, patches)
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
        config: raw.key?(:config) ? (raw[:config] || {}) : existing.config,
        disabled: raw.key?(:disabled) ? !!raw[:disabled] : existing.disabled,
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

      Row.new(id: id, plugin: raw[:plugin].to_s, config: raw[:config] || {},
              disabled: !!raw[:disabled], row_layer: label, config_layer: label)
    end
  end
end
