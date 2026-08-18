Gem::Specification.new do |s|
  s.name = "terret-morph"
  s.version = "0.1.0"
  s.summary = "Morph-backed context compaction for Terret"
  s.description = "ctx[:summarizer] backed by Morph's Compact API: extractive " \
                  "line-level compression (surviving lines byte-identical), " \
                  "wire mirrored from the deployed agora integration. Zero " \
                  "runtime dependencies beyond stdlib net/http."
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
