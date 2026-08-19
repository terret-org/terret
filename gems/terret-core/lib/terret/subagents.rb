# frozen_string_literal: true

module Terret
  # ctx[:subagents] — the delegation seam (plan §6.4, docs/subagents.md §1), a
  # SOLE-PROVIDER key like ctx[:session_store] and ctx[:summarizer]. Nothing
  # sits behind it dispatching between providers: "what is a subagent in this
  # deployment" is one answer for the whole process, decided in a config row,
  # rather than a roster the Task tool picks from per call.
  #
  #   ctx[:subagents].run(prompt:, ctx:) # => Result(text:, session_id:, usage:)
  #
  # `ctx:` is the CALLING AGENT's context, not the root, and it is an explicit
  # argument rather than a service ivar for exactly one reason: it is what
  # makes the no-escalation guarantee structural. The child is forked from the
  # caller, so it starts with the tools that agent can see and the
  # tools/pre_execute listeners that govern it — its AllowList included — and
  # NO path through this provider can build a child from the root context. An
  # agent restricted to Read and Grep cannot ask a child to run Bash.
  #
  # This is the fork provider, the one M8 builds. Plan §6.4's other two — a
  # delegated turn to an external agent over ACP, and a pooled worker — are
  # recorded in §14 as deferred. A seam with one provider is still a seam;
  # what makes it one is that the Task tool talks to `run` and knows nothing
  # else.
  class Subagents < Hames::Service
    service_key :subagents
    inject :loop, :sessions

    Result = Data.define(:text, :session_id, :usage)

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
    # its parent's capabilities, not its parent's transcript. That is most of
    # why delegating is worth doing — a long, expensive parent context does not
    # have to be re-read to answer a bounded question.
    #
    # The agent cap is the only ceiling. A child holds its slot for the length
    # of its run, so a wide parallel fan-out is bounded by the same cap as the
    # fleet and AgentCapExceeded raises straight through: it is the caller's
    # answer, not something that happened inside a child.
    def run(prompt:, ctx:)
      sessions = @ctx[:sessions]
      loop_service = @ctx[:loop]
      session = sessions.create
      agent = loop_service.spawn_agent(session_id: session.id,
                                       id: "subagent-#{session.id}", parent: ctx)
      begin
        # The ordinary Loop: same steps, same MAX_STEPS ceiling, same pipeline,
        # same approvals gate, same allow list. run_turn's own input path is
        # what appends the prompt as a durable user/message.
        loop_service.run_turn(agent, prompt)
        Result.new(text: final_text(sessions, session.id), session_id: session.id,
                   usage: sessions.usage(session.id))
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
