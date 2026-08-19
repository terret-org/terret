# frozen_string_literal: true

module Terret
  # Terret home: where profiles live (docs/composition.md §3).
  #
  #   ~/.terret/
  #   ├── patch.yml                  # applies to every profile
  #   └── profiles/<name>/{profile.yml,patch.yml}
  #
  # TERRET_HOME overrides ~/.terret wholesale, which is what makes the layer
  # stack testable — every composition test points it at a tmpdir — and what
  # lets a deployment ship a home directory as an artifact rather than as
  # instructions for populating a user's dotfiles.
  #
  # A home that does not hold the named profile falls back to the templates
  # this gem ships (gems/terret/profiles), so `trt boot --profile headless`
  # works on a machine whose home is empty. The home always wins where it has
  # an opinion; the shipped templates are only the floor.
  class Home
    DEFAULT = "~/.terret"
    SHIPPED = File.expand_path("../../profiles", __dir__)

    # ENV is read here rather than at load time so a test can set TERRET_HOME
    # after this file is required.
    def self.resolve(path = nil)
      return path if path.is_a?(Home)

      env = ENV["TERRET_HOME"]
      env = nil if env.nil? || env.empty?
      new(path || env || DEFAULT)
    end

    attr_reader :path

    def initialize(path)
      @path = File.expand_path(path.to_s)
    end

    def patch = File.join(path, "patch.yml")
    def profile_dir(name) = File.join(path, "profiles", name.to_s)
    def profile_config(name) = File.join(profile_dir(name), "profile.yml")
    def profile_patch(name) = File.join(profile_dir(name), "patch.yml")

    def shipped_profile_dir(name) = File.join(SHIPPED, name.to_s)
    def shipped_profile_config(name) = File.join(shipped_profile_dir(name), "profile.yml")
    def shipped_profile_patch(name) = File.join(shipped_profile_dir(name), "patch.yml")

    # The pair of files a profile resolves to, home first and the shipped
    # template as the floor. Either may be nil; a profile with neither does
    # not exist.
    def profile_files(name)
      config = [profile_config(name), shipped_profile_config(name)].find { |f| File.file?(f) }
      patch  = config == shipped_profile_config(name) ? shipped_profile_patch(name) : profile_patch(name)
      [config, (patch if File.file?(patch))]
    end

    # Profile names offered by this home and by the shipped templates.
    def profile_names
      [File.join(path, "profiles"), SHIPPED]
        .flat_map { |d| Dir.glob(File.join(d, "*", "profile.yml")) }
        .map { |f| File.basename(File.dirname(f)) }
        .uniq.sort
    end

    # dump-config prints these, so they are home-relative rather than absolute:
    # a command whose whole purpose is "show me my config" should be safe to
    # paste into an issue, and an absolute path names the operator.
    def label(file)
      f = file.to_s
      return f.delete_prefix("#{path}/") if f.start_with?("#{path}/")
      return "terret:#{f.delete_prefix("#{SHIPPED}/")}" if f.start_with?("#{SHIPPED}/")

      f
    end

    def to_s = path
    def ==(other) = other.is_a?(Home) && other.path == path
    alias eql? ==
    def hash = path.hash
  end
end
