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
      load_failures = require_code(resolved)
      settings = Composition.materialize_settings(resolved.settings, allow_config_ruby: allow_config_ruby)
      results = resolved.rows.map { |row| check(row, settings, allow_config_ruby) }

      render(resolved, results, load_failures, out)
      results.any? { |r| !r[:disabled] && r[:status] == :error } ? 1 : 0
    end

    # Requiring the composition's code, best-effort: a require that fails does
    # not abort doctor. It surfaces as an info line for the file, and as the
    # per-row "does not resolve" error for every class that file would define —
    # which is more useful than a single aborted run.
    def self.require_code(resolved)
      (resolved.requires + resolved.plugins).filter_map do |file|
        require file
        nil
      rescue LoadError => e
        [file, e.message]
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

    # -- output ----------------------------------------------------------------

    def self.render(resolved, results, load_failures, out)
      out.puts "# doctor: profile #{resolved.profile.inspect}"
      out.puts

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
