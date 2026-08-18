# frozen_string_literal: true

module Hames
  # A Context is a repository of services and an event bus. Plugins mount into
  # a context, claim service keys, register listeners, and install reversible
  # effects. Forked contexts inherit parent services and listeners; their own
  # registrations dispose independently (the per-agent scope primitive).
  class Context
    Listener = Data.define(:name, :block, :prepend, :owner)

    attr_reader :parent

    def initialize(parent: nil)
      @parent    = parent
      @services  = {}
      @listeners = Hash.new { |h, k| h[k] = [] }
      @effects   = [] # frames: [owner, disposer] in registration order
      @owner     = nil # plugin id currently mounting (set by Loader)
    end

    # -- services -----------------------------------------------------------

    def register_service(key, instance)
      key = key.to_sym
      raise ContractError, "service #{key} already registered" if @services.key?(key)

      @services[key] = instance
      effect { -> { @services.delete(key) } }
      instance
    end

    def [](key)
      key = key.to_sym
      @services[key] || parent&.[](key) ||
        raise(ServiceMissingError, "no service registered at ctx[:#{key}]")
    end

    def service?(key) = @services.key?(key.to_sym) || parent&.service?(key) || false

    def method_missing(name, *args, &blk)
      service?(name) && args.empty? && blk.nil? ? self[name] : super
    end

    def respond_to_missing?(name, include_private = false)
      service?(name) || super
    end

    # -- effects (reversible registrations) ---------------------------------

    # Runs the block now; the block must return a disposer callable (or nil).
    # Disposal happens in reverse registration order, per owner, on unload.
    # The disposer handed back is self-removing and idempotent: calling it
    # runs the teardown once and drops its own entry from @effects, so a
    # long-lived context does not pin every disposed registration (and
    # whatever its closure captured). The done flag lives on the frame (not
    # presence in @effects) because dispose_owner! removes frames from
    # @effects BEFORE running them — a presence check would silently skip
    # the real teardown there.
    def effect(&block)
      disposer = block.call
      return disposer unless disposer

      frame = [@owner, nil, false]
      wrapped = lambda do
        next if frame[2]

        frame[2] = true
        @effects.delete(frame)
        disposer.call
      end
      frame[1] = wrapped
      @effects << frame
      wrapped
    end

    def with_owner(owner)
      prev, @owner = @owner, owner
      yield
    ensure
      @owner = prev
    end

    # Dispose everything owned by `owner` (a plugin id), reverse order.
    def dispose_owner!(owner)
      kept = []
      doomed = []
      @effects.each { |fr| (fr[0] == owner ? doomed : kept) << fr }
      @effects = kept
      doomed.reverse_each { |(_o, d)| d.call }
    end

    # Dispose the whole context (child scopes call this when they end).
    def dispose!
      @effects.dup.reverse_each { |(_o, d)| d.call }
      @effects.clear
    end

    # -- events --------------------------------------------------------------

    # Register a listener. Mode is validated against the event declaration.
    # Returns a disposer and records it as an effect of the current owner.
    def on(name, prepend: false, &block)
      name = name.to_s
      raise ContractError, "listener for undeclared event #{name}" unless Hames.declared?(name)

      l = Listener.new(name:, block:, prepend:, owner: @owner)
      bucket = @listeners[name]
      prepend ? bucket.unshift(l) : bucket.push(l)
      effect { -> { bucket.delete(l) } }
    end

    # Listeners visible to this context: parent chain first (registration
    # order preserved within each context), respecting prepend within buckets.
    def listeners_for(name)
      own = @listeners[name.to_s]
      parent ? parent.listeners_for(name) + own : own.dup
    end

    # emit: fire-and-forget, registration order, no return value.
    def emit(name, *args)
      Hames.assert_mode!(name, :emit)
      listeners_for(name).each { |l| l.block.call(*args) }
      nil
    end

    # waterfall: around-middleware. Each listener receives (*args, next_).
    # Calling next_.(payload) delegates; returning without calling next_
    # short-circuits. The innermost next_ returns its (possibly rewritten)
    # payload — or calls the base block if one is given.
    def waterfall(name, *args, &base)
      Hames.assert_mode!(name, :waterfall)
      chain = listeners_for(name)
      invoke = lambda do |i, current_args|
        if i >= chain.length
          base ? base.call(*current_args) : current_args.first
        else
          next_ = ->(*rewritten) { invoke.call(i + 1, rewritten.empty? ? current_args : rewritten) }
          chain[i].block.call(*current_args, next_)
        end
      end
      invoke.call(0, args)
    end

    # parallel: all listeners observe the event; awaited as a group. Without
    # a reactor this runs each in sequence but preserves the contract that
    # dispatch completes only when every listener has. (Under terret's async
    # runtime this maps onto an Async barrier.)
    def parallel(name, *args)
      Hames.assert_mode!(name, :parallel)
      listeners_for(name).each { |l| l.block.call(*args) }
      nil
    end

    # serial: ordered, awaited, single-decision. The first non-nil listener
    # return value wins and stops dispatch.
    def serial(name, *args)
      Hames.assert_mode!(name, :serial)
      listeners_for(name).each do |l|
        result = l.block.call(*args)
        return result unless result.nil?
      end
      nil
    end

    # -- fork ----------------------------------------------------------------

    # Child scope: sees parent services and listeners; its own registrations
    # dispose when the scope ends (or when its owner unloads).
    def fork = Context.new(parent: self)
  end
end
