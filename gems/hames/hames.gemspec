Gem::Specification.new do |s|
  s.name = "hames"
  s.version = "0.1.0"
  s.summary = "Plugin kernel: services, typed events, reversible effects"
  s.description = "Hames is a small plugin kernel for Ruby: services resolved by key " \
                  "in a context, typed events with four dispatch modes enforced at " \
                  "runtime, reversible registrations, and dependency-driven boot. It " \
                  "has no knowledge of LLMs and is reusable for any plugin-composed " \
                  "application. It is the kernel underneath the Terret agent harness."
  s.authors = ["Obie Fernandez"]
  s.email = ["obiefernandez@gmail.com"]
  s.homepage = "https://terret.org"
  s.license = "MIT"
  s.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb"] }
  s.required_ruby_version = ">= 4.0"
  s.metadata = {
    "homepage_uri" => "https://terret.org",
    "source_code_uri" => "https://github.com/terret-org/terret",
    "bug_tracker_uri" => "https://github.com/terret-org/terret/issues",
    "rubygems_mfa_required" => "true"
  }
end
