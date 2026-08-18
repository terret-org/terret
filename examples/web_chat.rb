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
require_relative "../gems/terret-store-sqlite/lib/terret/store/sqlite"
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

# The sidebar is cross-session state derived from store queries, deliberately
# separate from the per-session Renderer, which stays replay-pure.
def session_label(events)
  first = events.find { |ev| ev.type == "user/message" }
  first ? first.payload[:text][0, 40] : "untitled"
end

def sidebar_html(sessions, active_id)
  entries = sessions.session_ids
                    .map { |id| [id, sessions.read(id)] }
                    .sort_by { |(_id, events)| events.last&.at || Time.at(0) }
                    .reverse
  items = entries.map do |(id, events)|
    active = id == active_id ? " active" : ""
    <<~HTML
      <form action="/session/select" method="post" data-turbo="false">
        <input type="hidden" name="id" value="#{h(id)}">
        <button class="session#{active}" type="submit">#{h(session_label(events))}</button>
      </form>
    HTML
  end
  <<~HTML
    <form action="/session" method="post" data-turbo="false"><button class="new">+ new session</button></form>
    #{items.join}
  HTML
end

def sidebar_frame(sessions, active_id)
  turbo_tag("update", "sessions", sidebar_html(sessions, active_id))
end

# Rebuild every connected tab after a session switch: clear, replay the
# active session through a fresh Renderer, refresh the sidebar, then send
# the authoritative composer state (covers logs that end mid-turn).
def broadcast_session(hub, sessions, host)
  hub.broadcast(turbo_tag("update", "transcript", ""))
  replay = Renderer.new
  host.session.events.each do |ev|
    html = replay.render(ev)
    hub.broadcast(html) if html
  end
  hub.broadcast(sidebar_frame(sessions, host.session.id))
  hub.broadcast(turbo_tag("replace", "composer", composer_html(disabled: host.busy?)))
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
                         %(<div class="meta">#{h(usage[:prompt_tokens])}+#{h(usage[:completion_tokens])} tokens · $#{h(usage[:cost])}</div>))
    when "turn/start"
      turbo_tag("replace", "composer", composer_html(disabled: true))
    when "turn/end"
      turbo_tag("replace", "composer", composer_html) +
        turbo_tag("append", "transcript", %(<div class="meta">turn #{h(ev.payload[:status])}</div>))
    end
  end
end

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
    latest = most_recent_session_id
    latest ? select!(latest) : reset!
  end

  def busy? = @busy

  def reset!
    @session = @ctx[:sessions].create
    @agent = @ctx[:loop].spawn_agent(session_id: @session.id)
    @session
  end

  # Switch the globally active session (every tab follows, same as the
  # new-session button). Refused while a turn runs.
  def select!(session_id)
    return false if @busy

    @session = @ctx[:sessions].resume(session_id)
    @agent = @ctx[:loop].spawn_agent(session_id: @session.id)
    @session
  end

  # Runs one turn in its own task on the shared reactor. Returns false when a
  # turn is already running (the composer is disabled; this is belt and braces).
  def run(text)
    return false if @busy

    @busy = true
    Async do
      @ctx[:loop].run_turn(@agent, text)
    rescue => e
      # the durable turn/end (status :failed) already re-enabled the composer
      # through the normal render path; only the exception detail is ephemeral —
      # it is not model-visible truth, so it stays out of the session log
      @hub.broadcast(
        turbo_tag("append", "transcript",
                  %(<div class="tool error">turn failed: #{h(e.message)}</div>))
      )
    ensure
      @busy = false
    end
    true
  end

  private

  def most_recent_session_id
    @ctx[:sessions].session_ids
        .max_by { |id| @ctx[:sessions].read(id).last&.at || Time.at(0) }
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
        body { font: 15px/1.5 system-ui, sans-serif; margin: 0; display: flex; min-height: 100vh; }
        nav#sessions { width: 240px; flex-shrink: 0; background: #f7f7f8; padding: 1rem .75rem; box-sizing: border-box; overflow-y: auto; }
        nav#sessions form { margin: 0 0 .25rem; }
        nav#sessions button { width: 100%; text-align: left; border: 0; background: transparent; padding: .5rem; border-radius: .375rem; cursor: pointer; font: inherit; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        nav#sessions button:hover { background: #ececf1; }
        nav#sessions button.active { background: #e3e3ea; font-weight: 600; }
        nav#sessions button.new { border: 1px solid #ccc; text-align: center; margin-bottom: 1rem; }
        main { flex: 1; max-width: 640px; margin: 2rem auto; padding: 0 1rem; }
        header { display: flex; justify-content: space-between; align-items: baseline; color: #666; }
        .msg { padding: .5rem .75rem; border-radius: .5rem; margin: .5rem 0; white-space: pre-wrap; }
        .msg:empty { display: none; } /* a tool-only step never fills its bubble */
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
      <nav id="sessions"></nav>
      <main>
        <header><span>terret · #{h(model)}</span></header>
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
      </main>
    </body>
    </html>
  HTML
end

# Snapshot the log and subscribe with no await in between, so the stream has
# no gap and no duplicate; then replay through a fresh Renderer and tail.
def sse_response(hub, host, sessions)
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
    body.write(sse_frame(sidebar_frame(sessions, host.session.id)))
    body.write(sse_frame(turbo_tag("replace", "composer", composer_html(disabled: host.busy?))))
    loop { body.write(sse_frame(queue.dequeue)) }
  rescue StandardError
    # any write failure means the browser went away; drop the connection
  ensure
    hub.unsubscribe(queue) if queue
    body.close_write
  end
  Protocol::HTTP::Response[200, { "content-type" => "text/event-stream",
                                  "cache-control" => "no-cache" }, body]
end

model = ENV.fetch("TERRET_MODEL", "openai/gpt-5-mini")

loader = Hames::Loader.new
loader.layer([
  { id: "session_store", plugin: Terret::Store::SQLite,
    config: { path: File.expand_path("../tmp/web_chat.sqlite3", __dir__) } },
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
      sse_response(hub, host, ctx[:sessions])
    when ["POST", "/messages"]
      text = begin
        URI.decode_www_form(request.read.to_s).to_h["text"].to_s.strip
      rescue ArgumentError
        nil
      end
      if text.nil?
        Protocol::HTTP::Response[400, {}, ["malformed form body"]]
      elsif text.empty?
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
        broadcast_session(hub, ctx[:sessions], host)
        Protocol::HTTP::Response[204, {}, []]
      end
    when ["POST", "/session/select"]
      id = begin
        URI.decode_www_form(request.read.to_s).to_h["id"].to_s
      rescue ArgumentError
        ""
      end
      if host.busy?
        Protocol::HTTP::Response[409, {}, ["a turn is already running"]]
      elsif id.empty? || !ctx[:sessions].session_ids.include?(id)
        Protocol::HTTP::Response[404, {}, ["unknown session"]]
      else
        host.select!(id)
        broadcast_session(hub, ctx[:sessions], host)
        Protocol::HTTP::Response[204, {}, []]
      end
    else
      Protocol::HTTP::Response[404, {}, ["not found"]]
    end
  end
  puts "terret web chat on http://localhost:#{port} (model: #{model})"
  server.run
end
