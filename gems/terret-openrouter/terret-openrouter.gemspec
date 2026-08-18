Gem::Specification.new do |s|
  s.name = "terret-openrouter"
  s.version = "0.1.0"
  s.summary = "OpenRouter adapter for the Terret agent harness"
  s.description = "The one v1 model adapter for Terret: OpenRouter is " \
                  "OpenAI-compatible, so a single streaming implementation reaches " \
                  "the whole model space behind the provider-neutral ctx.llm seam. " \
                  "SSE streaming with tool calling, usage accounting, and retry " \
                  "with jittered backoff."
  s.authors = ["Obie Fernandez"]
  s.email = ["obiefernandez@gmail.com"]
  s.homepage = "https://terret.org"
  s.license = "MIT"
  s.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb"] }
  s.required_ruby_version = ">= 4.0"
  s.add_dependency "terret-core", "~> 0.1"
  s.add_dependency "async-http", ">= 0.94"
  s.metadata = {
    "homepage_uri" => "https://terret.org",
    "source_code_uri" => "https://github.com/terret-org/terret",
    "bug_tracker_uri" => "https://github.com/terret-org/terret/issues",
    "rubygems_mfa_required" => "true"
  }
end
