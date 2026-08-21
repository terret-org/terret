Gem::Specification.new do |s|
  s.name = "terret-core"
  s.version = "0.1.1"
  s.summary = "Terret agent harness core: session log, tools pipeline, agent loop"
  s.description = "The core of the Terret agent harness: an append-only session log " \
                  "that is the single source of model-visible truth, a scoped tool " \
                  "registry with a vetoable execution pipeline, the agent turn/step " \
                  "loop as a replaceable plugin, and a provider-neutral LLM seam."
  s.authors = ["Obie Fernandez"]
  s.email = ["obiefernandez@gmail.com"]
  s.homepage = "https://terret.org"
  s.license = "MIT"
  s.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb"] }
  s.required_ruby_version = ">= 4.0"
  s.add_dependency "hames", "~> 0.1"
  s.metadata = {
    "homepage_uri" => "https://terret.org",
    "source_code_uri" => "https://github.com/terret-org/terret",
    "bug_tracker_uri" => "https://github.com/terret-org/terret/issues",
    "rubygems_mfa_required" => "true"
  }
end
