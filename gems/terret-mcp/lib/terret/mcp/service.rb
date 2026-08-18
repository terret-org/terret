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
        entry[:disposers].reverse_each(&:call)
        begin
          entry[:client].disconnect
        rescue StandardError => e
          warn "terret-mcp: #{name}: disconnect failed: #{e.class}: #{e.message}"
        end
      end

      private

      def mount_one(name)
        cfg = @servers[name] or
          raise ArgumentError, @strict ? "strict mode: server #{name.inspect} is not in this row's config" :
                                         "unknown server #{name.inspect}"
        return if @mounted.key?(name)

        client = @factory.call(name, cfg)
        client.connect
        entry = { client: client, disposers: [], tool_names: [] }
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
        entry
      end

      def sync_tools(name, entry, cfg)
        approval = cfg[:approval] || :policy
        timeout = cfg[:timeout] || DEFAULT_TIMEOUT
        entry[:disposers].reverse_each(&:call)
        entry[:disposers].clear
        entry[:tool_names].clear

        @ctx.with_owner("mcp:#{name}") do
          entry[:client].tools.each do |tool|
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
