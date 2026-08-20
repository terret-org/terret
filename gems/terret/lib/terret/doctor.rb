# frozen_string_literal: true

require_relative "composition"

module Terret
  # `trt doctor` resolves a profile and validates every row's config against its
  # plugin's Hames::Schema, without booting anything (docs/composition.md §9).
  #
  # It requires the composition's code and materializes each row (so !env,
  # !setting and !ruby resolve to concrete values), then maps each row's plugin
  # to its class and checks the materialized config against the class's schema.
  # Nothing is mounted: doctor reports on a composition it never boots.
  #
  # Two semantics keep the exit status trustworthy, and both err the same way:
  # a service with no schema is reported `unschema'd`, not failed, and an extra
  # key WARNS rather than fails. Environment probes — does OPENROUTER_API_KEY
  # resolve — print as informational lines and never as failures: doctor
  # validates config, not the world. Exit status is 1 only when an enabled row's
  # config is actually wrong.
  module Doctor
    # Returns a process exit status: 1 when an enabled row's config is wrong,
    # 0 otherwise.
    def self.run(resolved, allow_config_ruby: false, out:)
      load_failures = require_code(resolved, allow_config_ruby)
      # Settings resolve once, but a bad !setting/!ruby in settings: must not
      # abort the whole run and hide the row table. It becomes its own error
      # line; rows then materialize against empty settings, so any !setting in a
      # row surfaces as that row's own error rather than a swallowed one.
      settings, settings_error = begin
        [Composition.materialize_settings(resolved.settings, allow_config_ruby: allow_config_ruby), nil]
      rescue Composition::Error => e
        [{}, e.message]
      end
      results = resolved.rows.map { |row| check(row, settings, allow_config_ruby) }

      render(resolved, results, load_failures, settings_error, out)
      bad = settings_error || results.any? { |r| !r[:disabled] && r[:status] == :error }
      bad ? 1 : 0
    end

    # Requiring the composition's code, best-effort: a require that fails does
    # not abort doctor. It surfaces as an info line for the file, and as the
    # per-row "does not resolve" error for every class that file would define —
    # which is more useful than a single aborted run.
    #
    # doctor is the SAFE preview — "validates config, not the world" — so a
    # path-shaped require in a profile's plugins: (portable config from anywhere)
    # is NOT executed to do that job: it surfaces as a load failure the same way
    # a missing feature does, keeping `trt doctor <untrusted profile>` from being
    # arbitrary code execution. A bundle's requires: ship inside an installed gem
    # and are trusted (they may name a path to their own lib);
    # --allow-config-ruby is the operator's consent to load a profile path too,
    # exactly as at boot.
    def self.require_code(resolved, allow_config_ruby)
      refused, permitted = resolved.plugins.partition do |file|
        !allow_config_ruby && !Composition.load_path_feature?(file)
      end
      failures = (resolved.requires + permitted).filter_map do |file|
        require file
        nil
      rescue LoadError => e
        [file, e.message]
      end
      failures + refused.map do |file|
        [file, "refused: a filesystem path, not a load-path feature name; doctor does " \
               "not execute untrusted requires — pass --allow-config-ruby to load it"]
      end
    end

    # One row's verdict. The row id names the row in the table's first column,
    # so validate is called WITHOUT a subject — the schema can name the row (its
    # unit tests prove it), but here the column already does, and the doc's
    # `error: sink must be a String` reads better without the id repeated.
    def self.check(row, settings, allow_config_ruby)
      base = { id: row.id, plugin: row.plugin, disabled: row.disabled }
      config = Composition.materialize(row.config, settings: settings, allow_config_ruby: allow_config_ruby,
                                                   where: "row #{row.id.inspect}")
      klass = constantize(row.plugin)
      return base.merge(status: :error, detail: "#{row.plugin} does not resolve to a plugin class") unless klass
      unless plugin_class?(klass)
        # A name that resolves to a live constant that is not a plugin (String, a
        # module, a typo hitting something real) is not "a plugin with no schema"
        # — it is a wrong plugin:, and reporting it unschema'd would hide that.
        return base.merge(status: :error, detail: "#{row.plugin} is not a plugin " \
                                                   "(its instances do not respond to #apply)")
      end

      schema = klass.respond_to?(:config_schema) ? klass.config_schema : nil
      return base.merge(status: :unschema, detail: nil) unless schema

      # redact: a value here is a materialized !env/!setting/!ruby result and
      # may be a secret; the detail names its type only, never its content.
      result = schema.validate(config, redact: true)
      status = if result.errors.any? then :error
               elsif result.warnings.any? then :warn
               else :ok
               end
      base.merge(status: status, detail: (result.errors + result.warnings).join("; "))
    rescue Composition::Error => e
      # A row whose !setting or !ruby cannot resolve is a config fault doctor
      # owns, reported against the row rather than crashing every other row.
      base.merge(status: :error, detail: e.message)
    end

    def self.constantize(name)
      Object.const_get(name)
    rescue NameError
      nil
    end

    # The plugin contract boot itself enforces (boot.rb): a class whose instances
    # respond to #apply. Using the same test keeps doctor from red-flagging a
    # composition boot would accept — including a third-party functional plugin
    # that is not a Hames::Service.
    def self.plugin_class?(klass)
      klass.is_a?(Class) && klass.method_defined?(:apply)
    end

    # -- output ----------------------------------------------------------------

    def self.render(resolved, results, load_failures, settings_error, out)
      out.puts "# doctor: profile #{resolved.profile.inspect}"
      out.puts
      if settings_error
        out.puts "error  #{settings_error}"
        out.puts
      end

      row_w = [results.map { |r| r[:id].length }.max || 3, 3].max
      plugin_w = [results.map { |r| r[:plugin].length }.max || 6, 6].max
      out.puts "#{'row'.ljust(row_w)}  #{'plugin'.ljust(plugin_w)}  status"
      results.each do |r|
        out.puts "#{r[:id].ljust(row_w)}  #{r[:plugin].ljust(plugin_w)}  #{status_text(r)}"
      end

      info = info_lines(resolved, load_failures)
      return if info.empty?

      out.puts
      info.each { |line| out.puts "info  #{line}" }
    end

    def self.status_text(result)
      text = case result[:status]
             when :ok then "ok"
             when :unschema then "unschema'd"
             when :warn then "warn: #{result[:detail]}"
             when :error then "error: #{result[:detail]}"
             end
      result[:disabled] ? "#{text}  (disabled)" : text
    end

    # Informational, never a verdict: which !env markers this composition reads
    # and whether each resolves, plus any code that would not load. The resolved
    # value of a marker never appears — a doctor that printed a secret would be
    # one nobody could run in front of other people.
    def self.info_lines(resolved, load_failures)
      lines = env_markers(resolved.rows).map { |name| "#{name}: #{ENV.key?(name) ? 'set' : 'unset'}" }
      load_failures.each { |file, message| lines << "could not require #{file.inspect}: #{message}" }
      lines
    end

    def self.env_markers(rows)
      names = []
      rows.each { |row| collect_env(row.config, names) }
      names.uniq
    end

    def self.collect_env(value, names)
      case value
      when Composition::Tagged then names << value.argument if value.tag == "env"
      when Hash then value.each_value { |v| collect_env(v, names) }
      when Array then value.each { |v| collect_env(v, names) }
      end
    end
  end
end
