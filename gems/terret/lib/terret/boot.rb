# frozen_string_literal: true

# Running from a source checkout, the sibling gems are not on the load path;
# a `gem install` puts them there. Seeding them here is what lets a bundle's
# `requires:` name `terret/exec` and resolve identically in both worlds, and it
# is the same monorepo path-source affordance every other gem's entry file
# makes for terret-core.
gems_root = File.expand_path("../../..", __dir__)
if File.directory?(File.join(gems_root, "terret-core", "lib"))
  # One unshift, so the sibling libs keep the order they are listed in rather
  # than the reverse of it.
  $LOAD_PATH.unshift(*Dir.children(gems_root).sort
                        .map { |gem_dir| File.join(gems_root, gem_dir, "lib") }
                        .select { |lib| File.directory?(lib) && !$LOAD_PATH.include?(lib) })
end

require "terret"

require_relative "version"
require_relative "home"
require_relative "composition"
require_relative "doctor"
require_relative "cli"

module Terret
  # Resolve the layers, hand the row list to the Hames loader, return the
  # booted context (docs/composition.md §7). That is the whole surface, and its
  # shape is the embeddability goal made concrete: a Rails app calls this in an
  # initializer and holds the ctx, with no process to supervise and no socket
  # to speak.
  def self.boot(profile:, patches: [], allow_config_ruby: false, home: nil)
    Boot.new(Composition.resolve(profile: profile, home: home, patches: patches),
             allow_config_ruby: allow_config_ruby).boot!
  end

  # The impure half: requiring the code a composition names, turning plugin
  # names into constants, and mounting. Split out from Composition so the pure
  # half stays runnable on a machine with none of this installed.
  class Boot
    Error = Class.new(StandardError)

    attr_reader :resolved, :allow_config_ruby

    def initialize(resolved, allow_config_ruby: false)
      @resolved = resolved
      @allow_config_ruby = allow_config_ruby
    end

    def boot! = loader.boot!

    # The loader rather than the context, for a caller that wants
    # reconfigure!/unload! on the composition it just booted. Memoized, because
    # a second loader would be a second context: `b.loader` then `b.boot!`
    # would hand back two unrelated worlds built from the same rows.
    def loader
      @loader ||= begin
        require_code!
        built = Hames::Loader.new.layer(rows)
        # Reachable from the context it boots. Terret.boot returns the ctx and
        # nothing else, so without this a caller holding one has no way to
        # reconfigure a row, unload one, or shut the composition down through
        # the services' own stop hooks.
        built.ctx.register_service(:loader, built)
        built
      end
    end

    def rows
      @rows ||= resolved.materialize(allow_config_ruby: allow_config_ruby)
                        .map { |row| row.merge(plugin: constantize(row[:plugin], row[:id])) }
    end

    # A bundle's requires first, then the profile's own `plugins:` — code that
    # is not a bundle loads last so it can reopen what a bundle defined.
    def require_code!
      (resolved.requires + resolved.plugins).each do |file|
        require file
      rescue LoadError => e
        raise Error, "profile #{resolved.profile.inspect} needs #{file.inspect}, " \
                     "which is not on the load path (#{e.message}). Is the gem " \
                     "that ships it in your Gemfile?"
      end
    end

    def constantize(name, id)
      klass = Object.const_get(name)
      unless klass.is_a?(Class) && klass.method_defined?(:apply)
        raise Error, "row #{id.inspect}: #{name} is not a plugin — a plugin is a " \
                     "class whose instances respond to #apply(ctx), which is what " \
                     "subclassing Hames::Service gives you"
      end

      klass
    rescue NameError
      raise Error, "row #{id.inspect}: no such plugin #{name}. The constant did not " \
                   "resolve, so either the name is wrong or the gem that defines it " \
                   "is not required by any bundle in this profile."
    end

    # Take a booted context down through the loader, so every row's own stop
    # hook runs: the shell closes its bash, the sandbox discards its container,
    # the SQLite store closes its handle. A hand-written list of seams runs
    # none of the hooks it does not happen to name, and grows a hole every time
    # a bundle mounts something new.
    #
    # Reverse declaration order, so the session store — which everything else
    # may still be writing to — closes last.
    #
    # Best-effort means each step is separately best-effort. One wedged seam
    # aborting the rest is how a container survives the process that owned it.
    def self.shutdown(ctx)
      loader = ctx[:loader] if ctx.service?(:loader)
      loader&.rows&.values&.reject(&:disabled)&.reverse_each do |row|
        step("row #{row.id}") { loader.unload!(row.id) }
      end
      step("dispose") { ctx.dispose! }
    end

    def self.step(what)
      yield
    rescue StandardError => e
      warn "terret: shutdown: #{what}: #{e.class}: #{e.message}"
    end
  end
end
