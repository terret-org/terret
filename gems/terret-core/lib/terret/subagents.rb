# frozen_string_literal: true

module Terret
  # ctx[:subagents] — the delegation seam, sole-provider like
  # ctx[:session_store] and ctx[:summarizer]. This is the fork provider; the
  # seam, the other two providers plan §6.4 names, and the lifecycle below are
  # docs/subagents.md §§1-3.
  #
  #   ctx[:subagents].run(prompt:, ctx:) # => Result(text:, session_id:, usage:, status:)
  #
  # `ctx:` is the CALLING AGENT's context and it is an explicit argument
  # rather than a service ivar for one reason: it is what makes the
  # no-escalation guarantee structural. No path through this provider can
  # build a child from the root, so a child inherits the caller's roster and
  # its install-time policy FLOOR — an agent whose FLOOR is Read and Grep
  # cannot ask a child to run Bash. The qualifier matters (docs/subagents.md
  # §3): a policy hot-*narrowed* mid-session does not carry to children spawned
  # after it, because the child's session is fresh and holds no policy/updated,
  # so it runs at the floor rather than at the parent's live, narrowed set. A
  # narrowing that must reach children belongs in the floor (a config row).
  class Subagents < Hames::Service
    service_key :subagents
    inject :loop, :sessions
    config_schema({}) # spawns delegated agents; takes no config of its own

    # `status` is the child's TURN status — :completed, :cancelled, :rejected
    # or :empty (a failure raises instead). A caller rendering the child's text
    # needs it to tell "had nothing to say" from "was stopped", and re-reading
    # the child's log for a fact the turn already returned is a worse seam.
    Result = Data.define(:text, :session_id, :usage, :status)

    def start(ctx)
      @ctx = ctx
    end

    # Nothing is captured from config, so a swapped row governs the very next
    # delegation with nothing to re-derive.
    def reconfigure(_config); end

    # Spawn a child inside a fork of the caller's context, run one turn to
    # completion on a fresh durable session, and hand back what it said, where
    # it said it, and what it cost.
    #
    # The child's session is FRESH, not `Sessions#fork`ed: a subagent inherits
    # its parent's capabilities, not its parent's transcript.
    #
    # AgentCapExceeded raises straight through rather than being wrapped: a
    # refused spawn is the caller's answer, not something that happened inside
    # a child.
    def run(prompt:, ctx:)
      sessions = @ctx[:sessions]
      loop_service = @ctx[:loop]
      session = sessions.create
      agent = loop_service.spawn_agent(session_id: session.id,
                                       id: "subagent-#{session.id}", parent: ctx)
      # Marked before the turn can start: nothing routes an approval request
      # for this session to a human, so the gate must deny rather than park on
      # a verdict that can never arrive. A parked child would hold the parent's
      # fiber forever and there is no one to unstick it.
      agent.unattended = true
      begin
        # The ordinary Loop: same steps, same MAX_STEPS ceiling, same pipeline,
        # same approvals gate, same allow list. run_turn's own input path is
        # what appends the prompt as a durable user/message.
        status = loop_service.run_turn(agent, prompt)
        Result.new(text: final_text(sessions, session.id), session_id: session.id,
                   usage: sessions.usage(session.id), status: status)
      rescue StandardError => e
        # A stack trace in a tool result is context the parent's model cannot
        # act on and pays for on every subsequent request. The session id is
        # the pointer to where the whole story actually is.
        raise Tools::Failure,
              "the subagent turn failed (#{e.class}); its session #{session.id} has the story"
      ensure
        dispose(loop_service, agent)
      end
    end

    private

    # The child's last word, projected from its log like every other
    # model-visible fact. A turn that closed without one (rejected, empty, or
    # cancelled before a first reply) answers nil, and the caller renders it.
    def final_text(sessions, session_id)
      sessions.derive_messages(session_id).reverse_each
              .find { |m| m.role == :assistant }&.text
    end

    # Unconditional, including when the turn raised: the fork goes with the
    # agent, so every tool, listener, and effect the child installed dies at
    # the same moment. A disposal that itself fails must not replace the
    # failure the caller is already being told about.
    def dispose(loop_service, agent)
      loop_service.dispose_agent(agent.id)
    rescue StandardError => e
      warn "terret: subagent #{agent.id} would not dispose: #{e.class}: #{e.message}"
    end
  end
end
