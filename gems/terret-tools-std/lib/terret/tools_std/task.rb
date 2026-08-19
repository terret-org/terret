# frozen_string_literal: true

module Terret
  module ToolsStd
    # `Task` (docs/subagents.md §4) — Claude Code's name verbatim, per the M7
    # rule: allow lists in the wild are already written against `Task`, and a
    # Terret-native name would buy a translation layer that does nothing but
    # rename, forever. The tool is thin on purpose: it talks to
    # `ctx[:subagents].run` and knows nothing else about what a subagent is.
    #
    # `approval: :never` on a tool that can obviously mutate the world is the
    # one entry here that looks wrong and is not. The metadata describes what
    # THIS call does directly, and this call starts a conversation. Everything
    # the child then does passes the child's own pipeline: its own allow list,
    # its own approvals gate, one decision per actual effect. Gating `Task`
    # itself would ask a human to approve a call whose effects are not knowable
    # until after the approval is granted — the worst possible moment to ask —
    # and would then ask again, correctly, for each real effect inside.
    #
    # `concurrency: :parallel` because a Task call is a whole turn of latency,
    # which is exactly the case the barrier was declared for.
    class Task < Hames::Service
      service_key :tools_std_task
      inject :tools, :loop, :subagents

      # The same literal Bash and WebFetch separate their output with, and it
      # carries the same caveats: a readability device rather than a security
      # boundary — a child could print the line itself — whose actual delivery
      # is that the genuine remarks are always last and always advisory data
      # that nothing downstream acts on.
      LEDGER = "--- terret ---"

      DESCRIPTION = "Delegate a whole task to a fresh subagent and get back its final answer. " \
                    "The subagent starts with an empty conversation: the prompt is everything " \
                    "it will see, so state the goal, the context it needs, and what to report " \
                    "back. It runs with the same tools and the same permissions you have, and " \
                    "its own work is logged in its own session rather than in yours."

      def start(ctx)
        @ctx = ctx
        register_task
      end

      # Nothing is captured from config; there is no knob on this row.
      def reconfigure(_config); end

      private

      # `ctx:` is passed explicitly: the registry would otherwise record the
      # frame on the context it was started in (the root), so a roster mounted
      # into a forked agent scope would leave a registration behind that
      # outlives the fork.
      def tool(name, description, params, mutating:, approval:, concurrency:, &handler)
        @ctx[:tools].register(name: name, description: description, params: params,
                              mutating: mutating, approval: approval,
                              concurrency: concurrency, ctx: @ctx, &handler)
      end

      def register_task
        params = {
          type: "object",
          properties: {
            description: { type: "string",
                           description: "A short label for the delegation, three to five words" },
            prompt: { type: "string",
                      description: "The subagent's whole instruction; it sees nothing else" }
          },
          required: %w[description prompt]
        }
        # `description` is a label for a log or a UI line and the child never
        # sees it, so it is accepted and not used here. It is still required in
        # the schema: a delegation nobody can name is one nobody can follow.
        # Defaulted anyway, because an omitted keyword would cost a whole turn
        # to an ArgumentError rather than a readable result.
        tool("Task", DESCRIPTION, params, mutating: false, approval: :never,
             concurrency: :parallel) do |prompt:, session_id:, description: nil|
          render(delegate(prompt, session_id))
        end
      end

      # The load-bearing line of this tool. Task is registered on the ROOT
      # context like the rest of the roster, so its closure captures the root
      # and not any agent; what makes the child inherit the CALLER's roster and
      # policy floor is looking the caller up here. `session_id` is injected by
      # the registry and merged last, so a model that writes one into its
      # arguments is naming somebody else's context and simply loses.
      def delegate(prompt, session_id)
        unless prompt.is_a?(String)
          raise Terret::Tools::Failure,
                "prompt must be a string; got #{prompt.class}. Nothing was delegated."
        end

        agent = @ctx[:loop].agent_for_session(session_id)
        unless agent
          raise Terret::Tools::Failure,
                "no live agent owns this session, so Task has no context to delegate from"
        end

        @ctx[:subagents].run(prompt: prompt, ctx: agent.ctx)
      end

      # The ledger is not cosmetic and it is never omitted: nothing in the
      # parent's log links it to the child's session except this line.
      def render(result)
        text = result.text.to_s
        body = text.empty? ? "(no reply)" : text
        "#{body}\n#{LEDGER}\nchild session #{result.session_id}"
      end
    end
  end
end
