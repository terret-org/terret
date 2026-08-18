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
