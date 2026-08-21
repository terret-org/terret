# frozen_string_literal: true

require "securerandom"
require_relative "wire"
require_relative "bounded_queue"

module Terret
  module ACP
    # The ACP v1 protocol engine (docs/acp.md). It is to terret-acp what
    # Connection is to terret-ws: transport-facing, holding no session
    # vocabulary of its own. It consumes `session/event` and projects it to
    # `session/update` notifications, and it drives `ctx[:loop]` — the exact
    # two-seam shape the socket uses, with JSON-RPC over stdio as the only new
    # thing. Nothing reaches the editor that is not in the log first.
    #
    # One connection, many sessions: unlike the socket's one-connection-per-
    # agent rule, an editor calls `session/new` repeatedly over a single
    # stdio pair, so the server routes prompts and cancels by `sessionId` and
    # keys agents `agent-#{sid}` (spawn_agent's default, same as ws).
    #
    # Concurrency (plan §8): the read loop PARKS the fiber on `input.gets`, it
    # never blocks the thread — one reactor drives every agent in the process.
    # A turn runs in a task rooted on `runner_task` (the server task, not the
    # read loop), so a disconnect cannot cancel a turn in flight.
    #
    # Outbound is DECOUPLED from the event bus, exactly as terret-ws decouples
    # it (ws/connection.rb): `project` runs inside `Sessions#fan_out`'s
    # synchronous drainer, so if it wrote to a slow editor's pipe directly it
    # would park that drainer and stall every agent's event dispatch in the
    # process. Instead every producer ENQUEUES a frame (non-blocking) onto a
    # bounded queue, and one dedicated writer fiber is the only thing that ever
    # parks on the pipe. That writer is also the single serialization point, so
    # a streaming turn's notifications and a request's response never interleave
    # without a mutex. A queue that fills means the editor stopped reading:
    # its output is dropped rather than blocking the bus (finding: a lagging
    # editor must never wedge other sessions).
    class Server
      PROTOCOL_VERSION = 1

      # Bounds the outbound queue so a stalled editor cannot grow it without
      # limit. Not config: it is a safety bound, not a knob (the acp row has no
      # config surface). Injectable so a test can force the lag path.
      DEFAULT_QUEUE_LIMIT = 512

      # Std-roster tool -> ACP ToolKind (docs/acp.md, "Resolved in Task 7").
      # Everything not here — Task, every mcp__<server>__<tool> whose name
      # arrives at runtime, any third-party tool — falls to the enum's own
      # `other`.
      TOOL_KINDS = {
        "Read" => "read",
        "Glob" => "search", "Grep" => "search",
        "Write" => "edit", "Edit" => "edit",
        "Bash" => "execute",
        "WebFetch" => "fetch"
      }.freeze

      def initialize(ctx:, input:, output:, runner_task: Async::Task.current,
                     queue_limit: DEFAULT_QUEUE_LIMIT)
        @ctx = ctx
        @input = input
        @output = output
        @runner_task = runner_task
        @queue = BoundedQueue.new(queue_limit)
        @sessions = {}  # sessionId => Agent, this connection's sessions
        @pending = {}   # sessionId => the request id of its pending session/prompt
        @announced = {} # toolCallId => true, tool_calls this connection has sent
        @tail = nil
      end

      # Serve until the input closes. One listener projects every durable append
      # for our sessions onto the queue; a writer fiber drains the queue to the
      # output; the read loop dispatches inbound frames. The writer is rooted on
      # this connection's own task so it dies with the connection — unlike turn
      # tasks, which root on runner_task and outlive it.
      def run
        @tail = @ctx.on("session/event") { |ev| project(ev) }
        Sync do |task|
          writer = task.async { drain_writes }
          read_loop
        ensure
          # EOF disposes the connection, NOT the agents (docs/acp.md): they stay
          # in the loop registry, parked per the M6 lifecycle, and re-attach
          # through session/prompt. Closing the queue lets the writer flush what
          # is already queued, then end.
          @tail&.call
          @tail = nil
          @queue.close
          writer&.wait
        end
      end

      private

      # -- transport -------------------------------------------------------------

      def read_loop
        while (line = @input.gets)
          text = line.chomp
          next if text.empty? # a blank line between frames is noise, not a parse error

          dispatch(text)
        end
      rescue IOError, SystemCallError
        # The input was closed under us (the editor died mid-read) rather than
        # reaching a clean EOF; either way there is nothing more to read.
        nil
      end

      # The only fiber that may park on the pipe. A slow editor parks it here,
      # never the event-bus drainer.
      def drain_writes
        while (frame = @queue.pop)
          @output.write("#{frame}\n")
          @output.flush if @output.respond_to?(:flush)
        end
      rescue IOError, SystemCallError => e
        # The editor is gone (a broken pipe). Stop writing and close the queue so
        # producers lag immediately rather than filling the bound; the read loop
        # winds down at EOF and the agents survive, their turns logged durably.
        warn "terret-acp: writer stopped (client gone?): #{e.class}: #{e.message}"
        @queue.close
      end

      # Non-blocking, always — this is called from the event-bus drainer, from
      # the read loop, and from turn tasks, and none of them may block on a slow
      # pipe. A full queue means the editor stopped reading.
      def enqueue(frame)
        return if @queue.push(frame)

        lag!
      end

      # The editor fell too far behind. Drop its output rather than block the
      # shared bus; the connection lingers reading until EOF, producing nothing.
      def lag!
        return if @queue.closed?

        warn "terret-acp: client lagged; dropping output (agents survive, turns still log)"
        @queue.close
      end

      # -- inbound ---------------------------------------------------------------

      def dispatch(line)
        msg = Wire.decode(line)
        case msg.kind
        when :parse_error then enqueue(Wire.error(id: nil, code: -32700, message: "parse error"))
        when :invalid then enqueue(Wire.error(id: msg.id, code: -32600, message: "invalid request"))
        when :notification then handle_notification(msg)
        when :request then handle_request(msg)
        # :response — this server sends no requests to the client, so an
        # inbound response correlates with nothing; drop it rather than error.
        end
      rescue StandardError => e
        # A bug handling one frame must never kill the read loop: an editor that
        # sends something we mishandle gets an answer (if it was a request) and
        # the loop reads on.
        warn "terret-acp: dropping frame on dispatch error: #{e.class}: #{e.message}"
        enqueue(Wire.error(id: msg&.id, code: -32603, message: "internal error")) if msg&.request?
      end

      def handle_request(msg)
        params = msg.params.is_a?(Hash) ? msg.params : {}
        case msg.method
        when "initialize" then enqueue(Wire.response(id: msg.id, result: initialize_result))
        when "session/new" then new_session(msg.id, params)
        when "session/prompt" then prompt(msg.id, params)
        else
          # Every unimplemented method, including authenticate (authMethods is
          # empty, so it is never reached) and every v2 name, answers here.
          enqueue(Wire.error(id: msg.id, code: -32601, message: "method not found: #{msg.method}"))
        end
      end

      def handle_notification(msg)
        params = msg.params.is_a?(Hash) ? msg.params : {}
        case msg.method
        when "session/cancel" then cancel(params[:sessionId])
        when "$/cancel_request" then cancel(@pending.key(params[:requestId]))
        # Any other notification is ignored — a notification may always be.
        end
      end

      # -- methods ---------------------------------------------------------------

      def initialize_result
        # Reports what this boot mounts, not what the gems can do (docs/acp.md).
        # v1 advertises no loadSession, no prompt capabilities beyond the
        # text+resource_link baseline, and no mcp/session subgroups, so the
        # capabilities object is empty rather than a wall of `false`.
        { protocolVersion: PROTOCOL_VERSION, agentCapabilities: {}, authMethods: [] }
      end

      def new_session(id, params)
        cwd = params[:cwd]
        mcp = params[:mcpServers]
        unless cwd.is_a?(String) && !cwd.empty?
          return enqueue(Wire.error(id: id, code: -32602,
                                    message: "session/new requires a cwd (an absolute path)"))
        end
        unless mcp.is_a?(Array)
          return enqueue(Wire.error(id: id, code: -32602,
                                    message: "session/new requires mcpServers (a list, possibly empty)"))
        end

        # Spawn BEFORE the durable create, so a registry refusal (the agent cap)
        # cannot leave an orphaned session in the log — create only runs once the
        # agent exists. cwd does not widen filesystem reach and mcpServers are
        # not mounted in v1 (docs/acp.md): the profile's floor governs.
        sid = SecureRandom.hex(6)
        agent = @ctx[:loop].spawn_agent(session_id: sid)
        @ctx[:sessions].create(id: sid)
        @sessions[sid] = agent
        enqueue(Wire.response(id: id, result: { sessionId: sid }))
      rescue AgentExists, AgentCapExceeded => e
        # A registry refusal is this process's business, not the client's fault;
        # it still deserves an answer rather than a dropped connection.
        enqueue(Wire.error(id: id, code: -32603, message: e.message))
      end

      def prompt(request_id, params)
        sid = params[:sessionId]
        agent = resolve_agent(sid)
        unless agent
          return enqueue(Wire.error(id: request_id, code: -32602, message: "unknown session #{sid.inspect}"))
        end

        blocks = params[:prompt]
        unless blocks.is_a?(Array) && !blocks.empty?
          return enqueue(Wire.error(id: request_id, code: -32602,
                                    message: "session/prompt requires a non-empty prompt"))
        end

        text = render_prompt(blocks)
        if text.empty?
          # A prompt whose blocks carry nothing we can act on (no text, only
          # unhandled block types) is invalid params — the fresh and resume
          # branches both refuse it rather than driving an empty turn.
          return enqueue(Wire.error(id: request_id, code: -32602,
                                    message: "session/prompt has no text content to act on"))
        end
        if @pending.key?(sid)
          return enqueue(Wire.error(id: request_id, code: -32600,
                                    message: "a prompt is already in flight for #{sid}"))
        end

        @pending[sid] = request_id
        drive_turn(agent, sid, text)
      end

      # The pending request stays open for the whole turn (docs/acp.md). The
      # turn task is rooted on runner_task so a disconnect cannot cancel it; on
      # completion it answers the pending prompt with the mapped stop reason.
      # A session whose log holds an open turn resumes it — an editor reopening
      # a project is the canonical way to meet a turn a killed process left
      # open — otherwise a fresh run_turn.
      def drive_turn(agent, sid, text)
        resuming = @ctx[:loop].resumable?(sid)
        @runner_task.async do
          status =
            if resuming
              agent.inject(text) # the prompt rides the resumed turn's next step
              @ctx[:loop].resume_turn(agent)
            else
              @ctx[:loop].run_turn(agent, text)
            end
          respond_prompt(sid, status)
        rescue StandardError => e
          # A turn that raised (a runaway MAX_STEPS overflow, an LLM outage) is
          # a request that could not complete, not a turn with a sad stop
          # reason: answer -32603, not a result (docs/acp.md, "Stop reasons").
          warn "terret-acp: turn failed for #{sid}: #{e.class}: #{e.message}"
          answer = @pending.delete(sid)
          enqueue(Wire.error(id: answer, code: -32603, message: "the turn failed: #{e.class}")) if answer
        end
      end

      def respond_prompt(sid, status)
        request_id = @pending.delete(sid) or return
        reason = stop_reason(status)
        if reason
          enqueue(Wire.response(id: request_id, result: { stopReason: reason }))
        else
          enqueue(Wire.error(id: request_id, code: -32603, message: "the turn failed"))
        end
      end

      # Terret's five turn statuses onto ACP's five stop reasons (docs/acp.md).
      # nil means "answer a -32603 error, not a result" — only `failed`, which
      # run_turn raises rather than returns, so it is reached defensively.
      def stop_reason(status)
        case status
        when :completed, :empty then "end_turn"
        when :cancelled then "cancelled"
        when :rejected then "refusal"
        when :failed then nil
        else "end_turn"
        end
      end

      def cancel(sid)
        agent = sid && (@sessions[sid] || @ctx[:loop].agent("agent-#{sid}"))
        return unless agent # a cancel for a session we do not know is a no-op

        # Lands on the same Agent#cancel the socket's cancel frame drives; the
        # turn closes cancelled at its next step boundary and respond_prompt
        # answers the pending prompt with stopReason "cancelled".
        agent.cancel
        # A parked agent cannot reach a boundary until its verdict lands, so a
        # cancel on one denies the pending approval too, if that row is mounted.
        if agent.status == :waiting_approval && @ctx.service?(:approvals)
          @ctx[:approvals].deny_pending!(agent.session_id, reason: "cancelled")
        end
      end

      # -- session resolution ----------------------------------------------------

      # This connection's session, or a re-attach: a live agent from a prior
      # connection, or a durable session resumed and given a fresh agent. The
      # last is the loadSession story done through session/prompt (docs/acp.md).
      def resolve_agent(sid)
        return nil unless sid.is_a?(String)
        return @sessions[sid] if @sessions.key?(sid)

        if (live = @ctx[:loop].agent("agent-#{sid}"))
          return @sessions[sid] = live
        end
        return nil unless @ctx[:sessions].session_ids.include?(sid)

        @ctx[:sessions].resume(sid)
        @sessions[sid] = @ctx[:loop].spawn_agent(session_id: sid)
      rescue AgentExists
        @sessions[sid] = @ctx[:loop].agent("agent-#{sid}") # a racing spawn won; use it
      end

      # -- outbound: session/event -> session/update -----------------------------

      def project(ev)
        return unless @sessions.key?(ev.session_id)

        update =
          case ev.type
          when "assistant/chunk"
            { sessionUpdate: "agent_message_chunk",
              content: text_block(ev.payload[:text]) }
          when "tool/call"
            announce(ev.payload[:id])
            tool_call_frame(ev.payload)
          when "tool/result"
            id = ev.payload[:id]
            # On the resume path complete_dangling can append a tool/result for a
            # call whose tool/call was already durable before the crash, so this
            # connection never announced it. A bare tool_call_update for an
            # unannounced id is a malformed stream to the editor — synthesize the
            # opening tool_call (pending) first, in order, ahead of the update.
            synthesize_tool_call(ev.session_id, id) unless @announced[id]
            failed = !ev.payload[:error].nil?
            { sessionUpdate: "tool_call_update", toolCallId: id,
              status: failed ? "failed" : "completed",
              content: tool_content(ev.payload[:error] || ev.payload[:content]) }
          end
        # There is no thinking part in Terret's LLM vocabulary — Text, ToolCall,
        # ToolResult and nothing else — so agent_thought_chunk has no source and
        # is never emitted. The other unmapped variants (plan, user_message_chunk,
        # the *_update family) have no Terret consumer either. See docs/acp.md.
        return unless update

        notify(ev.session_id, update)
      rescue StandardError => e
        # The synthesize lookup reads the log and could raise; a projection fault
        # must never surface into Sessions#append (emit isolates it too, but this
        # names the session).
        warn "terret-acp: projection failed for #{ev.session_id}: #{e.class}: #{e.message}"
      end

      def announce(id) = @announced[id] = true

      # Emit the opening tool_call for a call whose id this connection has not
      # announced, reading its name from the log. Ordered ahead of the caller's
      # tool_call_update because both go through the one FIFO queue.
      def synthesize_tool_call(sid, id)
        payload = tool_call_payload_for(sid, id) || { id: id, name: nil }
        announce(id)
        notify(sid, tool_call_frame(payload))
      end

      # rawInput is the logged args. Append already folded them through the
      # session scrubbers, so a credential that made it into a call argument
      # is [REDACTED] here the same way it is in the log — nothing reaches
      # the editor that is not in the log first. locations is filled when
      # the std file tools named a file_path, so the editor can follow along.
      def tool_call_frame(payload)
        args = payload[:args]
        frame = { sessionUpdate: "tool_call", toolCallId: payload[:id],
                  title: payload[:name].to_s, kind: tool_kind(payload[:name]),
                  status: "pending" }
        frame[:rawInput] = args unless args.nil?
        locs = locations_for(args)
        frame[:locations] = locs if locs
        frame
      end

      def locations_for(args)
        return unless args.is_a?(Hash)

        path = args[:file_path] || args["file_path"]
        return unless path.is_a?(String) && !path.empty?

        [{ path: path }]
      end

      def tool_call_payload_for(sid, id)
        @ctx[:sessions].fetch(sid).events.reverse_each
                       .find { |e| e.type == "tool/call" && e.payload[:id] == id }
                       &.payload
      end

      def tool_kind(name)
        name = name.to_s
        return TOOL_KINDS[name] if TOOL_KINDS.key?(name)
        return "execute" if name.start_with?("job_", "terminal_")

        "other"
      end

      def text_block(text) = { type: "text", text: text.to_s }

      def tool_content(body)
        return [] if body.nil?

        [{ type: "content", content: text_block(body) }]
      end

      # Baseline blocks are text and resource_link (docs/acp.md). Terret's
      # user/message is plain text, so a resource_link folds into the text as a
      # named reference; unknown block types are skipped leniently.
      def render_prompt(blocks)
        blocks.filter_map do |block|
          next unless block.is_a?(Hash)

          case block[:type]
          when "text" then block[:text]
          when "resource_link" then "#{block[:name] || block[:uri]} (#{block[:uri]})"
          end
        end.join("\n")
      end

      def notify(sid, update)
        enqueue(Wire.notification(method: "session/update",
                                  params: { sessionId: sid, update: update }))
      end
    end
  end
end
