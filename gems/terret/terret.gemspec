require_relative "lib/terret/version"

Gem::Specification.new do |s|
  s.name = "terret"
  s.version = Terret::Meta::VERSION
  s.summary = "Ruby-native, model-agnostic agent harness: profiles, boot, and the trt CLI"
  s.description = "The meta-gem, and the way a Terret is composed. Bundles ship " \
                  "ordered config rows, profiles stack bundles, patches adjust " \
                  "rows by id, and Terret.boot hands the result to the Hames " \
                  "loader -- so which plugins run, in what order, with what " \
                  "config is a question YAML answers rather than Ruby. Ships " \
                  "terret-base (the log, the harness, the model seam, the " \
                  "execution world sandboxed with the network denied, the " \
                  "standard tool roster, and a policy floor that starts closed), " \
                  "the headless profile template, and trt: boot, dump-config, " \
                  "doctor."
  s.authors = ["Obie Fernandez"]
  s.email = ["obiefernandez@gmail.com"]
  s.homepage = "https://terret.org"
  s.license = "MIT"
  s.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "config/*.yml", "profiles/**/*.yml"] }
  s.bindir = "exe"
  s.executables = ["trt"]
  s.required_ruby_version = ">= 4.0"

  # A bundle does not have to contain the code its rows mount -- it has to make
  # that code available, which for a Ruby gem means depending on the gems the
  # rows name. These six are what config/bundle.yml resolves against.
  s.add_dependency "terret-core", "~> 0.1"
  s.add_dependency "terret-exec", "~> 0.1"
  s.add_dependency "terret-openrouter", "~> 0.1"
  s.add_dependency "terret-sandbox-docker", "~> 0.1"
  s.add_dependency "terret-store-sqlite", "~> 0.1"
  s.add_dependency "terret-tools-std", "~> 0.1"

  s.metadata = {
    "homepage_uri" => "https://terret.org",
    "source_code_uri" => "https://github.com/terret-org/terret",
    "bug_tracker_uri" => "https://github.com/terret-org/terret/issues",
    "rubygems_mfa_required" => "true",
    # How a gem declares itself a bundle. Discovery scans loaded gemspecs for
    # this key and parses the file it points at -- gem install is already the
    # install step and Gemfile is already the manifest, so a third-party bundle
    # becomes discoverable by shipping normally. RubyGems requires every
    # metadata value to be a String, hence the bare path.
    "terret" => "config/bundle.yml"
  }
end
