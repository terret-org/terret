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
      config_schema({}) # the Task tool takes no config (see the :subagents seam)

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
        # Both are required in the schema and both are defaulted here. A
        # delegation nobody can name is one nobody can follow, and a model
        # writing one without a prompt has made a mistake — but an omitted
        # keyword would cost a whole turn to an ArgumentError, where a
        # defaulted one costs a result the model can read and correct.
        # `description` is a label for a log or a UI line; the child never
        # sees it, so nothing here uses it.
        tool("Task", DESCRIPTION, params, mutating: false, approval: :never,
             concurrency: :parallel) do |session_id:, description: nil, prompt: nil|
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
        if prompt.nil? || (prompt.is_a?(String) && prompt.strip.empty?)
          raise Terret::Tools::Failure,
                "Task needs a prompt: it is everything the subagent will see. " \
                "Nothing was delegated."
        end
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
      #
      # A turn that did not complete is reported too. "Had nothing to say" and
      # "was stopped part-way" are different facts about a delegation, and a
      # model shown only the child's last sentence would summarize the second
      # as if it were an answer.
      def render(result)
        text = result.text.to_s
        remarks = ["child session #{result.session_id}"]
        unless result.status == :completed
          remarks << "the subagent's turn ended #{result.status} rather than completing"
        end
        "#{text.empty? ? '(no reply)' : text}\n#{LEDGER}\n#{remarks.join("\n")}"
      end
    end
  end
end
