# frozen_string_literal: true

require_relative "translate"

module Terret
  module MCP
    # ctx[:mcp] — mounts MCP servers as namespaced tool sources (docs/mcp.md).
    # The client is injectable (client_factory config) so tests run on fakes;
    # the default factory builds a manceps client, lazily required so nothing
    # here needs manceps until something actually connects.
    class Service < Hames::Service
      service_key :mcp
      inject :tools, :prompt
      # client_factory: is an injectable seam (tests pass a factory), not YAML
      # config, so it is absent from the schema. servers: is an open map of
      # name => { url|command, args, env, bearer, approval, timeout }.
      config_schema strict:  { type: [TrueClass, FalseClass], default: false,
                               doc: "when true, a server that fails to mount fails the boot" },
                    servers: { type: Hash, default: {},
                               doc: "name => server config (url or command, args, env, bearer, " \
                                    "approval, timeout)" }

      DEFAULT_TIMEOUT = 30

      def start(ctx)
        @ctx = ctx
        @strict = !!config[:strict]
        @factory = config[:client_factory] || method(:default_client)
        @servers = {}
        @mounted = {} # name => { client:, disposers:, tool_names: }
        (config[:servers] || {}).each do |name, cfg|
          name = Translate.assert_server_name!(name)
          unless cfg[:url].nil? ^ cfg[:command].nil?
            raise ArgumentError, "server #{name}: exactly one of url:/command: required"
          end

          @servers[name] = cfg
        end
      end

      def stop(_ctx) = @mounted.keys.each { |n| unmount!(n) }

      def mounted = @mounted.keys

      def mount!(*names)
        names = @servers.keys if names.empty?
        names.each { |n| mount_one(n.to_s) }
      end

      # Reverses every registration the server contributed and disconnects.
      def unmount!(name)
        entry = @mounted.delete(name.to_s) or return
        entry[:listener]&.stop
        entry[:resource_disposers].reverse_each(&:call)
        entry[:disposers].reverse_each(&:call)
        begin
          entry[:client].disconnect
        rescue StandardError => e
          warn "terret-mcp: #{name}: disconnect failed: #{e.class}: #{e.message}"
        end
      end

      # Reads the resource once and registers its text as a prompt section
      # (docs/mcp.md); live refresh on resources/updated is deferred until a
      # consumer needs it. Returns the section's disposer.
      def register_resource_section(server, uri, name:, priority: 100)
        entry = @mounted.fetch(server.to_s) { raise ArgumentError, "server #{server.inspect} is not mounted" }
        body = entry[:client].read_resource(uri).text.to_s
        disposer = @ctx.with_owner("mcp:#{server}") do
          @ctx[:prompt].register_section(name, priority: priority) { body }
        end
        entry[:resource_disposers] << disposer
        disposer
      end

      private

      def mount_one(name)
        cfg = @servers[name] or
          raise ArgumentError, @strict ? "strict mode: server #{name.inspect} is not in this row's config" :
                                         "unknown server #{name.inspect}"
        return if @mounted.key?(name)

        client = @factory.call(name, cfg)
        client.connect
        entry = { client: client, disposers: [], tool_names: [],
                  lock: (cfg[:command] ? Mutex.new : nil), resource_disposers: [] }
        begin
          sync_tools(name, entry, cfg)
        rescue StandardError
          entry[:disposers].reverse_each(&:call)
          begin
            client.disconnect
          rescue StandardError => e
            warn "terret-mcp: #{name}: disconnect after failed mount: #{e.class}: #{e.message}"
          end
          raise
        end
        @mounted[name] = entry
        entry[:client].on("notifications/tools/list_changed") do |_params|
          # a straggler notification after unmount (or from a superseded
          # mount) must not resurrect tools from a dead entry
          next unless @mounted[name].equal?(entry)

          begin
            sync_tools(name, entry, cfg)
          rescue StandardError => e
            # a transient relist failure must not kill the listener or take
            # down the roster; sync_tools already left it in place (fetch
            # happens before disposal) — just retry on the next notification
            warn "terret-mcp: #{name}: reconcile failed: #{e.class}: #{e.message}"
          end
        end
        start_listener(entry)
        entry
      end

      # manceps' listen is a blocking dispatch loop; give it its own task
      # when a reactor exists. Without one there is nothing to run it on —
      # notifications are skipped (docs/mcp.md documents this).
      def start_listener(entry)
        task = defined?(Async) ? Async::Task.current? : nil
        return unless task

        entry[:listener] = task.async do
          entry[:client].listen
        rescue StandardError => e
          warn "terret-mcp: listener died: #{e.class}: #{e.message}"
        end
      end

      def sync_tools(name, entry, cfg)
        approval = cfg[:approval] || :policy
        timeout = cfg[:timeout] || DEFAULT_TIMEOUT
        # fetch before disposing anything: a relist failure (network blip,
        # server hiccup) must leave the current roster registered, not tear
        # it down and then have nothing to put back.
        tools = entry[:client].tools

        entry[:disposers].reverse_each(&:call)
        entry[:disposers].clear
        entry[:tool_names].clear

        @ctx.with_owner("mcp:#{name}") do
          tools.each do |tool|
            args = Translate.definition_args(server: name, tool: tool, approval: approval)
            remote = tool.name
            entry[:disposers] << @ctx[:tools].register(**args) do |**call_args|
              call_remote(name, entry, remote, call_args, timeout)
            end
            entry[:tool_names] << args[:name]
          end
        end
      end

      def call_remote(name, entry, remote, call_args, timeout)
        if (lock = entry[:lock])
          # stdio replies correlate by order, not id: the whole
          # heal+call sequence must serialize per server, so a waiter
          # re-checks the poison flag after the loser's timeout lands.
          lock.synchronize { locked_call(name, entry, remote, call_args, timeout) }
        else
          locked_call(name, entry, remote, call_args, timeout)
        end
      end

      def locked_call(name, entry, remote, call_args, timeout)
        if entry[:poisoned]
          # claim the heal before reconnecting (reconnect! yields): a second
          # fiber arriving mid-heal proceeds against the reconnecting client
          # and at worst gets a transport error that re-poisons. A waiting
          # latch would be race-free; that arrives with the M6 lifecycle work.
          entry[:poisoned] = false
          begin
            entry[:client].reconnect!
          rescue StandardError
            entry[:poisoned] = true
            raise Terret::Tools::Failure, "mcp #{name}: reconnect failed"
          end
        end
        result = with_timeout(timeout) { entry[:client].call_tool(remote, **call_args) }
        error = Translate.result_error(result)
        raise Terret::Tools::Failure, error if error

        Translate.result_content(result)
      rescue *timeout_errors
        entry[:poisoned] = true
        raise Terret::Tools::Failure, "mcp timeout after #{timeout}s"
      rescue *transport_errors => e
        entry[:poisoned] = true
        raise Terret::Tools::Failure, "mcp #{name}: #{e.class}: #{e.message}"
      end

      def with_timeout(seconds, &block)
        task = defined?(Async) ? Async::Task.current? : nil
        return yield unless task

        task.with_timeout(seconds) { block.call }
      end

      # Async is optional for terret-mcp; a rescue clause must not name a
      # constant the host may never load. Evaluated at exception time, so a
      # late `require "async"` still matches.
      def timeout_errors
        defined?(Async::TimeoutError) ? [Async::TimeoutError] : []
      end

      def transport_errors
        defined?(Manceps::Error) ? [Manceps::Error] : [IOError]
      end

      def default_client(name, cfg)
        require "manceps"
        if cfg[:url]
          auth = cfg[:bearer] ? Manceps::Auth::Bearer.new(cfg[:bearer]) : Manceps::Auth::None.new
          Manceps::Client.new(cfg[:url], auth: auth)
        else
          Manceps::Client.new(cfg[:command], args: cfg[:args] || [], env: cfg[:env])
        end
      end
    end
  end
end
