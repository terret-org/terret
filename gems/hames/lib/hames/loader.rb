# frozen_string_literal: true

module Hames
  # Base class for service plugins. A plugin may instead be any object that
  # responds to apply(ctx) (the functional form), with optional #inject.
  class Service
    class << self
      # Both class-level declarations are inherited: a subclass (a test
      # double, a provider variant) mounts exactly like its parent unless it
      # redeclares. inject accumulates down the chain; service_key overrides.
      def service_key(key = nil)
        @service_key = key.to_sym if key
        return @service_key if @service_key

        superclass <= Hames::Service ? superclass.service_key : nil
      end

      def inject(*keys)
        @inject ||= []
        @inject.concat(keys.map(&:to_sym)) unless keys.empty?
        inherited = superclass <= Hames::Service ? superclass.inject : []
        inherited + @inject
      end
    end

    attr_reader :config

    def initialize(config = {})
      @config = config
    end

    def inject = self.class.inject

    def apply(ctx)
      ctx.register_service(self.class.service_key, self) if self.class.service_key
      start(ctx)
    end

    def start(ctx); end
    def stop(ctx); end
  end

  Row = Data.define(:id, :plugin, :config, :disabled) do
    def self.build(h)
      new(id: h.fetch(:id).to_s, plugin: h.fetch(:plugin),
          config: h[:config] || {}, disabled: h[:disabled] || false)
    end
  end

  # Mounts config rows into a context in dependency order derived from each
  # plugin's inject list. Layers apply as ordered row lists; a later layer's
  # row with an existing id replaces that row's config wholesale (never a
  # deep merge); unknown ids append.
  class Loader
    attr_reader :ctx, :rows

    def initialize(ctx = Context.new)
      @ctx = ctx
      @rows = {} # id => Row
      @mounted = {} # id => plugin instance
    end

    def layer(row_hashes)
      row_hashes.each do |h|
        id = h.fetch(:id).to_s
        if (existing = @rows[id])
          # patch: wholesale config replacement; plugin class may also swap
          @rows[id] = Hames::Row.new(
            id: id,
            plugin: h[:plugin] || existing.plugin,
            config: h.key?(:config) ? (h[:config] || {}) : existing.config,
            disabled: h.key?(:disabled) ? h[:disabled] : existing.disabled
          )
        else
          @rows[id] = Row.build(h)
        end
      end
      self
    end

    # Mount all enabled rows. Plugins whose injected services are not yet
    # present wait; repeated passes mount whatever has become satisfiable.
    # No progress with plugins still pending => cycle / missing provider.
    def boot!
      pending = @rows.values.reject(&:disabled).map { |r| [r, instantiate(r)] }
      until pending.empty?
        ready, pending = pending.partition { |(_r, pl)| satisfied?(pl) }
        if ready.empty?
          missing = pending.map { |(r, pl)| "#{r.id} (needs #{unmet(pl).join(', ')})" }
          raise CycleError, "cannot mount: #{missing.join('; ')}"
        end
        ready.each { |(r, pl)| mount(r, pl) }
      end
      ctx
    end

    def unload!(id)
      plugin = @mounted.delete(id) or raise ArgumentError, "no mounted plugin #{id}"
      plugin.stop(ctx) if plugin.respond_to?(:stop)
      ctx.dispose_owner!(id)
    end

    # Resolved tree, layer-agnostic view (for --dump-config).
    def dump_config
      @rows.values.map { |r| { id: r.id, plugin: r.plugin.to_s, config: r.config, disabled: r.disabled } }
    end

    private

    def instantiate(row)
      k = row.plugin
      k.is_a?(Class) ? k.new(row.config) : k
    end

    def satisfied?(plugin)
      unmet(plugin).empty?
    end

    def unmet(plugin)
      needs = plugin.respond_to?(:inject) ? Array(plugin.inject) : []
      needs.reject { |key| ctx.service?(key) }
    end

    def mount(row, plugin)
      ctx.with_owner(row.id) { plugin.apply(ctx) }
      @mounted[row.id] = plugin
    end
  end
end
