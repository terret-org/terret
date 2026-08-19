# frozen_string_literal: true
# The manual-testing console: a browser chat against a real model over
# OpenRouter with the WHOLE execution world mounted underneath it — the std
# tool roster on ctx[:fs]/ctx[:shell]/ctx[:terminals], the Task tool over
# ctx[:subagents], background jobs and TodoWrite where the gems carry them,
# optional human-in-the-loop approvals, and cancel. Turbo Streams over SSE,
# one reactor, no framework, no build step.
#
# The transcript is rendered entirely from session/event replay-then-tail
# (plan §9.3 in miniature): a page refresh reconstructs everything from the
# session log, including which approval cards have already been settled.
#
#   OPENROUTER_API_KEY=sk-or-... ruby examples/web_chat.rb
#   open http://localhost:9292
#
# Env toggles, all optional:
#   TERRET_MODEL=openai/gpt-5-mini   which model answers
#   TERRET_APPROVALS=1               mount ctx[:approvals]; mutating tools park
#                                    on a human verdict (opt-in, the M6 posture)
#   TERRET_SANDBOX=docker            move execution into a container
#   TERRET_REDACT=0                  drop the redactor row (it holds streamed
#                                    text until each run ends, so turning it
#                                    off is how you watch tokens arrive live)
#   TERRET_WEBFETCH_ALLOW=a.com,*.b  the WebFetch domain allow list
#   PORT=9292                        where to listen

abort "set OPENROUTER_API_KEY to run this demo" unless ENV["OPENROUTER_API_KEY"]

Warning[:experimental] = false # async's resolv use of IO::Buffer warns on Ruby 4.0

require_relative "../gems/terret-core/lib/terret"
require_relative "../gems/terret-exec/lib/terret/exec"           # fs, sandbox-none, subprocess, shell, terminals (+ jobs, once M8 lands)
require_relative "../gems/terret-tools-std/lib/terret/tools_std" # Read/Write/Edit/Glob/Grep, Bash, terminal_*, WebFetch, Task
require_relative "../gems/terret-openrouter/lib/terret/openrouter"
require_relative "../gems/terret-store-sqlite/lib/terret/store/sqlite"
require "async"
require "async/http/server"
require "async/http/endpoint"
require "protocol/http/body/writable"
require "fileutils"
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

def trim(text, limit)
  s = text.to_s
  s.length > limit ? "#{s[0, limit]}… (+#{s.length - limit} more)" : s
end

# Tool arguments, one line, each value capped on its own so a Write's whole
# file body cannot push the file_path off the end.
def compact_args(args)
  return trim(args, 200) unless args.is_a?(Hash)

  args.map { |k, v| "#{k}: #{trim(v.inspect, 80)}" }.join(", ")
end

RESULT_LIMIT = 1_500 # a tool result's display cap; the log keeps the whole thing

# The composer is swapped wholesale by turn/start (busy) and turn/end (ready),
# so it must render identically here and in the Renderer. It is a DIV wrapping
# the form rather than the form itself, because the busy state carries a
# second form — Cancel — and a turbo replace targeting #composer has to take
# both away again.
#
# data-turbo="false" keeps Turbo Drive away from these forms — the page's own
# fetch handler submits them (Turbo would otherwise intercept first and choke
# on the 204 responses).
def composer_html(state = :ready)
  case state
  when :readonly
    <<~HTML
      <div id="composer" class="readonly">
        read-only — this is a subagent's session. Pick a root session, or start a new one, to type.
      </div>
    HTML
  when :busy
    <<~HTML
      <div id="composer">
        <form action="/messages" method="post" data-turbo="false" autocomplete="off">
          <input type="text" name="text" placeholder="agent is working…" disabled>
          <button type="submit" disabled>Send</button>
        </form>
        <form action="/cancel" method="post" data-turbo="false"><button class="cancel" type="submit">Cancel</button></form>
      </div>
    HTML
  else
    <<~HTML
      <div id="composer">
        <form action="/messages" method="post" data-turbo="false" autocomplete="off">
          <input type="text" name="text" placeholder="Say something…" autofocus>
          <button type="submit">Send</button>
        </form>
      </div>
    HTML
  end
end

# Which composer this host's current session deserves. An agentless session is
# one the console is only reading (a Task run); busy is a turn in flight.
def composer_state(host)
  return :readonly unless host.agent

  host.busy? ? :busy : :ready
end

def composer_frame(state) = turbo_tag("replace", "composer", composer_html(state))

# -- the sidebar --------------------------------------------------------------
#
# Cross-session state derived from store queries, deliberately separate from
# the per-session Renderer, which stays replay-pure.

def session_entries(sessions)
  sessions.session_ids
          .map { |id| [id, sessions.read(id)] }
          .sort_by { |(_id, events)| events.last&.at || Time.at(0) }
          .reverse
end

# The only link from a parent's log to a subagent's session is the Task
# result's ledger line (Terret::ToolsStd::Task::LEDGER), so that line is where
# the console learns the lineage. Derived from the log like everything else
# here, which is what makes it survive a restart: a child session listed after
# a redeploy is still recognised as a Task run.
CHILD_LINE = /^child session (\S+)$/

def child_session_ids(entries)
  entries.flat_map do |(_id, events)|
    events.filter_map do |ev|
      ev.payload[:content].to_s[CHILD_LINE, 1] if ev.type == "tool/result"
    end
  end
end

# Prefers Sessions#title (the durable, once-per-session title); falls back to
# the first-user-message truncation for a session with no title yet. #title
# reads the in-memory cache (fetch), which only holds sessions this process
# has created or resumed — a session listed here from a prior run that was
# never selected raises KeyError, so that's the fallback's other job.
def session_label(sessions, id, events)
  title = begin
    sessions.title(id)
  rescue KeyError
    nil
  end
  title || events.find { |ev| ev.type == "user/message" }&.payload&.[](:text)&.[](0, 40) || "untitled"
end

def sidebar_html(sessions, active_id)
  entries = session_entries(sessions)
  children = child_session_ids(entries)
  items = entries.map do |(id, events)|
    classes = ["session"]
    classes << "active" if id == active_id
    classes << "child"  if children.include?(id)
    label = session_label(sessions, id, events)
    label = "↳ #{label}" if children.include?(id)
    <<~HTML
      <form action="/session/select" method="post" data-turbo="false">
        <input type="hidden" name="id" value="#{h(id)}">
        <button class="#{classes.join(' ')}" type="submit"
                title="#{children.include?(id) ? 'Task run' : 'session'} #{h(id)}">#{h(label)}</button>
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

# The session's lifetime spend (Sessions#usage's rollup), rendered as the
# header badge.
def usage_html(usage)
  "$#{format('%.4f', usage[:cost])} · #{usage[:prompt_tokens] + usage[:completion_tokens]} tokens"
end

def usage_frame(sessions, session_id)
  turbo_tag("update", "usage", usage_html(sessions.usage(session_id)))
end

# Rebuild every connected tab after a session switch: clear, replay the
# active session through a fresh Renderer, refresh the sidebar, then send
# the authoritative composer state (covers logs that end mid-turn, and
# read-only Task sessions, whose replayed turn/starts say nothing about
# whether a human may type here now).
def broadcast_session(hub, sessions, host)
  hub.broadcast(turbo_tag("update", "transcript", ""))
  replay = Renderer.new(composer: false)
  host.session.events.each do |ev|
    html = replay.render(ev)
    hub.broadcast(html) if html
  end
  hub.broadcast(sidebar_frame(sessions, host.session.id))
  hub.broadcast(usage_frame(sessions, host.session.id))
  hub.broadcast(composer_frame(composer_state(host)))
end

# Durable session event -> <turbo-stream> fragment (or nil for events with no
# visual). Every DOM id it mints is derived from an event seq, so the live
# renderer and each connection's replay renderer agree on them by construction
# — that is what lets a refresh land on the same transcript the tail built.
#
# `composer:` is off for replay: the caller sends one authoritative composer
# frame after the replay finishes, and a replayed turn/start fighting it would
# only flicker.
class Renderer
  TODO_LINE = /\A- \[([ ~x])\] (.*)\z/
  TODO_STATES = { " " => %w[pending ☐], "~" => %w[active ◐], "x" => %w[done ☑] }.freeze
  LEDGER = "--- terret ---" # Terret::ToolsStd::Task::LEDGER, kept as a literal so the console renders logs written by any version

  def initialize(composer: true)
    @composer = composer
    @step_id = nil
    @names = {} # tool call id -> tool name; tool/result carries neither
    @cards = {} # approval call id -> the card's DOM id, so a verdict finds it
  end

  def render(ev)
    case ev.type
    when "session/created"
      turbo_tag("update", "transcript", "")
    when "user/message"
      turbo_tag("append", "transcript", %(<div class="msg user">#{h(ev.payload[:text])}</div>))
    when "context/injected"
      turbo_tag("append", "transcript", %(<div class="msg user">(injected) #{h(ev.payload[:text])}</div>))
    when "step/start"
      @step_id = "step-#{ev.seq}"
      turbo_tag("append", "transcript", %(<div class="msg assistant" id="#{@step_id}"></div>))
    when "assistant/chunk"
      turbo_tag("append", @step_id, h(ev.payload[:text]))
    when "tool/call"
      @names[ev.payload[:id]] = ev.payload[:name]
      turbo_tag("append", "transcript",
                %(<div class="tool call"><b>#{h(ev.payload[:name])}</b> #{h(compact_args(ev.payload[:args]))}</div>))
    when "tool/result"
      turbo_tag("append", "transcript", result_html(ev.payload))
    when "approval/requested"
      dom = "approval-#{ev.seq}"
      @cards[ev.payload[:call_id]] = dom
      turbo_tag("append", "transcript", approval_card(dom, ev.payload))
    when "approval/resolved"
      dom = @cards[ev.payload[:call_id]]
      dom && turbo_tag("replace", dom, settled_card(dom, ev.payload))
    when "session/compacted"
      turbo_tag("append", "transcript",
                %(<div class="meta">history compacted up to seq #{h(ev.payload[:upto_seq])}</div>))
    when "step/end"
      usage = ev.payload[:usage]
      usage && turbo_tag("append", "transcript",
                         %(<div class="meta">#{h(usage[:prompt_tokens])}+#{h(usage[:completion_tokens])} tokens · $#{h(usage[:cost])}</div>))
    when "turn/start"
      @composer ? composer_frame(:busy) : nil
    when "turn/end"
      turn_end(ev)
    end
  end

  private

  def turn_end(ev)
    status = ev.payload[:status].to_s
    reason = ev.payload[:reason]
    line = %(<div class="meta #{h(status)}">turn #{h(status)}#{reason ? " · #{h(reason)}" : ''}</div>)
    (@composer ? composer_frame(:ready) : "") + turbo_tag("append", "transcript", line)
  end

  # A tool result renders three ways: an error, a TodoWrite checklist, or the
  # content trimmed for display. The tool's NAME is not on the tool/result
  # event — the loop appends {id, content, error} — so it comes from the
  # tool/call this renderer already walked past, which is exactly why the map
  # above is renderer state rather than a lookup against a live registry.
  def result_html(payload)
    name = @names[payload[:id]]
    return %(<div class="tool error">→ #{h(trim(payload[:error], RESULT_LIMIT))}</div>) if payload[:error]

    todos = (todo_html(payload[:content]) if name == "TodoWrite")
    return todos if todos
    return task_html(payload[:content]) if name == "Task"

    %(<div class="tool">→ #{h(trim(payload[:content], RESULT_LIMIT))}</div>)
  end

  # TodoWrite keeps the list nowhere but in its own result (the M8 tool holds
  # no state), so the checklist a human reads is parsed back out of exactly
  # the text the model will read. A result that does not match the shape falls
  # through to the plain rendering rather than being half-parsed.
  def todo_html(content)
    items = content.to_s.lines.filter_map do |line|
      match = TODO_LINE.match(line.chomp) or next
      state, glyph = TODO_STATES.fetch(match[1])
      %(<li class="todo #{state}"><span class="box">#{glyph}</span>#{h(match[2])}</li>)
    end
    items.empty? ? nil : %(<ul class="todos">#{items.join}</ul>)
  end

  # The Task result's ledger line is the only thing in a parent's log that
  # names the child's session, so it is rendered as the one control that goes
  # there: a form-button posting the child id to /session/select.
  def task_html(content)
    body, _, ledger = content.to_s.partition(LEDGER)
    child = ledger[CHILD_LINE, 1]
    remarks = ledger.to_s.lines.map(&:chomp).reject { |l| l.empty? || l.start_with?("child session ") }
    html = +%(<div class="tool">→ #{h(trim(body.strip, RESULT_LIMIT))}</div>)
    html << %(<div class="ledger">#{child_link(child)}#{remarks.map { |r| %( · #{h(r)}) }.join}</div>) if child || remarks.any?
    html
  end

  def child_link(child)
    return "" unless child

    <<~HTML.chomp
      <form action="/session/select" method="post" data-turbo="false">
        <input type="hidden" name="id" value="#{h(child)}">
        <button class="link" type="submit">child session #{h(child)} →</button>
      </form>
    HTML
  end

  def approval_card(dom, payload)
    <<~HTML
      <div class="approval" id="#{dom}">
        <div class="approval-head">approval needed · <b>#{h(payload[:name])}</b></div>
        <div class="approval-args">#{h(trim(compact_args(payload[:args]), 600))}</div>
        <div class="approval-actions">
          #{verdict_form(payload[:call_id], 'approved', 'Approve')}
          #{verdict_form(payload[:call_id], 'denied', 'Deny')}
        </div>
      </div>
    HTML
  end

  def verdict_form(call_id, verdict, label)
    <<~HTML.chomp
      <form action="/approvals" method="post" data-turbo="false">
        <input type="hidden" name="call_id" value="#{h(call_id)}">
        <input type="hidden" name="verdict" value="#{h(verdict)}">
        <button class="#{verdict}" type="submit">#{label}</button>
      </form>
    HTML
  end

  # Replace rather than update, so the settled card carries its verdict in its
  # own class. The buttons go with it: a decision already in the log is not one
  # a second click may revisit.
  def settled_card(dom, payload)
    verdict = payload[:verdict].to_s
    reason = payload[:reason]
    <<~HTML
      <div class="approval settled #{h(verdict)}" id="#{dom}">
        <div class="approval-head">#{h(verdict)}#{reason ? " · #{h(reason)}" : ''}</div>
      </div>
    HTML
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
#
# A session the console is only READING (a subagent's, reached through a Task
# ledger link) has no agent at all: nothing is spawned for it, so there is
# nothing to type into and nothing to cancel. That is what @agent being nil
# means everywhere below.
class AgentHost
  attr_reader :session, :agent

  def initialize(ctx, hub)
    @ctx = ctx
    @hub = hub
    @busy = false
    latest = most_recent_root_session_id
    latest ? select!(latest) : reset!
  end

  def busy? = @busy

  def read_only? = @agent.nil?

  def reset!
    drop_stale_agent!
    @session = @ctx[:sessions].create
    @agent = @ctx[:loop].spawn_agent(session_id: @session.id)
    @session
  end

  # Switch the globally active session (every tab follows, same as the
  # new-session button). Refused while a turn runs.
  def select!(session_id)
    return false if @busy

    read_only = child_sessions.include?(session_id)
    drop_stale_agent!(read_only ? nil : session_id)
    @session = @ctx[:sessions].resume(session_id)
    @agent = read_only ? nil : @ctx[:loop].spawn_agent(session_id: @session.id)
    @session
  end

  # Runs one turn in its own task on the shared reactor. Returns false when a
  # turn is already running (the composer is disabled; this is belt and braces)
  # or when this session is one the console is only reading.
  def run(text)
    return false if @busy || @agent.nil?

    drive do
      # a session picked back up after a crash may still have a turn open in
      # the log; the text rides its next step instead of starting a second one
      if @ctx[:loop].resumable?(@session.id)
        @agent.inject(text)
        @ctx[:loop].resume_turn(@agent)
      else
        @ctx[:loop].run_turn(@agent, text)
      end
    end
  end

  # A human verdict on a parked call. The append IS the resolution — the
  # approvals gate listens for approval/resolved on the session stream and
  # unparks the fiber holding the turn (Terret::Tools::Approvals#park), so
  # nothing here has to know a waiter exists.
  def resolve(call_id, verdict, reason = nil)
    payload = { call_id: call_id, verdict: verdict }
    payload[:reason] = reason if reason
    @ctx[:sessions].append(@session.id, "approval/resolved", payload)
    # A verdict for an IDLE agent means no fiber was parked when it landed —
    # the process restarted since the call parked — so the open turn has to be
    # picked back up by hand. The socket does exactly this (WS::Connection).
    return true unless @agent && @agent.status == :idle && @ctx[:loop].resumable?(@session.id)

    drive { @ctx[:loop].resume_turn(@agent) }
    true
  end

  # Cooperative stop, honored by the loop at a step boundary. Answers :ok when
  # there was something to stop and :idle when there was not.
  def cancel!(reason)
    return :idle unless @agent

    case @agent.status
    when :running, :stopping
      @agent.cancel(reason)
      :ok
    when :waiting_approval
      # cancel first, THEN deny: the parked fiber unparks into a turn that
      # already knows it is stopping (docs/subagents.md §8). Each denial is an
      # ordinary durable append, so the cards settle in the transcript too.
      @agent.cancel(reason)
      @ctx[:approvals].deny_pending!(@session.id, reason: reason) if @ctx.service?(:approvals)
      :ok
    else
      :idle
    end
  end

  private

  # One place where a turn is driven on the shared reactor, so run and resume
  # share the busy flag and the same failure rendering.
  def drive
    @busy = true
    Async do
      yield
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

  # Never abandon a registered agent: dispose whatever agent currently
  # occupies the slot we're about to spawn into — the one for the
  # target session (reselecting the active session, or an earlier
  # visit left it registered) or, failing that, the one we're
  # switching away from. Without this, spawn_agent below collides
  # (one live agent per session) instead of silently leaking the old
  # forked context the way it used to.
  def drop_stale_agent!(target_session_id = nil)
    old = (target_session_id && @ctx[:loop].agent_for_session(target_session_id)) || @agent
    @ctx[:loop].dispose_agent(old.id) if old && old.status == :idle
  end

  def child_sessions = child_session_ids(session_entries(@ctx[:sessions]))

  # Newest first, skipping Task runs: the console opens on something a human
  # can actually talk to.
  def most_recent_root_session_id
    entries = session_entries(@ctx[:sessions])
    kids = child_session_ids(entries)
    entries.find { |(id, _events)| !kids.include?(id) }&.first
  end
end

def page_html(world, usage, state)
  <<~HTML
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Terret console</title>
      <style>
        body { font: 15px/1.5 system-ui, sans-serif; margin: 0; display: flex; min-height: 100vh; }
        nav#sessions { width: 240px; flex-shrink: 0; background: #f7f7f8; padding: 1rem .75rem; box-sizing: border-box; overflow-y: auto; }
        nav#sessions form { margin: 0 0 .25rem; }
        nav#sessions button { width: 100%; text-align: left; border: 0; background: transparent; padding: .5rem; border-radius: .375rem; cursor: pointer; font: inherit; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        nav#sessions button:hover { background: #ececf1; }
        nav#sessions button.active { background: #e3e3ea; font-weight: 600; }
        nav#sessions button.child { padding-left: 1.25rem; color: #666; font-size: .9em; }
        nav#sessions button.new { border: 1px solid #ccc; text-align: center; margin-bottom: 1rem; }
        main { flex: 1; max-width: 680px; margin: 2rem auto; padding: 0 1rem; }
        header { display: flex; justify-content: space-between; align-items: baseline; color: #666; }
        .world { color: #999; font-size: .78em; font-family: ui-monospace, monospace; margin: .25rem 0 1rem; word-break: break-all; }
        .msg { padding: .5rem .75rem; border-radius: .5rem; margin: .5rem 0; white-space: pre-wrap; }
        .msg:empty { display: none; } /* a tool-only step never fills its bubble */
        .user { background: #e8f0fe; margin-left: 20%; }
        .assistant { background: #f5f5f5; margin-right: 20%; }
        .tool { color: #666; font-family: ui-monospace, monospace; font-size: .85em; margin: .25rem 0; white-space: pre-wrap; word-break: break-word; }
        .tool.call b { color: #333; }
        .tool.error { color: #c00; }
        .meta { color: #999; font-size: .8em; margin: .25rem 0; }
        .meta.cancelled { color: #b26a00; font-weight: 600; }
        .meta.failed { color: #c00; font-weight: 600; }
        .ledger { font-size: .8em; margin: 0 0 .5rem; color: #888; }
        .ledger form { display: inline; margin: 0; }
        .ledger button.link { border: 0; background: none; padding: 0; font: inherit; color: #1a73e8; text-decoration: underline; cursor: pointer; }
        ul.todos { list-style: none; padding: .375rem 0 .375rem .75rem; margin: .5rem 0; border-left: 3px solid #d7d7dd; }
        li.todo { font-size: .9em; color: #444; }
        li.todo .box { display: inline-block; width: 1.4em; }
        li.todo.done { color: #999; text-decoration: line-through; }
        li.todo.active { color: #222; font-weight: 600; }
        .approval { border: 1px solid #e0b400; background: #fffbe6; border-radius: .5rem; padding: .625rem .75rem; margin: .5rem 0; }
        .approval.settled.approved { border-color: #2e7d32; background: #f1f8f2; }
        .approval.settled.denied { border-color: #c62828; background: #fdf1f1; }
        .approval-head { font-size: .9em; }
        .approval-args { font-family: ui-monospace, monospace; font-size: .78em; color: #555; white-space: pre-wrap; word-break: break-word; margin: .375rem 0; }
        .approval-actions { display: flex; gap: .5rem; }
        .approval-actions form { margin: 0; }
        .approval-actions button { padding: .25rem .75rem; border-radius: .375rem; border: 1px solid #bbb; background: #fff; cursor: pointer; font: inherit; font-size: .9em; }
        .approval-actions button.approved { border-color: #2e7d32; color: #2e7d32; }
        .approval-actions button.denied { border-color: #c62828; color: #c62828; }
        #composer { display: flex; gap: .5rem; margin-top: 1rem; align-items: center; }
        #composer form { display: flex; gap: .5rem; flex: 1; margin: 0; }
        #composer input { flex: 1; padding: .5rem; }
        #composer form:last-child:not(:only-child) { flex: 0; }
        #composer button.cancel { background: #fdf1f1; border: 1px solid #e39c9c; color: #a11; border-radius: .375rem; padding: .4rem .75rem; cursor: pointer; font: inherit; }
        #composer.readonly { color: #888; font-size: .9em; }
      </style>
    </head>
    <body>
      <nav id="sessions"></nav>
      <main>
        <header><span>terret · #{h(world[:model])}</span><span id="usage">#{h(usage_html(usage))}</span></header>
        <div class="world">
          workspace #{h(world[:workspace])}<br>
          sandbox #{h(world[:sandbox])} · approvals #{h(world[:approvals])} · redactor #{h(world[:redactor])}<br>
          tools #{h(world[:tools])}
        </div>
        <div id="transcript"></div>
        #{composer_html(state)}
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
    replay = Renderer.new(composer: false)
    events = host.session.events.dup
    queue = hub.subscribe
    events.each do |ev|
      html = replay.render(ev)
      body.write(sse_frame(html)) if html
    end
    body.write(sse_frame(sidebar_frame(sessions, host.session.id)))
    body.write(sse_frame(usage_frame(sessions, host.session.id)))
    body.write(sse_frame(composer_frame(composer_state(host))))
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

def form_params(request)
  URI.decode_www_form(request.read.to_s).to_h
rescue ArgumentError
  nil
end

# -- the world ----------------------------------------------------------------

model = ENV.fetch("TERRET_MODEL", "openai/gpt-5-mini")
workspace = File.expand_path("../tmp/web_chat_workspace", __dir__)
FileUtils.mkdir_p(workspace)
docker = ENV["TERRET_SANDBOX"] == "docker"
approvals = ENV["TERRET_APPROVALS"] == "1"
redacting = ENV["TERRET_REDACT"] != "0"
web_allow = ENV.fetch("TERRET_WEBFETCH_ALLOW", "example.com,*.wikipedia.org").split(",").map(&:strip)

rows = [
  { id: "session_store", plugin: Terret::Store::SQLite,
    config: { path: File.expand_path("../tmp/web_chat.sqlite3", __dir__) } },
  { id: "sessions",   plugin: Terret::Sessions },
  { id: "prompt",     plugin: Terret::Prompt },
  { id: "tools",      plugin: Terret::Tools::Registry },
  # the execution seams: every path realpath-contained to the workspace, every
  # argv wrapped by the sandbox row before it spawns
  { id: "sandbox",    plugin: Terret::Exec::SandboxNone },
  { id: "subprocess", plugin: Terret::Exec::Subprocess },
  { id: "fs",         plugin: Terret::Exec::FS,        config: { workspace: [workspace] } },
  { id: "shell",      plugin: Terret::Exec::Shell,     config: { cwd: workspace } },
  { id: "terminals",  plugin: Terret::Exec::Terminals, config: { cwd: workspace } },
  # the std roster
  { id: "std_files",     plugin: Terret::ToolsStd::Files },
  { id: "std_bash",      plugin: Terret::ToolsStd::Bash },
  { id: "std_terminals", plugin: Terret::ToolsStd::Terminals },
  { id: "std_web_fetch", plugin: Terret::ToolsStd::WebFetch, config: { allow: web_allow } },
  # delegation: the seam, then the tool that is thin over it
  { id: "subagents",     plugin: Terret::Subagents },
  { id: "std_task",      plugin: Terret::ToolsStd::Task },
  { id: "llm",        plugin: Terret::LLM::Service, config: { roles: { main: "openrouter/#{model}" } } },
  { id: "loop",       plugin: Terret::Loop },
  { id: "titler",     plugin: Terret::Titler }, # no :titler role configured — the fallback carries it
  { id: "openrouter", plugin: Terret::OpenRouter::Plugin,
    config: { title: "Terret web console", referer: "https://terret.org" } }
]

# Background jobs, the job_* tools and TodoWrite arrive with M8. Mounted when
# the gems on the load path carry them and quietly skipped when they do not,
# so this console runs against either tree.
rows << { id: "jobs",      plugin: Terret::Exec::Jobs, config: { cwd: workspace } } if defined?(Terret::Exec::Jobs)
rows << { id: "std_jobs",  plugin: Terret::ToolsStd::Jobs } if defined?(Terret::ToolsStd::Jobs)
rows << { id: "std_todo",  plugin: Terret::ToolsStd::Todo } if defined?(Terret::ToolsStd::Todo)

# Opt-in, matching the M6 posture: without this row nothing parks, and Bash
# outside a sandbox is `approval: :always`, so switching it on means every
# shell command and every mutating file tool waits for a human.
rows << { id: "approvals", plugin: Terret::Tools::Approvals } if approvals

# Credentials never enter the session log (§13). The cost is visible: while a
# scrubber is registered the loop holds each run of streamed text and appends
# it whole, so the transcript arrives in paragraphs rather than tokens.
if redacting
  patterns = [/sk-[A-Za-z0-9._-]{12,}/, Regexp.new(Regexp.escape(ENV.fetch("OPENROUTER_API_KEY")))]
  rows << { id: "redactor", plugin: Terret::Redactor, config: { patterns: patterns } }
end

loader = Hames::Loader.new
loader.layer(rows)
# One appended row moves EXECUTION into a container with zero tool changes
# (docs/exec.md §7). The gem is required only here, so the default boot needs
# neither docker nor the gem.
if docker
  require_relative "../gems/terret-sandbox-docker/lib/terret/sandbox/docker"
  loader.layer([{ id: "sandbox", plugin: Terret::Sandbox::Docker,
                  config: { image: ENV.fetch("TERRET_DOCKER_IMAGE", "ruby:slim"),
                            network: "none", workspace: [workspace] } }])
end
ctx = loader.boot!

ctx.with_owner("web-console-tools") do
  ctx[:tools].register(
    name: "weather", description: "Current weather for a city",
    params: { type: "object", properties: { city: { type: "string" } },
              required: ["city"] }
  ) { |city:| "22C, clear skies in #{city}" }
  ctx[:prompt].register_section("identity", priority: 1) do
    "You are Terret, a terse coding assistant being manually exercised from a local web console. " \
      "Your workspace is #{workspace}; every file path you use must be inside it. " \
      "Use the tools you are given rather than describing what you would do, and prefer the " \
      "Task tool when the user asks you to delegate."
  end
end

# The policy floor: everything the roster registered at boot, which for a local
# console is the permissive end of deny-by-default. It is a floor, not a
# ceiling — Tools::AllowList.update writes a durable policy/updated per session
# and the very next call honors it (the M6 hot-policy story).
floor = ctx[:tools].schemas.map { |s| s[:name] }.sort
Terret::Tools::AllowList.install(ctx, floor)

world = {
  model: model,
  workspace: workspace,
  sandbox: docker ? "docker (--network none)" : "none",
  approvals: approvals ? "on" : "off",
  redactor: redacting ? "on" : "off",
  tools: floor.join(", ")
}

hub = Hub.new
host = AgentHost.new(ctx, hub)
live = Renderer.new

# A sidebar rebuild is a store-wide scan, so only the events that can change
# what it says trigger one from another session's stream.
SIDEBAR_EVENTS = %w[session/created session/titled turn/end].freeze

ctx.with_owner("web-console") do
  # Events for OTHER sessions reach here too, now that a Task delegation runs a
  # whole turn on a child session: those must not land in the transcript the
  # human is reading. What they do earn is a sidebar refresh, which is how a
  # Task run shows up as its own entry while it happens.
  ctx.on("session/event") do |ev|
    if ev.session_id == host.session.id
      html = live.render(ev)
      hub.broadcast(html) if html
      hub.broadcast(usage_frame(ctx[:sessions], ev.session_id)) if ev.type == "turn/end"
      hub.broadcast(sidebar_frame(ctx[:sessions], host.session.id)) if SIDEBAR_EVENTS.include?(ev.type)
    elsif SIDEBAR_EVENTS.include?(ev.type)
      hub.broadcast(sidebar_frame(ctx[:sessions], host.session.id))
    end
  end
end

port = ENV.fetch("PORT", "9292").to_i
endpoint = Async::HTTP::Endpoint.parse("http://localhost:#{port}")

begin
  Sync do
    server = Async::HTTP::Server.for(endpoint) do |request|
      case [request.method, request.path]
      when ["GET", "/"]
        Protocol::HTTP::Response[200, { "content-type" => "text/html; charset=utf-8" },
                                 [page_html(world, ctx[:sessions].usage(host.session.id),
                                            composer_state(host))]]
      when ["GET", "/events"]
        sse_response(hub, host, ctx[:sessions])
      when ["POST", "/messages"]
        params = form_params(request)
        text = params && params["text"].to_s.strip
        if text.nil?
          Protocol::HTTP::Response[400, {}, ["malformed form body"]]
        elsif text.empty?
          Protocol::HTTP::Response[422, {}, ["missing text"]]
        elsif host.read_only?
          Protocol::HTTP::Response[409, {}, ["this session belongs to a subagent; it is read-only"]]
        elsif host.run(text)
          Protocol::HTTP::Response[204, {}, []]
        else
          Protocol::HTTP::Response[409, {}, ["a turn is already running"]]
        end
      when ["POST", "/approvals"]
        params = form_params(request)
        call_id = params && params["call_id"].to_s
        verdict = params && params["verdict"].to_s
        if params.nil?
          Protocol::HTTP::Response[400, {}, ["malformed form body"]]
        elsif !ctx.service?(:approvals)
          Protocol::HTTP::Response[409, {}, ["no approvals row is mounted; start with TERRET_APPROVALS=1"]]
        elsif !%w[approved denied].include?(verdict)
          Protocol::HTTP::Response[422, {}, ["verdict must be approved or denied"]]
        elsif !ctx[:approvals].pending?(host.session.id, call_id)
          # a double click, or a card left over from a turn that has since
          # closed: appending a second verdict would only pollute the log
          Protocol::HTTP::Response[409, {}, ["#{call_id} has no pending approval"]]
        else
          host.resolve(call_id, verdict, verdict == "denied" ? "denied from the console" : nil)
          Protocol::HTTP::Response[204, {}, []]
        end
      when ["POST", "/cancel"]
        if host.cancel!("cancelled from the console") == :ok
          Protocol::HTTP::Response[204, {}, []]
        else
          Protocol::HTTP::Response[409, {}, ["nothing is running"]]
        end
      when ["POST", "/session"]
        if host.busy?
          Protocol::HTTP::Response[409, {}, ["a turn is already running"]]
        else
          host.reset!
          live = Renderer.new # the live renderer's DOM state belongs to the session it left
          broadcast_session(hub, ctx[:sessions], host)
          Protocol::HTTP::Response[204, {}, []]
        end
      when ["POST", "/session/select"]
        params = form_params(request)
        id = (params && params["id"]).to_s
        if host.busy?
          Protocol::HTTP::Response[409, {}, ["a turn is already running"]]
        elsif id.empty? || !ctx[:sessions].session_ids.include?(id)
          Protocol::HTTP::Response[404, {}, ["unknown session"]]
        else
          host.select!(id)
          live = Renderer.new
          broadcast_session(hub, ctx[:sessions], host)
          Protocol::HTTP::Response[204, {}, []]
        end
      else
        Protocol::HTTP::Response[404, {}, ["not found"]]
      end
    end
    puts "terret web console on http://localhost:#{port}"
    puts "  model      #{model}"
    puts "  workspace  #{workspace}"
    puts "  sandbox    #{world[:sandbox]}#{docker ? '' : '   (TERRET_SANDBOX=docker to run execution in a container)'}"
    puts "  approvals  #{world[:approvals]}#{approvals ? '' : '   (TERRET_APPROVALS=1 to park mutating tools on a human)'}"
    puts "  redactor   #{world[:redactor]}#{redacting ? '   (holds streamed text until each run ends; TERRET_REDACT=0 to stream live)' : ''}"
    puts "  tools      #{floor.join(', ')}"
    server.run
  end
ensure
  # A console killed with Ctrl-C must not leave a bash, a PTY, or a container
  # behind it.
  ctx[:shell].close_all     if ctx.service?(:shell)
  ctx[:terminals].close_all if ctx.service?(:terminals)
  ctx[:sandbox].stop        if ctx.service?(:sandbox) && ctx[:sandbox].isolated?
end
