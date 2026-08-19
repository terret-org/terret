# frozen_string_literal: true

module Hames
  # The kernel's own tiny config validator (docs/composition.md §9): a plain
  # description of a service's config keys — for each one a type:, whether it is
  # required:, an optional enum: of legal values, a default:, and a doc: string
  # — plus the code that checks a config hash against it and reports what does
  # not fit.
  #
  # Pure stdlib rather than dry-schema, because the kernel's zero-runtime-
  # dependency rule is a design constraint rather than a coincidence (CLAUDE.md).
  # The plan's §10 dry-schema mention is superseded by that rule.
  class Schema
    # Tells config_schema() the read from config_schema({}) the declaration:
    # with no argument it reads the stored schema, config_schema({}) declares an
    # empty one (a service that takes no config), and config_schema(key: {...})
    # declares a populated one.
    UNSET = Object.new.freeze
    private_constant :UNSET

    # One key's rules. `type` is a Class or an array of Classes (a union);
    # [TrueClass, FalseClass] is how a boolean is spelled, since Ruby has no
    # Boolean class. `default` documents what the service reads when the key is
    # missing — it fills a missing key at read time, it does NOT merge into the
    # config, because config layering is wholesale-replace (CLAUDE.md).
    KeySpec = Data.define(:name, :type, :required, :enum, :default, :doc)

    Result = Data.define(:errors, :warnings) do
      def ok? = errors.empty?
    end

    # Class-level DSL. Hames::Service extends it so every service is schema-able;
    # a functional plugin (one that only responds to apply, not a Service) can
    # `extend Hames::Schema::DSL` to be schema'd too — that is how the OpenRouter
    # plugin, which is not a Service, still carries a schema doctor can read.
    module DSL
      def config_schema(specs = UNSET)
        return stored_config_schema if specs.equal?(UNSET)

        @config_schema = Hames::Schema.build(specs)
        Hames::Schema.register(self, @config_schema)
        @config_schema
      end

      # Inherited like service_key and inject: a subclass that does not redeclare
      # validates exactly like its parent.
      def stored_config_schema
        return @config_schema if defined?(@config_schema) && @config_schema

        parent = superclass if respond_to?(:superclass)
        parent.respond_to?(:config_schema) ? parent.config_schema : nil
      end
    end

    # Every declared schema, class => schema, in declaration order. The catalog
    # generator (rake config:catalog) walks this once the code is required, the
    # way events:catalog walks Hames.catalog.
    def self.declared = (@declared ||= {})
    def self.register(klass, schema) = declared[klass] = schema
    def self.reset_declared! = declared.clear # test hook

    def self.build(specs)
      keys = (specs || {}).to_h do |name, opts|
        opts ||= {}
        key = name.to_sym
        [key, KeySpec.new(name: key, type: opts[:type], required: opts.fetch(:required, false),
                          enum: opts[:enum], default: opts[:default], doc: opts[:doc])]
      end
      new(keys)
    end

    attr_reader :keys

    def initialize(keys)
      @keys = keys
    end

    # Validates a config hash without mutating it. `subject` names the row (or
    # class) so an error reads as "sandbox: image is required but was not set" —
    # a refusal that cannot say which of thirty rows it is about is one an
    # operator cannot act on.
    #
    # A key that is absent OR present-but-nil counts as UNSET: a required unset
    # key is an error, a non-required one is fine — its default applies, and an
    # unset !env resolving to nil is an ordinary state (§5) rather than a fault.
    # A non-nil value is checked against `type` and `enum`. Extra keys WARN
    # rather than fail, because config rows grow.
    def validate(config, subject: nil)
      config ||= {}
      prefix = subject ? "#{subject}: " : ""
      errors = []

      @keys.each_value do |spec|
        value = config[spec.name]
        if value.nil?
          errors << "#{prefix}#{spec.name} is required but was not set" if spec.required
          next
        end
        if spec.type && Array(spec.type).none? { |t| value.is_a?(t) }
          errors << "#{prefix}#{spec.name} must be #{Schema.type_desc(spec.type)}, got #{Schema.describe(value)}"
        end
        if spec.enum && !spec.enum.include?(value)
          errors << "#{prefix}#{spec.name} must be one of #{spec.enum.map(&:inspect).join(', ')}, " \
                    "got #{value.inspect}"
        end
      end

      warnings = (config.keys - @keys.keys).map { |extra| "#{prefix}#{extra} is not a known config key" }
      Result.new(errors: errors, warnings: warnings)
    end

    # A boolean is the TrueClass/FalseClass union, so it reads as "a boolean"
    # rather than naming two classes nobody wrote in a config.
    def self.type_desc(type)
      types = Array(type)
      return "a boolean" if types.sort_by(&:name) == [FalseClass, TrueClass]
      return "a #{types.first}" if types.length == 1

      "one of #{types.join(', ')}"
    end

    # A scalar renders as itself ("got 5", "got nil"); anything larger renders
    # as its class, so a wrong Hash where a String was wanted does not paste a
    # whole tree into a one-line status.
    def self.describe(value)
      case value
      when String, Numeric, Symbol, true, false then value.inspect
      else value.class.to_s
      end
    end
  end
end
