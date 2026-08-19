# frozen_string_literal: true

module Terret
  module Tools
    Definition = Data.define(:name, :description, :params, :handler,
                             :mutating, :approval, :concurrency) do
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

      # Returns the registration's disposer. The roster itself stays global
      # (visibility is the AllowList's job, not this method's) — but the
      # effect that puts a Definition in the roster is recorded on `ctx`,
      # which defaults to the registry's own root and so preserves every
      # existing call site. A caller that passes its forked agent ctx ties
      # OWNERSHIP to that fork: disposing the agent reaps the registration,
      # closing the M6-recorded bleed where an agent-registered tool (one
      # that can carry filesystem authority) outlived the agent that made it.
      def register(name:, description:, params: {}, mutating: false,
                   approval: :never, concurrency: :serial, ctx: @ctx, &handler)
        d = Definition.new(name: name.to_s, description:, params:, handler:,
                           mutating:, approval:, concurrency:)
        ctx.effect do
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
      #
      # One thing a handler is given beyond its arguments: a handler that
      # declares a `session_id:` keyword receives the executing call's
      # session. It is injected here and never model-supplied — it is not a
      # property of any tool's params schema, and the merge in #handler_args
      # puts the Call's own value LAST so an argument carrying that name
      # cannot name somebody else's session.
      def execute(call, ctx:)
        admitted = ctx.waterfall("tools/pre_execute", call)
        return Result.new(id: call.id, content: nil, error: admitted.reason) if admitted.is_a?(Veto)

        result = ctx.waterfall("tools/execute", admitted) do |c|
          begin
            d = fetch(c.name)
            Result.new(id: c.id, content: d.handler.call(**handler_args(d, c)), error: nil)
          rescue Failure => e
            Result.new(id: c.id, content: nil, error: e.message)
          rescue => e
            Result.new(id: c.id, content: nil, error: "#{e.class}: #{e.message}")
          end
        end
        ctx.waterfall("tools/post_execute", result)
      end

      private

      # A handler that declares a `session_id:` keyword is asking which
      # session it is running for. That is the one fact about a call that is
      # not in its args and cannot be recovered from anywhere else: a forked
      # agent scope is an anonymous Context, so a tool owning per-session
      # state — a persistent shell, a named terminal — has no other way to
      # keep one agent's state out of another's.
      #
      # Only handlers that declare it are handed it, so every registration
      # that does not care keeps its exact signature (an unknown keyword
      # would raise). And the call's own session is merged LAST: a model that
      # writes `session_id` into its arguments is trying to name somebody
      # else's shell, and here that argument simply loses.
      #
      # Both keyword shapes count. A handler written as a block reports an
      # optional keyword as `:key` and a required one as `:keyreq`, and a
      # lambda handler reports `:keyreq` too — the tool that needs its
      # session must not depend on which of the three forms it was written
      # in.
      def handler_args(definition, call)
        return call.args unless wants_session?(definition.handler)

        call.args.merge(session_id: call.session_id)
      end

      def wants_session?(handler)
        handler.parameters.any? { |kind, name| name == :session_id && %i[key keyreq].include?(kind) }
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

        # Per-install, never global: this cache is a closure local of THIS
        # install, so a forked agent scope or a hot policy swap that installs
        # its own AllowList gets its own cache. Two installs sharing one would
        # leak one agent's policy into another's — the cross-agent bleed this
        # milestone closed. Keyed by session id; the value is the patterns from
        # that session's last policy/updated, or nil for "no policy yet, fall
        # to the floor" (nil is cached too, so a never-updated session also
        # stops rescanning the log).
        cache = {}

        pre = ctx.on("tools/pre_execute") do |call, next_|
          active = active_patterns(ctx, call.session_id, cache) || floor
          if active.any? { |p| File.fnmatch(p, call.name) }
            next_.(call)
          else
            Veto.new(reason: "#{call.name} is not on the allow list")
          end
        end

        # Log-first invalidation. The cache is a read-through of the durable
        # log, never a second source of truth, so the ONLY write besides a
        # miss is a policy/updated landing in the log. session/event is emitted
        # on the context that mounts Sessions — the root of the fork chain, NOT
        # this forked ctx — and a fork-registered listener would never see it,
        # so we listen on root. Lifetime still follows the fork: wrapping
        # root.on in ctx.effect records the teardown as an effect of THIS
        # context, so disposing the agent (Loop#dispose_agent -> fork.dispose!)
        # reaps the root listener too, and it also rides the composite disposer
        # below. Fan-out is synchronous and in seq order, so update's append has
        # refreshed the entry before the next call reads it.
        root = ctx
        root = root.parent while root.parent
        inval = ctx.effect do
          root.on("session/event") do |ev|
            cache[ev.session_id] = ev.payload[:patterns] if ev.type == "policy/updated"
          end
        end

        # Composite: tear the gate and its invalidation down together. Both are
        # already recorded as effects of this context (so fork.dispose! reaps
        # them); this is the handle a caller pulls to remove its list early.
        lambda do
          pre.call
          inval.call
        end
      end

      # Hot update: durable, per-session, last one wins.
      def self.update(ctx, session_id, patterns)
        ctx[:sessions].append(session_id, "policy/updated",
                              { patterns: Array(patterns).map(&:to_s) })
      end

      # Read-through cache over the log projection. A hit returns the cached
      # patterns-or-nil without touching the log; a miss derives once and
      # stores the result. Concurrency: under the fiber scheduler a fiber
      # yields only at an await, and neither this read/write nor the
      # session/event writer awaits between touching the Hash — so same-sid
      # operations cannot interleave and distinct sids are independent; a plain
      # Hash needs no lock. An unknown session raises KeyError out of the
      # derivation before any scan and before anything is stored, so it is NOT
      # cached: the call re-derives (and re-warns) each time, and a deny-all
      # never ossifies into an allow.
      def self.active_patterns(ctx, session_id, cache)
        cache.fetch(session_id) { cache[session_id] = current_patterns(ctx, session_id) }
      rescue KeyError
        warn "terret: no policy readable for session #{session_id.inspect}; denying every tool call"
        []
      end

      # The pure log derivation the cache reads through: the patterns of the
      # last durable policy/updated in the session, or nil if it never updated.
      # Raises KeyError for a session this context cannot read (handled in
      # active_patterns), which is why the rescue lives there and not here.
      def self.current_patterns(ctx, session_id)
        ctx[:sessions].fetch(session_id).events.reverse_each
                      .find { |e| e.type == "policy/updated" }
                      &.payload&.[](:patterns)
      end
    end

    # AllowList as a config row, so a bundle can ship the deny-by-default
    # floor the way it ships everything else (docs/composition.md §6). The
    # module above is still the mechanism and still installable by hand; this
    # is only the mounting. Its registrations are already effects of the
    # mounting row, so unloading the row takes the gate with it.
    #
    # `patterns:` is the floor — the policy governing sessions that never
    # issued a policy/updated of their own. Unconfigured means an empty floor,
    # which denies every tool call.
    class AllowListFloor < Hames::Service
      service_key :allow_list
      inject :tools, :sessions

      def start(ctx)
        AllowList.install(ctx, config[:patterns] || [])
      end
    end
  end
end
