# Turbo Web Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A one-file browser chat against a Terret agent — Turbo Streams over SSE, transcript rendered entirely from `session/event` replay-then-tail.

**Architecture:** `examples/web_chat.rb` boots the same plugin stack as `openrouter_demo.rb`, then serves four routes from `Async::HTTP::Server` on one reactor. A `Renderer` maps durable session events to `<turbo-stream>` fragments; a `Hub` fans rendered HTML out to per-connection `Async::Queue`s; an `AgentHost` serializes turns and owns session reset. Spec: `docs/superpowers/specs/2026-08-17-turbo-web-chat-design.md`.

**Tech Stack:** Ruby 4.0.6, terret-core + terret-openrouter (path gems), async-http (already installed; verified locally: `Writable#write/#close`, `Async::Queue#enqueue/#dequeue`, `Server.for`, `Protocol::HTTP::Response[status, headers, body]`, request responds to `method/path/read`), turbo.js 8 from CDN. **No test suite** — the approved spec sets examples convention: syntax checks per task, live browser verification at the end.

---

### Task 1: Helpers and the Renderer

**Files:**
- Create: `examples/web_chat.rb`

- [ ] **Step 1: Write the file skeleton — env guard, requires, stream helpers, composer, Renderer**

```ruby
# frozen_string_literal: true
# Interactive browser chat against a real model over OpenRouter. Turbo Streams
# over SSE, one reactor, no framework, no build step. The transcript is
# rendered entirely from session/event replay-then-tail (plan §9.3 in
# miniature): a page refresh reconstructs everything from the session log.
#
#   OPENROUTER_API_KEY=sk-or-... ruby examples/web_chat.rb
#   open http://localhost:9292

abort "set OPENROUTER_API_KEY to run this demo" unless ENV["OPENROUTER_API_KEY"]

Warning[:experimental] = false # async's resolv use of IO::Buffer warns on Ruby 4.0

require_relative "../gems/terret-core/lib/terret"
require_relative "../gems/terret-openrouter/lib/terret/openrouter"
require "async"
require "async/http/server"
require "async/http/endpoint"
require "protocol/http/body/writable"
require "cgi"
require "uri"

def h(text) = CGI.escapeHTML(text.to_s)

def turbo_tag(action, target, html)
  %(<turbo-stream action="#{action}" target="#{target}"><template>#{html}</template></turbo-stream>)
end

# SSE data is line-framed: every line of a multi-line payload needs its own
# "data:" prefix, and the browser rejoins them with newlines.
def sse_frame(html)
  html.each_line.map { |line| "data: #{line.chomp}" }.join("\n") + "\n\n"
end

# The composer is swapped wholesale by turn/start (disable) and turn/end
# (re-enable), so it must render identically here and in the Renderer.
# data-turbo="false" keeps Turbo Drive away from these forms — the page's own
# fetch handler submits them (Turbo would otherwise intercept first and choke
# on the 204 responses).
def composer_html(disabled: false)
  attrs = disabled ? " disabled" : ""
  placeholder = disabled ? "agent is working…" : "Say something…"
  <<~HTML
    <form id="composer" action="/messages" method="post" data-turbo="false" autocomplete="off">
      <input type="text" name="text" placeholder="#{placeholder}"#{attrs} autofocus>
      <button type="submit"#{attrs}>Send</button>
    </form>
  HTML
end

# Durable session event -> <turbo-stream> fragment (or nil for events with no
# visual). One piece of state: the current step's DOM id, derived from the
# step/start seq, so replaying the log through a fresh Renderer reproduces the
# transcript exactly.
class Renderer
  def render(ev)
    case ev.type
    when "session/created"
      turbo_tag("update", "transcript", "")
    when "user/message"
      turbo_tag("append", "transcript", %(<div class="msg user">#{h(ev.payload[:text])}</div>))
    when "step/start"
      @step_id = "step-#{ev.seq}"
      turbo_tag("append", "transcript", %(<div class="msg assistant" id="#{@step_id}"></div>))
    when "assistant/chunk"
      turbo_tag("append", @step_id, h(ev.payload[:text]))
    when "tool/call"
      turbo_tag("append", "transcript",
                %(<div class="tool">#{h(ev.payload[:name])} #{h(ev.payload[:args].inspect)}</div>))
    when "tool/result"
      error = ev.payload[:error]
      turbo_tag("append", "transcript",
                %(<div class="tool#{' error' if error}">→ #{h(error || ev.payload[:content])}</div>))
    when "step/end"
      usage = ev.payload[:usage]
      usage && turbo_tag("append", "transcript",
                         %(<div class="meta">#{usage[:prompt_tokens]}+#{usage[:completion_tokens]} tokens · $#{usage[:cost]}</div>))
    when "turn/start"
      turbo_tag("replace", "composer", composer_html(disabled: true))
    when "turn/end"
      turbo_tag("replace", "composer", composer_html) +
        turbo_tag("append", "transcript", %(<div class="meta">turn #{h(ev.payload[:status])}</div>))
    end
  end
end
```

- [ ] **Step 2: Syntax check**

Run: `mise exec -- ruby -c examples/web_chat.rb`
Expected: `Syntax OK`

- [ ] **Step 3: Commit**

```bash
git add examples/web_chat.rb
git commit -m "Start the web chat example with its event renderer

Maps durable session events to turbo-stream fragments; a fresh
Renderer replaying the log reproduces the transcript exactly, which
is what makes refresh-as-replay work."
```

### Task 2: Hub, AgentHost, and the page

**Files:**
- Modify: `examples/web_chat.rb` (append after the `Renderer` class)

- [ ] **Step 1: Append Hub, AgentHost, and page_html**

```ruby
# Fan-out of rendered HTML to per-connection SSE queues.
class Hub
  def initialize
    @queues = []
  end

  def subscribe
    queue = Async::Queue.new
    @queues << queue
    queue
  end

  def unsubscribe(queue) = @queues.delete(queue)

  def broadcast(html)
    @queues.each { |q| q.enqueue(html) }
  end
end

# Owns the current session and agent; serializes turns with a plain flag —
# safe on one reactor because there is no await between check and set.
class AgentHost
  attr_reader :session, :agent

  def initialize(ctx, hub)
    @ctx = ctx
    @hub = hub
    @busy = false
    reset!
  end

  def busy? = @busy

  def reset!
    @session = @ctx[:sessions].create
    @agent = @ctx[:loop].spawn_agent(session_id: @session.id)
  end

  # Runs one turn in its own task on the shared reactor. Returns false when a
  # turn is already running (the composer is disabled; this is belt and braces).
  def run(text)
    return false if @busy

    @busy = true
    Async do
      @ctx[:loop].run_turn(@agent, text)
    rescue => e
      # ephemeral by design: a failed turn is not model-visible truth, so it
      # stays out of the session log — and the loop never appended turn/end,
      # so the composer must be re-enabled from here
      @hub.broadcast(
        turbo_tag("append", "transcript",
                  %(<div class="tool error">turn failed: #{h(e.message)}</div>)) +
        turbo_tag("replace", "composer", composer_html)
      )
    ensure
      @busy = false
    end
    true
  end
end

def page_html(model)
  <<~HTML
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Terret</title>
      <style>
        body { font: 15px/1.5 system-ui, sans-serif; max-width: 640px; margin: 2rem auto; padding: 0 1rem; }
        header { display: flex; justify-content: space-between; align-items: baseline; color: #666; }
        .msg { padding: .5rem .75rem; border-radius: .5rem; margin: .5rem 0; white-space: pre-wrap; }
        .user { background: #e8f0fe; margin-left: 20%; }
        .assistant { background: #f5f5f5; margin-right: 20%; }
        .tool { color: #666; font-family: ui-monospace, monospace; font-size: .85em; margin: .25rem 0; }
        .tool.error { color: #c00; }
        .meta { color: #999; font-size: .8em; margin: .25rem 0; }
        #composer { display: flex; gap: .5rem; margin-top: 1rem; }
        #composer input { flex: 1; padding: .5rem; }
      </style>
    </head>
    <body>
      <header>
        <span>terret · #{h(model)}</span>
        <form action="/session" method="post" data-turbo="false"><button>new session</button></form>
      </header>
      <div id="transcript"></div>
      #{composer_html}
      <script type="module">
        import { connectStreamSource } from "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8/+esm";
        connectStreamSource(new EventSource("/events"));
        // Delegated so the handler survives composer replacement by turbo-streams.
        document.addEventListener("submit", async (event) => {
          const form = event.target;
          event.preventDefault();
          const response = await fetch(form.action, { method: "POST", body: new URLSearchParams(new FormData(form)) });
          const input = form.querySelector("input[name=text]");
          if (input && response.ok) input.value = "";
        });
      </script>
    </body>
    </html>
  HTML
end
```

- [ ] **Step 2: Syntax check**

Run: `mise exec -- ruby -c examples/web_chat.rb`
Expected: `Syntax OK`

- [ ] **Step 3: Commit**

```bash
git add examples/web_chat.rb
git commit -m "Give the web chat its hub, agent host, and page shell

Per-connection queues for SSE fan-out, a busy flag serializing turns
on the single reactor, and the static page with delegated form
submission so the composer survives turbo-stream replacement."
```

### Task 3: Boot, routes, and the SSE stream

**Files:**
- Modify: `examples/web_chat.rb` (append after `page_html`)

- [ ] **Step 1: Append the SSE handler, boot wiring, and server**

```ruby
# Snapshot the log and subscribe with no await in between, so the stream has
# no gap and no duplicate; then replay through a fresh Renderer and tail.
def sse_response(hub, host)
  body = Protocol::HTTP::Body::Writable.new
  Async do
    queue = nil
    replay = Renderer.new
    events = host.session.events.dup
    queue = hub.subscribe
    events.each do |ev|
      html = replay.render(ev)
      body.write(sse_frame(html)) if html
    end
    loop { body.write(sse_frame(queue.dequeue)) }
  rescue StandardError
    # any write failure means the browser went away; drop the connection
  ensure
    hub.unsubscribe(queue) if queue
    body.close
  end
  Protocol::HTTP::Response[200, { "content-type" => "text/event-stream",
                                  "cache-control" => "no-cache" }, body]
end

model = ENV.fetch("TERRET_MODEL", "openai/gpt-5-mini")

loader = Hames::Loader.new
loader.layer([
  { id: "sessions",   plugin: Terret::Sessions },
  { id: "prompt",     plugin: Terret::Prompt },
  { id: "tools",      plugin: Terret::Tools::Registry },
  { id: "llm",        plugin: Terret::LLM::Service, config: { roles: { main: "openrouter/#{model}" } } },
  { id: "loop",       plugin: Terret::Loop },
  { id: "openrouter", plugin: Terret::OpenRouter::Plugin,
    config: { title: "Terret web chat", referer: "https://terret.org" } }
])
ctx = loader.boot!

ctx.with_owner("web-chat-tools") do
  ctx[:tools].register(
    name: "weather", description: "Current weather for a city",
    params: { type: "object", properties: { city: { type: "string" } },
              required: ["city"] }
  ) { |city:| "22C, clear skies in #{city}" }
  ctx[:prompt].register_section("identity", priority: 1) do
    "You are a terse assistant. Use the weather tool when asked about weather."
  end
end

hub = Hub.new
host = AgentHost.new(ctx, hub)
live = Renderer.new

ctx.with_owner("web-chat") do
  # No session filter here: Sessions#create appends session/created before
  # AgentHost's @session assignment lands, and abandoned sessions never emit
  # again anyway (reset is refused while a turn runs).
  ctx.on("session/event") do |ev|
    html = live.render(ev)
    hub.broadcast(html) if html
  end
end

port = ENV.fetch("PORT", "9292").to_i
endpoint = Async::HTTP::Endpoint.parse("http://localhost:#{port}")

Sync do
  server = Async::HTTP::Server.for(endpoint) do |request|
    case [request.method, request.path]
    when ["GET", "/"]
      Protocol::HTTP::Response[200, { "content-type" => "text/html; charset=utf-8" },
                               [page_html(model)]]
    when ["GET", "/events"]
      sse_response(hub, host)
    when ["POST", "/messages"]
      text = URI.decode_www_form(request.read.to_s).to_h["text"].to_s.strip
      if text.empty?
        Protocol::HTTP::Response[422, {}, ["missing text"]]
      elsif host.run(text)
        Protocol::HTTP::Response[204, {}, []]
      else
        Protocol::HTTP::Response[409, {}, ["a turn is already running"]]
      end
    when ["POST", "/session"]
      if host.busy?
        Protocol::HTTP::Response[409, {}, ["a turn is already running"]]
      else
        host.reset!
        Protocol::HTTP::Response[204, {}, []]
      end
    else
      Protocol::HTTP::Response[404, {}, ["not found"]]
    end
  end
  puts "terret web chat on http://localhost:#{port} (model: #{model})"
  server.run
end
```

- [ ] **Step 2: Syntax check**

Run: `mise exec -- ruby -c examples/web_chat.rb`
Expected: `Syntax OK`

- [ ] **Step 3: Boot check — server starts and serves the page**

Run (background): `OPENROUTER_API_KEY=... mise exec -- ruby examples/web_chat.rb`
Expected: `terret web chat on http://localhost:9292 (model: openai/gpt-5-mini)`

Run: `curl -s -o /dev/null -w "%{http_code}" http://localhost:9292/`
Expected: `200`

- [ ] **Step 4: Commit**

```bash
git add examples/web_chat.rb
git commit -m "Serve the web chat over async-http with SSE replay-then-tail

Four routes on the adapter's own reactor. The /events handler
snapshots the log and subscribes atomically, replays through a fresh
renderer, then tails the hub — so a refresh is a full replay and two
tabs see the same stream."
```

### Task 4: Live browser verification

**Files:** none (verification only; fix-up commits if issues surface)

- [ ] **Step 1: Run the server with a real key**

Run: `OPENROUTER_API_KEY=... mise exec -- ruby examples/web_chat.rb`

- [ ] **Step 2: Verify the spec's checklist in a browser at http://localhost:9292**

1. Send "What's the weather in Mexico City right now?" — text streams in incrementally; a tool line and result line appear; a usage badge with tokens and `$` cost follows; the input disables during the turn and re-enables after.
2. Refresh mid-conversation — the full transcript reproduces from replay.
3. Open a second tab — both tabs receive the same live stream.
4. Click **new session** — both tabs clear.
5. `curl -s -X POST http://localhost:9292/messages -d "text=hi" & curl -s -X POST http://localhost:9292/messages -d "text=again"` — the second returns `a turn is already running` (409).

- [ ] **Step 3: Fix anything found and commit fixes**

```bash
git add examples/web_chat.rb
git commit -m "Fix web chat issues found in live verification"
```

(Skip if nothing surfaced.)
