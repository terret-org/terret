# frozen_string_literal: true

module Terret
  # `trt doctor` resolves a profile and validates every row's config against
  # its plugin's schema, without booting anything (docs/composition.md §9).
  #
  # SKELETON. The validating half needs two things that do not exist yet:
  # Hames::Schema, the kernel's own tiny config validator, and a config_schema
  # declaration on each service. Until those land this prints the resolved tree
  # and says plainly that it checked nothing — a doctor that invented a verdict
  # would be worse than one that admits its scope, because the entire value of
  # the command is that its exit status can be trusted in CI.
  #
  # When it is finished: rows report ok / error / unschema'd, extra keys warn
  # rather than fail, environment probes print as informational lines and never
  # as failures, and the exit status is 1 only when a row's config is wrong.
  module Doctor
    PENDING = "schema validation arrives with doctor's completion; " \
              "no config was checked"

    # Returns a process exit status. Always 0 today: nothing here can find a
    # fault, so nothing here may report one.
    def self.run(resolved, out:)
      out.puts "# doctor: profile #{resolved.profile.inspect}"
      out.puts

      width = [resolved.rows.map { |r| r.id.length }.max || 3, 3].max
      out.puts "#{'row'.ljust(width)}  plugin"
      resolved.rows.each do |row|
        note = row.disabled ? "  (disabled)" : ""
        out.puts "#{row.id.ljust(width)}  #{row.plugin}#{note}"
      end

      out.puts
      out.puts "note  #{PENDING}"
      0
    end
  end
end
