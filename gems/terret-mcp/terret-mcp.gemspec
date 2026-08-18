Gem::Specification.new do |s|
  s.name = "terret-mcp"
  s.version = "0.1.0"
  s.summary = "MCP client plugin for the Terret agent harness"
  s.description = "Mounts Model Context Protocol servers (stdio and streamable " \
                  "HTTP, via the manceps client) as namespaced tool sources " \
                  "behind ctx.tools, with per-server approval policy, per-call " \
                  "timeouts, and live tool-list reconciliation."
  s.authors = ["Obie Fernandez"]
  s.email = ["obiefernandez@gmail.com"]
  s.homepage = "https://terret.org"
  s.license = "MIT"
  s.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb"] }
  s.required_ruby_version = ">= 4.0"
  s.add_dependency "terret-core", "~> 0.1"
  s.add_dependency "manceps", "~> 1.0"
  s.metadata = {
    "homepage_uri" => "https://terret.org",
    "source_code_uri" => "https://github.com/terret-org/terret",
    "bug_tracker_uri" => "https://github.com/terret-org/terret/issues",
    "rubygems_mfa_required" => "true"
  }
end
