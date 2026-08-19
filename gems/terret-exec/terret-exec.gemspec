Gem::Specification.new do |s|
  s.name = "terret-exec"
  s.version = "0.1.0"
  s.summary = "The execution-world gem for Terret: workspace-scoped filesystem and process seams"
  s.description = "ctx[:fs]: workspace-contained file ops (read/write/edit/stat/glob) " \
                  "behind an fs/authorize waterfall, with realpath-based containment " \
                  "that fails closed on traversal and symlink escapes. ctx[:subprocess] " \
                  "spawns and captures under the fiber scheduler with cooperative " \
                  "cancellation; ctx[:shell] keeps a bash per agent alive across calls; " \
                  "ctx[:terminals] holds named long-lived PTYs; and every argv reaches a " \
                  "process through the ctx[:sandbox] seam. Zero runtime dependencies " \
                  "beyond stdlib."
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
