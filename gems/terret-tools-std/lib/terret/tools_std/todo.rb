# frozen_string_literal: true

module Terret
  module ToolsStd
    # `TodoWrite` (docs/subagents.md §7) — Claude Code's name and Claude Code's
    # parameter shape, verbatim, per the M7 rule.
    #
    # This is the smallest illustration in the codebase of what "model-visible
    # means logged" actually buys. The handler validates the statuses, renders
    # the list back as the tool result, and holds NO state at all — that echo
    # is its only storage. The list is durable because the tool result is
    # durable; `derive_messages` projects it into the next request the same way
    # it projects every other result; a restart replays it for free; and
    # `resume_turn` re-derives it with no special case, because there is no
    # special case. A todo SERVICE would have been a second source of truth to
    # reconcile with the log after every crash, and it would disagree with it
    # eventually.
    #
    # One honest limit: compaction can erase it. A `session/compacted` boundary
    # that swallows the last TodoWrite result replaces it with a summary, and
    # whether the plan survives depends on whether the summarizer kept it. The
    # model writes a new list; nothing is corrupted.
    #
    # `concurrency: :serial` because the semantics are order-dependent — two
    # writes in one message mean the last one wins, and "last" should be a
    # property of the message rather than of which fiber returned first.
    class Todo < Hames::Service
      service_key :tools_std_todo
      inject :tools

      # The rendering, and the whole of this tool's vocabulary. An unknown
      # status is refused against exactly this set rather than coerced to
      # something plausible: a coerced status makes the list say a thing the
      # model did not say, in the one place the model keeps its plan.
      BOXES = { "pending" => "[ ]", "in_progress" => "[~]", "completed" => "[x]" }.freeze

      FIELDS = %w[content status activeForm].freeze

      DESCRIPTION = "Write the task list for this session. Send the WHOLE list every time: " \
                    "what this call does not mention is gone, because the result is the only " \
                    "place the list is kept. Mark exactly one item in_progress while you work " \
                    "on it, and complete it before starting the next."

      def start(ctx)
        @ctx = ctx
        register_todo_write
      end

      # Nothing is captured from config; there is no knob on this row, and
      # there is no state for one to govern.
      def reconfigure(_config); end

      private

      # `ctx:` is passed explicitly, like the rest of the roster: the registry
      # would otherwise record the frame on the context it was started in (the
      # root), so a roster mounted into a forked agent scope would leave a
      # registration behind that outlives the fork.
      def register_todo_write
        item = {
          type: "object",
          properties: {
            content: { type: "string", description: "The task, as an imperative: \"Run the tests\"" },
            status: { type: "string", enum: BOXES.keys,
                      description: "pending, in_progress, or completed" },
            activeForm: { type: "string",
                          description: "The present continuous form shown while the task is " \
                                       "in progress: \"Running the tests\"" }
          },
          required: FIELDS
        }
        params = {
          type: "object",
          properties: { todos: { type: "array", items: item,
                                 description: "The complete list, every item, every time" } },
          required: %w[todos]
        }
        # `todos` is required in the schema and defaulted here: an omitted
        # keyword would cost a whole turn to an ArgumentError, where a
        # defaulted one costs a result the model can read and correct.
        @ctx[:tools].register(name: "TodoWrite", description: DESCRIPTION, params: params,
                              mutating: false, approval: :never, concurrency: :serial,
                              ctx: @ctx) do |todos: nil|
          render(items!(todos))
        end
      end

      def items!(todos)
        unless todos.is_a?(Array)
          raise Terret::Tools::Failure,
                "TodoWrite needs `todos`: the whole list, as an array of " \
                "{content, status, activeForm} objects"
        end

        todos.each_with_index.map { |item, index| item!(item, index + 1) }
      end

      # A model writes JSON, and which of the two key shapes an item arrives in
      # depends on the adapter that parsed it. Normalizing once here is cheaper
      # than a validation error nobody can act on for a list that was written
      # correctly.
      #
      # Every refusal names the item's POSITION, because in a list of todos
      # nothing else tells them apart — and a hole in the list has no content
      # to be named by at all. `nil` is the case that needs saying twice: it
      # answers `respond_to?(:to_h)` and `nil.to_h` is `{}`, so a missing item
      # used to be reported back as an empty object the model never wrote.
      def item!(item, position)
        unless !item.nil? && item.respond_to?(:to_h) && !item.is_a?(Array)
          raise Terret::Tools::Failure,
                "every todo must be an object with content, status and activeForm; " \
                "item #{position} is #{item.inspect}"
        end

        item = item.to_h.transform_keys(&:to_s)

        # `status` is deliberately not checked for being text here. A status
        # that arrived as something else is a WRONG status rather than an
        # absent one, and the branch below is the one that can say so while
        # naming what the model actually wrote.
        missing = %w[content activeForm].reject { |f| item[f].is_a?(String) }
        unless missing.empty?
          raise Terret::Tools::Failure,
                "every todo needs #{FIELDS.join(', ')}; item #{position} is missing " \
                "#{missing.join(', ')}: #{item.inspect}"
        end

        unless BOXES.key?(item["status"])
          raise Terret::Tools::Failure,
                "#{item['status'].inspect} is not a todo status (item #{position}); use one " \
                "of #{BOXES.keys.join(', ')}"
        end

        item
      end

      def render(items)
        return "(the todo list is empty)" if items.empty?

        items.map { |item| "- #{BOXES.fetch(item['status'])} #{line(item)}" }.join("\n")
      end

      # One item, one line. This is the forgeability register the LEDGER
      # literal keeps in tools_std/jobs.rb, and it is the one place in the
      # roster where forging matters rather than merely misleading: the
      # rendered list IS the state, so a content string carrying a newline
      # could write a checkbox line of its own and hand the model back a task
      # it never completed as done. Escaped rather than dropped — what the
      # model wrote stays legible, it just cannot be a line.
      def line(item) = label(item).gsub(/[\r\n]/) { |c| c == "\n" ? "\\n" : "\\r" }

      # The running item is shown in its active form, which is the one thing
      # activeForm is for; everything else is shown as what it is.
      def label(item) = item["status"] == "in_progress" ? item["activeForm"] : item["content"]
    end
  end
end
