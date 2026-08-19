# frozen_string_literal: true

require "optparse"
require "yaml"
require_relative "version"
require_relative "composition"
require_relative "doctor"

module Terret
  # The `trt` command line interface (docs/composition.md §8).
  #
  # Non-interactive: optparse, no thor, no REPL, no TUI. Nothing here is a chat
  # window and nothing here competes with the socket. `trt boot` starts the
  # reactor and parks, the other two print and exit, and every one of them is a
  # thin wrapper over Terret.boot or over pure resolution.
  #
  # start returns a process exit status rather than calling exit, so the tests
  # can drive it in-process with captured IO. exe/trt is the one caller that
  # turns the status into an exit.
  module CLI
    COMMANDS = %w[boot dump-config doctor].freeze

    USAGE = <<~TXT
      Usage: trt <command> [options]

      Commands:
        boot           compose a profile, mount it, and park until interrupted
        dump-config    print the resolved rows, annotated with the layer that
                       contributed each one; secrets stay unresolved
        doctor         resolve a profile and report on its rows without booting

      Options:
        -p, --profile NAME       profile to compose (required)
            --patch FILE         overlay a patch file; repeatable, applied in order
            --home DIR           Terret home (default: $TERRET_HOME, else ~/.terret)
            --allow-config-ruby  permit !ruby scalars in this composition
        -v, --version            print the terret version
        -h, --help               print this message
    TXT

    Options = Struct.new(:command, :profile, :patches, :home, :allow_config_ruby)

    def self.start(argv = ARGV, out: $stdout, err: $stderr)
      opts = parse(argv, out: out, err: err)
      return opts if opts.is_a?(Integer)

      dispatch(opts, out: out, err: err)
    rescue Composition::Error => e
      # Boot failures are caught in .boot, which is also the only command that
      # needs boot.rb — this file must not name a constant from the file that
      # requires it.
      err.puts "trt: #{e.message}"
      1
    rescue SystemCallError, IOError, ScriptError => e
      # Belt and braces. Resolution turns these into Composition::Error where
      # it meets them, but a config file is a file on somebody's disk and a
      # !ruby scalar is a compiler — neither is done surprising us, and a
      # backtrace is not an error message.
      err.puts "trt: #{e.class}: #{e.message.lines.first.to_s.strip}"
      1
    rescue Interrupt
      err.puts "trt: interrupted"
      130
    end

    def self.dispatch(opts, out:, err:)
      case opts.command
      when "boot" then boot(opts, out: out, err: err)
      when "dump-config" then dump_config(opts, out: out)
      when "doctor" then Doctor.run(resolve(opts), out: out)
      end
    end

    # -- argument parsing ------------------------------------------------------

    # Returns Options, or an exit status when the run is over (help, version,
    # usage error).
    def self.parse(argv, out:, err:)
      opts = Options.new(nil, nil, [], nil, false)
      parser = OptionParser.new do |o|
        o.banner = USAGE
        o.on("-p", "--profile NAME") { |v| opts.profile = v }
        o.on("--patch FILE") { |v| opts.patches << v }
        o.on("--home DIR") { |v| opts.home = v }
        o.on("--allow-config-ruby") { opts.allow_config_ruby = true }
        o.on("-v", "--version") { out.puts "trt #{Terret::Meta::VERSION}"; return 0 }
        o.on("-h", "--help") { out.puts USAGE; return 0 }
      end

      rest = begin
        parser.parse(argv.dup)
      rescue OptionParser::ParseError => e
        return usage_error(e.message, err: err)
      end

      opts.command = rest.shift
      return usage_error("no command given", err: err) if opts.command.nil?
      return usage_error("unknown command #{opts.command.inspect}", err: err) unless COMMANDS.include?(opts.command)
      return usage_error("unexpected arguments: #{rest.join(' ')}", err: err) unless rest.empty?
      return usage_error("#{opts.command} needs --profile NAME", err: err) if opts.profile.nil?

      opts
    end

    def self.usage_error(message, err:)
      err.puts "trt: #{message}"
      err.puts
      err.puts USAGE
      2
    end

    def self.resolve(opts)
      Composition.resolve(profile: opts.profile, home: opts.home, patches: opts.patches)
    end

    # -- boot ------------------------------------------------------------------

    def self.boot(opts, out:, err:)
      require_relative "boot" # the one command that needs it; already loaded via exe/trt
      ctx = nil
      ctx = Terret.boot(profile: opts.profile, home: opts.home, patches: opts.patches,
                        allow_config_ruby: opts.allow_config_ruby)
      out.puts "trt: profile #{opts.profile.inspect} is up. Interrupt to stop."
      out.flush
      begin
        park
      rescue Interrupt
        out.puts
      end
      out.puts "trt: stopping"
      0
    rescue StandardError => e
      err.puts "trt: boot failed: #{e.class}: #{e.message}"
      1
    ensure
      # Teardown belongs here, not on the success path: a park that raises
      # rather than catching its Interrupt used to return 1 and leak the whole
      # booted world — its container, its bash, its open database. A boot that
      # got as far as a live context is always torn down; a Terret.boot that
      # never returned leaves ctx nil and nothing to shut down.
      Boot.shutdown(ctx) if ctx
    end

    # An agent is a task tree on the fiber scheduler, so a booted process
    # belongs on the reactor even when this command has nothing of its own to
    # run. Without async there is nothing to park on but the process itself.
    def self.park
      require "async"
      Async { |task| task.sleep }
    rescue LoadError
      sleep
    end

    # -- dump-config -----------------------------------------------------------

    # The resolved tree with each row annotated by the layer that contributed
    # it. SECRETS RENDER AS THEIR UNRESOLVED TAG — `api_key: !env
    # OPENROUTER_API_KEY` prints as written and the resolved value never
    # appears here at all. This output exists to be pasted into an issue, and a
    # resolved credential printed once is a credential rotated.
    def self.dump_config(opts, out:)
      resolved = resolve(opts)
      lines = [["# resolved: profile #{resolved.profile.inspect}", nil], ["rows:", nil]]

      resolved.rows.each do |row|
        lines << ["  - id: #{row.id}", "row: #{row.row_layer}"]
        # Annotated only when a later layer swapped it, so the annotation means
        # "somebody changed this" rather than being visual noise on every row.
        swapped = row.plugin_layer unless row.plugin_layer == row.row_layer
        lines << ["    plugin: #{row.plugin}", swapped && "plugin: #{swapped}"]
        lines << ["    disabled: true", nil] if row.disabled
        if row.config.empty?
          lines << ["    config: {}", "config: #{row.config_layer}"]
        else
          lines << ["    config:", "config: #{row.config_layer}"]
          yaml_lines(row.config, 3).each { |l| lines << [l, nil] }
        end
      end

      out.puts align(lines)
      0
    end

    # Comments live in a column so the provenance reads as a column.
    def self.align(lines)
      width = lines.filter_map { |text, comment| text.length if comment }.max.to_i
      column = [width + 2, 32].max
      lines.map { |text, comment| comment ? "#{text.ljust(column)}# #{comment}" : text }
    end

    def self.yaml_lines(value, depth)
      pad = "  " * depth
      case value
      when Hash
        value.flat_map do |key, sub|
          nested?(sub) ? ["#{pad}#{key}:", *yaml_lines(sub, depth + 1)] : ["#{pad}#{key}: #{scalar(sub)}"]
        end
      when Array
        value.flat_map do |sub|
          next ["#{pad}- #{scalar(sub)}"] unless nested?(sub)

          nested = yaml_lines(sub, depth + 1)
          ["#{pad}- #{nested.first.lstrip}", *nested.drop(1)]
        end
      else [pad + scalar(value)]
      end
    end

    def self.nested?(value) = (value.is_a?(Hash) || value.is_a?(Array)) && !value.empty?

    # Psych does the quoting, so a value that would reparse as a boolean, a
    # number, or a null comes back quoted. A tag renders as itself.
    def self.scalar(value)
      return value.to_s if value.is_a?(Composition::Tagged)
      return "{}" if value == {}
      return "[]" if value == []

      body = Psych.dump(value).delete_prefix("---").sub(/\n\z/, "").strip
      body.empty? ? "~" : body
    end
  end
end
