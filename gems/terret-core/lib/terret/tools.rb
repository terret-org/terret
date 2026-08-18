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

      def register(name:, description:, params: {}, mutating: false,
                   approval: :never, &handler)
        d = Definition.new(name: name.to_s, description:, params:, handler:,
                           mutating:, approval:)
        @ctx.effect do
          @defs[d.name] = d
          -> { @defs.delete(d.name) }
        end
        d
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
          d = fetch(c.name)
          begin
            Result.new(id: c.id, content: d.handler.call(**c.args), error: nil)
          rescue => e
            Result.new(id: c.id, content: nil, error: "#{e.class}: #{e.message}")
          end
        end
        ctx.waterfall("tools/post_execute", result)
      end
    end

    Veto = Data.define(:reason)

    # Deny-by-default allow list (plan §6.3): a tools/pre_execute listener,
    # not a registry special case, so a per-agent list rides the agent's
    # forked context (Registry#execute dispatches on the caller's ctx).
    # Patterns are File.fnmatch globs, e.g. "mcp__nexus__*". Returns the
    # listener's disposer.
    # Note fnmatch defaults: matching is case-sensitive, and a bare "*" does
    # not match names starting with "." (no FNM_DOTMATCH) — both fail closed.
    module AllowList
      def self.install(ctx, patterns)
        patterns = Array(patterns).map(&:to_s)
        ctx.on("tools/pre_execute") do |call, next_|
          if patterns.any? { |p| File.fnmatch(p, call.name) }
            next_.(call)
          else
            Veto.new(reason: "#{call.name} is not on the allow list")
          end
        end
      end
    end
  end
end
