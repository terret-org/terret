Gem::Specification.new do |s|
  s.name = "terret-sandbox-docker"
  s.version = "0.1.0"
  s.summary = "The container sandbox provider for Terret"
  s.description = "ctx[:sandbox] backed by a long-lived container: one patch row " \
                  "swaps this plugin in and every argv the harness spawns — Bash, " \
                  "Grep, the PTY tools — starts running inside it, with no change " \
                  "to any tool. The workspace is bind-mounted at its own realpath, " \
                  "so host-side file ops and in-container processes see one world " \
                  "at one set of paths; the network is denied by default. Shells " \
                  "out to the docker CLI, so there are no runtime dependencies " \
                  "beyond stdlib."
  s.authors = ["Obie Fernandez"]
  s.email = ["obiefernandez@gmail.com"]
  s.homepage = "https://terret.org"
  s.license = "MIT"
  s.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb"] }
  s.required_ruby_version = ">= 4.0"
  # terret-core alone: this gem PROVIDES the ctx[:sandbox] seam rather than
  # consuming one, so it needs the kernel and the Failure vocabulary and
  # nothing from terret-exec. A profile mounting this row without terret-exec
  # has a sandbox and nothing to sandbox, which is a profile's mistake to make.
  s.add_dependency "terret-core", "~> 0.1"
  s.metadata = {
    "homepage_uri" => "https://terret.org",
    "source_code_uri" => "https://github.com/terret-org/terret",
    "bug_tracker_uri" => "https://github.com/terret-org/terret/issues",
    "rubygems_mfa_required" => "true"
  }
end
