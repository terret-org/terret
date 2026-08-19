Gem::Specification.new do |s|
  s.name = "terret-tools-std"
  s.version = "0.1.0"
  s.summary = "The standard tool roster for Terret agents"
  s.description = "Claude Code's tool names, verbatim wherever it has one: Read, Write, " \
                  "Edit, Glob, Grep, Bash, WebFetch, Task and TodoWrite, plus snake_case " \
                  "terminal_* and job_* for the seams it has no equivalent for — all " \
                  "registered on ctx[:tools] with honest mutating/approval/concurrency " \
                  "metadata. Every handler reaches the world only through a seam, so " \
                  "swapping the sandbox row moves the whole roster into a container " \
                  "untouched. Zero runtime dependencies beyond stdlib; ripgrep is used " \
                  "as a fast path when it is present."
  s.authors = ["Obie Fernandez"]
  s.email = ["obiefernandez@gmail.com"]
  s.homepage = "https://terret.org"
  s.license = "MIT"
  s.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb"] }
  s.required_ruby_version = ">= 4.0"
  s.add_dependency "terret-core", "~> 0.1"
  # The roster is nothing but seam calls, but the seams it needs (ctx[:fs],
  # and ctx[:shell]/ctx[:terminals] as the roster grows) have exactly one
  # provider today: a profile that installs this gem without terret-exec gets
  # a service that can never mount.
  s.add_dependency "terret-exec", "~> 0.1"
  s.metadata = {
    "homepage_uri" => "https://terret.org",
    "source_code_uri" => "https://github.com/terret-org/terret",
    "bug_tracker_uri" => "https://github.com/terret-org/terret/issues",
    "rubygems_mfa_required" => "true"
  }
end
