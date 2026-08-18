# frozen_string_literal: true

module Hames
  # Runtime event contracts. Every event is declared once with its dispatch
  # mode (and optionally a durability flag and payload class). The bus refuses
  # to dispatch undeclared events or to dispatch a declared event through the
  # wrong mode. This is the Ruby replacement for Cordis's TypeScript
  # declaration-merged event typing.
  MODES = %i[emit waterfall parallel serial].freeze

  EventDecl = Data.define(:name, :mode, :durable, :payload, :doc)

  class << self
    def events = (@events ||= {})

    # Declare (or look up) an event contract.
    #
    #   Hames.event "tools/pre_execute", mode: :waterfall, payload: Tools::Call
    def event(name, mode: nil, durable: false, payload: nil, doc: nil)
      name = name.to_s
      if mode.nil?
        return events.fetch(name) do
          raise Hames::ContractError, "lookup of undeclared event #{name}"
        end
      end

      raise ArgumentError, "unknown dispatch mode #{mode.inspect}" unless MODES.include?(mode)
      if (existing = events[name]) && existing.mode != mode
        raise Hames::ContractError,
              "event #{name} already declared with mode #{existing.mode}, got #{mode}"
      end

      events[name] = EventDecl.new(name:, mode:, durable:, payload:, doc:)
    end

    def declared?(name) = events.key?(name.to_s)

    def assert_mode!(name, mode)
      decl = events[name.to_s]
      raise Hames::ContractError, "dispatch of undeclared event #{name}" unless decl
      return if decl.mode == mode

      raise Hames::ContractError,
            "event #{name} is #{decl.mode}, dispatched as #{mode}"
    end

    # Generated documentation source: [ [name, mode, durable, doc], ... ]
    def catalog
      events.values.sort_by(&:name).map { |d| [d.name, d.mode, d.durable, d.doc] }
    end

    def reset_events! = events.clear # test hook
  end

  class ContractError < StandardError; end
  class CycleError < StandardError; end
  class ServiceMissingError < StandardError; end
end
