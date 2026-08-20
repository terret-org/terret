Gem::Specification.new do |s|
  s.name = "terret-acp"
  s.version = "0.1.0"
  s.summary = "Agent Client Protocol server for the Terret agent harness"
  s.description = "The second interface (plan §9.1): an ACP v1 server so an " \
                  "editor can drive a Terret agent over JSON-RPC 2.0 on stdio. " \
                  "Newline-delimited framing, session/new spawns a durable " \
                  "agent, session/prompt pends the whole turn, session/update " \
                  "notifications projected from the session log. Consumes the " \
                  "same two seams the socket does with no change to core, which " \
                  "is the standing proof that the interface is not privileged. " \
                  "Zero runtime dependencies beyond stdlib json."
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
