# frozen_string_literal: true

module Terret
  module ToolsStd
    # The standard file roster (docs/exec.md §5), carrying Claude Code's tool
    # names verbatim because orchestrator allow lists are already written
    # against those exact strings and `File.fnmatch` patterns have hardened
    # around them — a Terret-native name would buy nothing but a permanent
    # translation layer.
    #
    # Every handler reaches the filesystem through ctx[:fs] and nothing else.
    # That is what makes the roster portable across the sandbox seam: when a
    # config row swaps the sandbox provider (plan §12), these tools move with
    # it untouched, because they never learned where the bytes actually live.
    class Files < Hames::Service
      service_key :tools_std_files
      inject :tools, :fs
      config_schema rg: { type: [TrueClass, FalseClass], default: true,
                          doc: "use ripgrep for Grep when it and a subprocess seam are available" }

      DEFAULT_GLOB = "**/*"

      # A grep that never returns is a turn that never ends.
      RG_TIMEOUT = 30

      # ripgrep takes its search paths as argv, and a large workspace can
      # exceed the kernel's argv limit. Past this budget the scan stays
      # in-process rather than risking Errno::E2BIG.
      MAX_RG_ARGV_BYTES = 100_000

      def start(ctx)
        @ctx = ctx
        register_read
        register_write
        register_edit
        register_glob
        register_grep
      end

      # start captures nothing from config: `rg` is read at call time, so a
      # swapped row governs the very next Grep and there is nothing here to
      # re-derive. Saying so explicitly beats letting the base class warn that
      # this service needs a remount when it does not.
      def reconfigure(_config); end

      private

      # `ctx:` is passed explicitly on every registration. The registry
      # defaults it to the context IT was started in, which is the root — so a
      # roster mounted into a forked agent scope would leave its registration
      # frames on the root context, outliving the fork that made them. Handing
      # register the ctx this service was started in puts each frame where
      # this row's lifetime is: unload the row, or dispose the fork it was
      # mounted into, and the tools go with it. That is what stands between a
      # disposed agent and a tool of its own that still holds filesystem
      # authority.
      def tool(name, description, params, mutating:, approval:, concurrency:, &handler)
        @ctx[:tools].register(name: name, description: description, params: params,
                              mutating: mutating, approval: approval,
                              concurrency: concurrency, ctx: @ctx, &handler)
      end

      def object_schema(properties, required)
        { type: "object", properties: properties, required: required }
      end

      def path_property(purpose)
        { type: "string", description: "Absolute path to #{purpose}, inside the granted workspace" }
      end

      def register_read
        tool("Read", "Read a file's full contents.",
             object_schema({ file_path: path_property("the file to read") }, ["file_path"]),
             mutating: false, approval: :never, concurrency: :parallel) do |file_path:|
          @ctx[:fs].read(file_path)
        end
      end

      def register_write
        params = object_schema(
          { file_path: path_property("the file to write"),
            content: { type: "string", description: "The file's full new contents" } },
          %w[file_path content]
        )
        tool("Write", "Write a file, replacing it if it exists and creating parent directories as needed.",
             params, mutating: true, approval: :policy, concurrency: :serial) do |file_path:, content:|
          "Wrote #{content.to_s.bytesize} bytes to #{@ctx[:fs].write(file_path, content)}"
        end
      end

      def register_edit
        params = object_schema(
          { file_path: path_property("the file to edit"),
            old_string: { type: "string", description: "Exact text to replace; must appear exactly once" },
            new_string: { type: "string", description: "Text to put in its place" } },
          %w[file_path old_string new_string]
        )
        description = "Replace one exact occurrence of a string in a file. Refuses if it appears " \
                      "zero times or more than once, so include enough surrounding text to make it unique."
        tool("Edit", description, params,
             mutating: true, approval: :policy, concurrency: :serial) do |file_path:, old_string:, new_string:|
          "Edited #{@ctx[:fs].edit(file_path, old_string, new_string)}"
        end
      end

      def register_glob
        params = object_schema(
          { pattern: { type: "string", description: "Glob pattern, e.g. **/*.rb, matched in every workspace root" } },
          ["pattern"]
        )
        tool("Glob", "List workspace files matching a glob pattern, as absolute paths.",
             params, mutating: false, approval: :never, concurrency: :parallel) do |pattern:|
          listing(@ctx[:fs].glob(pattern), "No files matched")
        end
      end

      def register_grep
        params = object_schema(
          { pattern: { type: "string", description: "Regular expression to search for" },
            glob: { type: "string", description: "Glob limiting which files are searched (default #{DEFAULT_GLOB})" } },
          ["pattern"]
        )
        tool("Grep", "Search workspace file contents for a regular expression. Returns matching lines as " \
                     "absolute_path:line_number:line.",
             params, mutating: false, approval: :never, concurrency: :parallel) do |pattern:, glob: DEFAULT_GLOB|
          grep(pattern, glob)
        end
      end

      def listing(paths, empty_message) = paths.empty? ? empty_message : paths.join("\n")

      def grep(pattern, glob)
        files = searchable(glob)
        return "No matches" if files.empty?

        lines = (ripgrep(pattern, files) if use_rg?(files)) || scan(pattern, files)
        listing(lines, "No matches")
      end

      # Directories are dropped through the same seam that produced the
      # listing rather than with a bare File.directory?: every path this tool
      # touches passes ctx[:fs], so containment and the fs/authorize
      # waterfall see all of it and not just the reads.
      def searchable(glob)
        @ctx[:fs].glob(glob).reject { |p| @ctx[:fs].stat(p)[:directory] }
      end

      def use_rg?(files)
        config.fetch(:rg, true) && @ctx.service?(:subprocess) &&
          files.sum { |f| f.bytesize + 1 } <= MAX_RG_ARGV_BYTES && rg_on_path?
      end

      # PATH is this process's own environment, not workspace content, so it
      # is read directly — routing it through ctx[:fs] would (correctly) deny
      # every directory on it.
      def rg_on_path?
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
          exe = File.join(dir, "rg")
          File.file?(exe) && File.executable?(exe)
        end
      end

      # ripgrep is a fast path, never a different answer: it is handed exactly
      # the file list the in-process scan would have walked, so the two paths
      # agree on which files are searched and differ only in regex dialect.
      # It runs through ctx[:subprocess] like every other spawn in Terret,
      # which is what keeps it inside the sandbox once one is mounted.
      #
      # Returns nil when ripgrep proved unusable and the caller should scan
      # in-process instead. There are two ways that happens, because
      # rg_on_path? only ever probed THIS process's PATH and the spawn's own
      # verdict outranks it: a local spawn that cannot find the binary raises
      # Errno::ENOENT, while a sandbox running the argv somewhere else answers
      # with a status and never raises — `docker exec` exits 127 for a command
      # missing from the container, 126 for one that is there but not
      # executable. A host with ripgrep and an image without it is the ordinary
      # case, not an exotic one, so neither may fail the call.
      def ripgrep(pattern, files)
        # --no-ignore because which files get searched is ctx[:fs]'s decision,
        # already made: the list below IS the answer, and a .gitignore in the
        # workspace must not quietly shrink it out from under the in-process
        # scan that knows nothing about ignore files.
        argv = ["rg", "--line-number", "--no-heading", "--with-filename",
                "--no-ignore", "--color", "never", "-e", pattern, *files]
        # cwd is a workspace directory (files is non-empty here) so the
        # sandboxed world always has one it can actually enter.
        result = @ctx[:subprocess].spawn(argv, cwd: File.dirname(files.first), timeout: RG_TIMEOUT)
        case result.status
        when 0 then result.stdout.lines.map(&:chomp)
        when 1 then [] # ripgrep's "no matches" — an answer, not a failure
        when 126, 127 then nil # no usable rg where the argv actually ran
        else
          # A bad pattern is the caller's problem. Silently retrying it under
          # Ruby's regex dialect would hide that the two engines disagree.
          raise Terret::Tools::Failure, "ripgrep failed: #{failure_detail(result)}"
        end
      rescue Errno::ENOENT
        nil # the local-spawn miss; the status branch above is the sandbox's
      end

      def failure_detail(result)
        detail = result.stderr.to_s.strip
        detail = result.stdout.to_s.strip if detail.empty?
        detail.empty? ? "exit status #{result.status.inspect}" : detail
      end

      def scan(pattern, files)
        rx = compile(pattern)
        files.flat_map do |path|
          body = @ctx[:fs].read(path)
          # Matching a Regexp against invalid UTF-8 raises, and a binary file
          # is not a grep target anyway; ripgrep skips them too, so skipping
          # here keeps the two paths agreeing on the same set of files.
          next [] unless body.valid_encoding?

          body.each_line.with_index(1).filter_map do |line, n|
            "#{path}:#{n}:#{line.chomp}" if rx.match?(line)
          end
        end
      end

      def compile(pattern)
        Regexp.new(pattern)
      rescue RegexpError => e
        raise Terret::Tools::Failure, "bad search pattern: #{e.message}"
      end
    end
  end
end
