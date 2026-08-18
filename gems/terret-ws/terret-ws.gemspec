Gem::Specification.new do |s|
  s.name = "terret-ws"
  s.version = "0.1.0"
  s.summary = "WebSocket interface for the Terret agent harness"
  s.description = "The v1 interface: one connection per agent, durable session " \
                  "events out, five client frames in, exact replay-then-tail " \
                  "reconnect on the append-only log, bounded-queue backpressure, " \
                  "heartbeat, and bearer auth. Ships as a plugin because the " \
                  "primary interface being a plugin is the architecture's point."
  s.authors = ["Obie Fernandez"]
  s.email = ["obiefernandez@gmail.com"]
  s.homepage = "https://terret.org"
  s.license = "MIT"
  s.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb"] }
  s.required_ruby_version = ">= 4.0"
  s.add_dependency "terret-core", "~> 0.1"
  s.add_dependency "async-websocket", ">= 0.30"
  s.metadata = {
    "homepage_uri" => "https://terret.org",
    "source_code_uri" => "https://github.com/terret-org/terret",
    "bug_tracker_uri" => "https://github.com/terret-org/terret/issues",
    "rubygems_mfa_required" => "true"
  }
end
