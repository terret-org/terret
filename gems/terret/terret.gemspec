Gem::Specification.new do |s|
  s.name = "terret"
  s.version = "0.0.1"
  s.summary = "Ruby-native, model-agnostic agent harness (name placeholder)"
  s.description = "Placeholder release. Terret is a Ruby-native, model-agnostic agent " \
                  "harness where everything is a plugin. This meta-gem will carry the " \
                  "trt CLI, profiles, and boot; none of that is written yet. The " \
                  "working code is in terret-core and hames."
  s.authors = ["Obie Fernandez"]
  s.email = ["obiefernandez@gmail.com"]
  s.homepage = "https://terret.org"
  s.license = "MIT"
  s.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb"] }
  s.required_ruby_version = ">= 4.0"
  s.add_dependency "terret-core", "~> 0.1"
  s.metadata = {
    "homepage_uri" => "https://terret.org",
    "source_code_uri" => "https://github.com/terret-org/terret",
    "bug_tracker_uri" => "https://github.com/terret-org/terret/issues",
    "rubygems_mfa_required" => "true"
  }
end
