# frozen_string_literal: true

module Terret
  module Tools
    Definition = Data.define(:name, :description, :params, :handler,
                             :mutating, :approval) do
      def schema = { name:, description:, parameters: params }
    end

    Call   = Data.define(:id, :name, :args, :session_id)
    Result = Data.define(:id, :content, :error)

    # ctx.tools — scoped registry + guarded execution pipeline. Registration
    # is an effect (unloading a plugin removes its tools). Execution runs the
    # three-waterfall pipeline: pre_execute (validate / veto / rewrite) ->
    # execute (a provider may replace execution wholesale) -> post_execute
    # (truncate / redact).
    class Registry < Hames::Service
      service_key :tools

      def start(ctx)
        @ctx = ctx
        @defs = {}
      end

      # Returns the registration's disposer.
      def register(name:, description:, params: {}, mutating: false,
                   approval: :never, &handler)
        d = Definition.new(name: name.to_s, description:, params:, handler:,
                           mutating:, approval:)
        @ctx.effect do
          @defs[d.name] = d
          -> { @defs.delete(d.name) }
        end
      end

      def schemas = @defs.values.map(&:schema)
      def fetch(name) = @defs.fetch(name.to_s)

      # Execution runs the three-waterfall pipeline: pre_execute (validate /
      # veto / rewrite) -> execute (a provider may replace execution
      # wholesale) -> post_execute (truncate / redact). Waterfalls dispatch
      # on `ctx`, which callers set to the AGENT's forked context so
      # per-agent policy listeners ride the fork (root listeners still run
      # first — fork dispatch chains parent-first). ctx is required — a
      # forgotten kwarg must fail loudly, not silently skip per-agent policy.
      def execute(call, ctx:)
        admitted = ctx.waterfall("tools/pre_execute", call)
        return Result.new(id: call.id, content: nil, error: admitted.reason) if admitted.is_a?(Veto)

        result = ctx.waterfall("tools/execute", admitted) do |c|
          begin
            d = fetch(c.name)
            Result.new(id: c.id, content: d.handler.call(**c.args), error: nil)
          rescue Failure => e
            Result.new(id: c.id, content: nil, error: e.message)
          rescue => e
            Result.new(id: c.id, content: nil, error: "#{e.class}: #{e.message}")
          end
        end
        ctx.waterfall("tools/post_execute", result)
      end
    end

    Veto = Data.define(:reason)

    # A domain failure whose message is the whole story: handlers raise it
    # when the error is the tool's outcome, not a bug. Registry#execute logs
    # it message-only; any other exception keeps its class name, because a
    # crash's class is diagnostics, not noise.
    Failure = Class.new(StandardError)

    # Deny-by-default allow list (plan §6.3), hot-reloadable (§12 M6): the
    # ACTIVE pattern set is the last durable policy/updated event in the
    # call's session, falling back to the install-time patterns as the floor.
    # update is an ordinary durable append — it takes effect on the very next
    # call with no reinstall, and replay rebuilds it, so a hot-reloaded
    # policy survives a restart while the floor only governs sessions that
    # never updated. Patterns are File.fnmatch globs; matching is
    # case-sensitive and "*" does not match dotfiles — both fail closed.
    module AllowList
      def self.install(ctx, patterns)
        floor = Array(patterns).map(&:to_s)
        ctx.on("tools/pre_execute") do |call, next_|
          active = current_patterns(ctx, call.session_id) || floor
          if active.any? { |p| File.fnmatch(p, call.name) }
            next_.(call)
          else
            Veto.new(reason: "#{call.name} is not on the allow list")
          end
        end
      end

      # Hot update: durable, per-session, last one wins.
      def self.update(ctx, session_id, patterns)
        ctx[:sessions].append(session_id, "policy/updated",
                              { patterns: Array(patterns).map(&:to_s) })
      end

      def self.current_patterns(ctx, session_id)
        ctx[:sessions].fetch(session_id).events.reverse_each
                      .find { |e| e.type == "policy/updated" }
                      &.payload&.[](:patterns)
      rescue KeyError
        nil # session unknown to this context: the floor applies
      end
    end
  end
end
