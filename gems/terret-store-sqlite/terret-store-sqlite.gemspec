Gem::Specification.new do |s|
  s.name = "terret-store-sqlite"
  s.version = "0.1.0"
  s.summary = "SQLite session store for the Terret agent harness"
  s.description = "Durable session persistence for Terret: the append-only " \
                  "session log stored one event per row in SQLite (WAL mode), " \
                  "behind the ctx[:session_store] seam, so sessions survive " \
                  "process restarts with byte-identical derived context."
  s.authors = ["Obie Fernandez"]
  s.email = ["obiefernandez@gmail.com"]
  s.homepage = "https://terret.org"
  s.license = "MIT"
  s.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb"] }
  s.required_ruby_version = ">= 4.0"
  s.add_dependency "terret-core", "~> 0.1"
  s.add_dependency "sqlite3", "~> 2.9"
  s.metadata = {
    "homepage_uri" => "https://terret.org",
    "source_code_uri" => "https://github.com/terret-org/terret",
    "bug_tracker_uri" => "https://github.com/terret-org/terret/issues",
    "rubygems_mfa_required" => "true"
  }
end
