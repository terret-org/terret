# frozen_string_literal: true

require "rubygems"

module Release
  # The order the gems must be built and pushed in for a release. A gem's
  # dependencies have to be on RubyGems before it is, or `gem install terret`
  # resolves against versions that do not exist yet — so this is a topological
  # sort of the in-repo dependency graph: hames first, the terret meta-gem last,
  # every gem after the ones it depends on.
  #
  # The graph is read off the gemspecs themselves rather than hard-coded, so it
  # cannot drift from what the gems actually require. Pure and network-free by
  # design: the "is this version already on RubyGems" check lives in the
  # release:push task, not here, so the ordering stays unit-testable with no
  # network.
  module Ordering
    module_function

    ROOT = File.expand_path("..", __dir__)

    # Every gemspec in the repo, loaded so its declared dependencies are
    # authoritative. Sorted by path for a deterministic starting point.
    def specs
      Dir[File.join(ROOT, "gems", "*", "*.gemspec")].sort.map do |path|
        Gem::Specification.load(path)
      end
    end

    # name => the in-repo gems it depends on. External dependencies
    # (async-http, sqlite3, manceps, async-websocket) are not ours to publish,
    # so they are not edges in this graph.
    def graph(specs = self.specs)
      names = specs.map(&:name)
      specs.each_with_object({}) do |spec, acc|
        acc[spec.name] = spec.runtime_dependencies.map(&:name).select { |n| names.include?(n) }
      end
    end

    # A deterministic topological sort (Kahn's algorithm): repeatedly emit the
    # gems whose dependencies are all already emitted, in name order so the
    # result is stable. Raises on a cycle rather than looping forever.
    def order(graph = self.graph)
      remaining = graph.transform_values(&:dup)
      emitted = []
      until remaining.empty?
        ready = remaining.select { |_, deps| deps.all? { |d| emitted.include?(d) } }.keys.sort
        raise "dependency cycle among: #{remaining.keys.sort.join(', ')}" if ready.empty?

        emitted.concat(ready)
        ready.each { |name| remaining.delete(name) }
      end
      emitted
    end

    # The loaded specs in build/push order — what the Rakefile iterates to build
    # each gem and push it, carrying the gemspec path (spec.loaded_from) and
    # version with it.
    def ordered_specs(specs = self.specs)
      by_name = specs.each_with_object({}) { |s, h| h[s.name] = s }
      order(graph(specs)).map { |name| by_name.fetch(name) }
    end
  end
end
