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
    # reconfigure!/unload! on the composition it just booted.
    def loader
      require_code!
      Hames::Loader.new.layer(rows)
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

    # Take a booted context down the way the demos do: the long-lived things
    # first, then every reversible registration. Best-effort by design — this
    # runs on the way out, including out of a failure.
    def self.shutdown(ctx)
      ctx[:shell].close_all     if ctx.service?(:shell)
      ctx[:terminals].close_all if ctx.service?(:terminals)
      ctx[:jobs].stop_all       if ctx.service?(:jobs)
      ctx[:sandbox].stop        if ctx.service?(:sandbox) && ctx[:sandbox].isolated?
      ctx.dispose!
    rescue StandardError => e
      warn "terret: shutdown: #{e.class}: #{e.message}"
    end
  end
end
