# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/terret/tools_std"
require_relative "../../terret-exec/lib/terret/exec" # the seams these tools stand on

class FilesToolsTest < Minitest::Test
  # The declared metadata for the whole roster (docs/exec.md §5). It is
  # asserted from the Definitions rather than from behaviour because approval
  # is enforced by a row this suite deliberately does not mount: what the
  # tools claim about themselves is the contract policy reads.
  ROSTER = {
    "Read" => { mutating: false, approval: :never, concurrency: :parallel },
    "Glob" => { mutating: false, approval: :never, concurrency: :parallel },
    "Grep" => { mutating: false, approval: :never, concurrency: :parallel },
    "Write" => { mutating: true, approval: :policy, concurrency: :serial },
    "Edit" => { mutating: true, approval: :policy, concurrency: :serial }
  }.freeze

  # Stands in for ctx[:subprocess] so the ripgrep branch is provable without
  # ripgrep installed: it records the argv the tool built and answers with a
  # canned rg-shaped Result (the real Result class — the stub must not be
  # allowed to invent a friendlier contract than the seam's).
  class StubSubprocess < Hames::Service
    service_key :subprocess

    def start(_ctx); end

    def calls = @calls ||= []

    def spawn(argv, cwd: Dir.pwd, env: {}, stdin: nil, timeout: nil)
      calls << { argv: argv, cwd: cwd, env: env, stdin: stdin, timeout: timeout }
      Terret::Exec::Subprocess::Result.new(status: config.fetch(:status, 0),
                                           stdout: config.fetch(:stdout, ""),
                                           stderr: config.fetch(:stderr, ""))
    end
  end

  def boot(workspace:, config: {}, extra_rows: [])
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "fs", plugin: Terret::Exec::FS, config: { workspace: workspace } },
      { id: "tools", plugin: Terret::Tools::Registry },
      { id: "std_files", plugin: Terret::ToolsStd::Files, config: config },
      *extra_rows
    ])
    [loader.boot!, loader]
  end

  # Every call goes through the pipeline, never straight at a handler: policy
  # listens on tools/pre_execute, so a tool proven only by calling its block
  # is a tool proven outside the thing that governs it.
  def call(ctx, name, **args)
    ctx[:tools].execute(
      Terret::Tools::Call.new(id: "c1", name: name, args: args, session_id: "s1"), ctx: ctx
    )
  end

  def rg_on_path?
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
       .any? { |d| p = File.join(d, "rg"); File.file?(p) && File.executable?(p) }
  end

  # Puts an executable named `rg` on PATH without installing ripgrep, so the
  # availability gate can be exercised independently of the spawn behind it.
  def with_fake_rg_on_path
    Dir.mktmpdir do |bin|
      fake = File.join(bin, "rg")
      File.write(fake, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, fake)
      original = ENV.fetch("PATH", "")
      ENV["PATH"] = "#{bin}#{File::PATH_SEPARATOR}#{original}"
      begin
        yield
      ensure
        ENV["PATH"] = original
      end
    end
  end

  # -- the roster ------------------------------------------------------------

  def test_the_roster_carries_claude_codes_exact_tool_names
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      assert_equal ROSTER.keys.sort, ctx[:tools].schemas.map { |s| s[:name] }.sort
    end
  end

  def test_every_definition_carries_the_declared_metadata
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      ROSTER.each do |name, declared|
        d = ctx[:tools].fetch(name)
        assert_equal declared[:mutating], d.mutating, "#{name} mutating"
        assert_equal declared[:approval], d.approval, "#{name} approval"
        assert_equal declared[:concurrency], d.concurrency, "#{name} concurrency"
        refute_empty d.description, "#{name} description"
      end
    end
  end

  def test_the_registrations_die_with_the_row_that_made_them
    Dir.mktmpdir do |dir|
      ctx, loader = boot(workspace: [dir])
      refute_empty ctx[:tools].schemas

      loader.unload!("std_files")
      assert_empty ctx[:tools].schemas,
                   "a tool registered by a plugin row must not outlive the row"
    end
  end

  # -- Read ------------------------------------------------------------------

  def test_read_returns_the_file_contents
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      path = File.join(dir, "note.txt")
      ctx[:fs].write(path, "hello from the workspace")

      result = call(ctx, "Read", file_path: path)
      assert_nil result.error
      assert_equal "hello from the workspace", result.content
    end
  end

  def test_read_outside_the_workspace_renders_the_denial_message_only
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |outside|
        ctx, = boot(workspace: [dir])
        target = File.join(outside, "secret.txt")
        File.write(target, "SECRET")

        result = call(ctx, "Read", file_path: target)
        assert_nil result.content
        assert_equal "#{target} is outside the granted workspace", result.error
        refute_match(/Denied/, result.error, "a Failure renders message-only, without its class")
      end
    end
  end

  # -- Write -----------------------------------------------------------------

  def test_write_creates_the_file_inside_the_workspace
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      path = File.join(dir, "nested", "new.txt")

      result = call(ctx, "Write", file_path: path, content: "fresh")
      assert_nil result.error
      assert_equal "fresh", ctx[:fs].read(path)
      assert_match(/#{Regexp.escape(File.realpath(path))}/, result.content)
    end
  end

  def test_write_outside_the_workspace_is_denied
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |outside|
        ctx, = boot(workspace: [dir])
        target = File.join(outside, "planted.txt")

        result = call(ctx, "Write", file_path: target, content: "nope")
        assert_equal "#{target} is outside the granted workspace", result.error
        refute File.exist?(target), "a denied write must never reach the filesystem"
      end
    end
  end

  # -- Edit ------------------------------------------------------------------

  def test_edit_replaces_a_unique_occurrence
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      path = File.join(dir, "f.txt")
      ctx[:fs].write(path, "the quick brown fox")

      result = call(ctx, "Edit", file_path: path, old_string: "brown", new_string: "red")
      assert_nil result.error
      assert_equal "the quick red fox", ctx[:fs].read(path)
    end
  end

  def test_edit_refuses_when_the_target_is_absent
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      path = File.join(dir, "f.txt")
      ctx[:fs].write(path, "the quick brown fox")

      result = call(ctx, "Edit", file_path: path, old_string: "purple", new_string: "red")
      assert_nil result.content
      assert_match(/appears 0 times/, result.error)
      assert_equal "the quick brown fox", ctx[:fs].read(path), "a refused edit changes nothing"
    end
  end

  def test_edit_refuses_when_the_target_is_ambiguous
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      path = File.join(dir, "f.txt")
      ctx[:fs].write(path, "brown brown fox")

      result = call(ctx, "Edit", file_path: path, old_string: "brown", new_string: "red")
      assert_nil result.content
      assert_match(/appears 2 times/, result.error)
      assert_equal "brown brown fox", ctx[:fs].read(path), "a refused edit changes nothing"
    end
  end

  # -- Glob ------------------------------------------------------------------

  def test_glob_lists_absolute_paths
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      ctx[:fs].write(File.join(dir, "a.rb"), "")
      ctx[:fs].write(File.join(dir, "lib", "b.rb"), "")
      ctx[:fs].write(File.join(dir, "c.txt"), "")

      result = call(ctx, "Glob", pattern: "**/*.rb")
      assert_nil result.error
      real = File.realpath(dir)
      assert_equal [File.join(real, "a.rb"), File.join(real, "lib", "b.rb")].sort,
                   result.content.lines.map(&:chomp).sort
    end
  end

  def test_glob_says_so_when_nothing_matches
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      result = call(ctx, "Glob", pattern: "**/*.rb")
      assert_nil result.error
      assert_equal "No files matched", result.content
    end
  end

  # -- Grep: the pure-Ruby scan ----------------------------------------------

  def test_grep_lists_absolute_paths_without_ripgrep
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir], config: { rg: false })
      ctx[:fs].write(File.join(dir, "a.rb"), "alpha\nneedle here\n")
      ctx[:fs].write(File.join(dir, "lib", "b.rb"), "no match\n")
      ctx[:fs].write(File.join(dir, "c.txt"), "needle in text\n")

      result = call(ctx, "Grep", pattern: "needle")
      assert_nil result.error
      real = File.realpath(dir)
      assert_equal ["#{File.join(real, 'a.rb')}:2:needle here",
                    "#{File.join(real, 'c.txt')}:1:needle in text"],
                   result.content.lines.map(&:chomp).sort
    end
  end

  def test_grep_honours_a_file_glob
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir], config: { rg: false })
      ctx[:fs].write(File.join(dir, "a.rb"), "needle\n")
      ctx[:fs].write(File.join(dir, "c.txt"), "needle\n")

      result = call(ctx, "Grep", pattern: "needle", glob: "**/*.rb")
      assert_equal ["#{File.join(File.realpath(dir), 'a.rb')}:1:needle"],
                   result.content.lines.map(&:chomp)
    end
  end

  def test_grep_says_so_when_nothing_matches
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir], config: { rg: false })
      ctx[:fs].write(File.join(dir, "a.rb"), "alpha\n")

      result = call(ctx, "Grep", pattern: "needle")
      assert_nil result.error
      assert_equal "No matches", result.content
    end
  end

  def test_grep_skips_files_that_are_not_valid_utf8
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir], config: { rg: false })
      ctx[:fs].write(File.join(dir, "bin.dat"), "needle\xC3\x28binary".b)
      ctx[:fs].write(File.join(dir, "a.rb"), "needle\n")

      result = call(ctx, "Grep", pattern: "needle")
      assert_nil result.error
      assert_equal ["#{File.join(File.realpath(dir), 'a.rb')}:1:needle"],
                   result.content.lines.map(&:chomp)
    end
  end

  # -- Grep: the ripgrep branch ----------------------------------------------

  def test_grep_spawns_ripgrep_through_the_subprocess_seam_when_it_is_available
    Dir.mktmpdir do |dir|
      real = File.realpath(dir)
      canned = "#{File.join(real, 'a.rb')}:2:needle here\n"
      with_fake_rg_on_path do
        ctx, = boot(workspace: [dir],
                    extra_rows: [{ id: "subprocess", plugin: StubSubprocess,
                                   config: { status: 0, stdout: canned } }])
        ctx[:fs].write(File.join(dir, "a.rb"), "alpha\nneedle here\n")

        result = call(ctx, "Grep", pattern: "needle")
        assert_nil result.error
        assert_equal ["#{File.join(real, 'a.rb')}:2:needle here"], result.content.lines.map(&:chomp)

        spawned = ctx[:subprocess].calls.fetch(0)
        assert_equal "rg", spawned[:argv].first
        assert_includes spawned[:argv], "--line-number"
        assert_includes spawned[:argv], "--no-heading"
        assert_includes spawned[:argv], "--with-filename"
        assert_includes spawned[:argv], "--no-ignore"
        assert_equal "needle", spawned[:argv][spawned[:argv].index("-e") + 1]
        assert_includes spawned[:argv], File.join(real, "a.rb")
        assert spawned[:argv].last.start_with?("/"), "ripgrep is handed absolute paths"
      end
    end
  end

  def test_grep_falls_back_to_the_ruby_scan_when_ripgrep_is_absent
    Dir.mktmpdir do |dir|
      skip "ripgrep is on PATH here; the absent-rg gate cannot be observed" if rg_on_path?

      ctx, = boot(workspace: [dir],
                  extra_rows: [{ id: "subprocess", plugin: StubSubprocess,
                                 config: { status: 0, stdout: "SHOULD NOT BE USED\n" } }])
      ctx[:fs].write(File.join(dir, "a.rb"), "needle\n")

      result = call(ctx, "Grep", pattern: "needle")
      assert_equal ["#{File.join(File.realpath(dir), 'a.rb')}:1:needle"],
                   result.content.lines.map(&:chomp)
      assert_empty ctx[:subprocess].calls, "an unavailable ripgrep must not be spawned"
    end
  end

  def test_grep_ignores_the_subprocess_seam_when_the_row_turns_ripgrep_off
    Dir.mktmpdir do |dir|
      with_fake_rg_on_path do
        ctx, = boot(workspace: [dir], config: { rg: false },
                    extra_rows: [{ id: "subprocess", plugin: StubSubprocess,
                                   config: { status: 0, stdout: "SHOULD NOT BE USED\n" } }])
        ctx[:fs].write(File.join(dir, "a.rb"), "needle\n")

        result = call(ctx, "Grep", pattern: "needle")
        assert_equal ["#{File.join(File.realpath(dir), 'a.rb')}:1:needle"],
                     result.content.lines.map(&:chomp)
        assert_empty ctx[:subprocess].calls, "config rg: false must keep the scan in-process"
      end
    end
  end

  def test_turning_ripgrep_off_hot_takes_effect_on_the_next_call
    Dir.mktmpdir do |dir|
      with_fake_rg_on_path do
        ctx, loader = boot(workspace: [dir],
                           extra_rows: [{ id: "subprocess", plugin: StubSubprocess,
                                          config: { status: 1, stdout: "" } }])
        ctx[:fs].write(File.join(dir, "a.rb"), "needle\n")
        call(ctx, "Grep", pattern: "needle")
        assert_equal 1, ctx[:subprocess].calls.length

        _, warning = capture_io { loader.reconfigure!("std_files", { rg: false }) }
        assert_empty warning, "nothing is captured at start, so there is nothing to warn about"

        result = call(ctx, "Grep", pattern: "needle")
        assert_equal ["#{File.join(File.realpath(dir), 'a.rb')}:1:needle"],
                     result.content.lines.map(&:chomp)
        assert_equal 1, ctx[:subprocess].calls.length, "the swapped row governs the very next call"
      end
    end
  end

  def test_grep_surfaces_a_ripgrep_error_rather_than_switching_engines
    Dir.mktmpdir do |dir|
      with_fake_rg_on_path do
        ctx, = boot(workspace: [dir],
                    extra_rows: [{ id: "subprocess", plugin: StubSubprocess,
                                   config: { status: 2, stderr: "regex parse error\n" } }])
        ctx[:fs].write(File.join(dir, "a.rb"), "needle\n")

        result = call(ctx, "Grep", pattern: "needle[")
        assert_nil result.content
        assert_match(/regex parse error/, result.error)
        refute_match(/Terret|Failure/, result.error, "a Failure renders message-only")
      end
    end
  end

  # The one test that needs ripgrep itself: proves the flags this tool builds
  # are the flags ripgrep actually honours, which no stub can establish.
  def test_real_ripgrep_produces_the_same_listing_as_the_ruby_scan
    skip "ripgrep is not on PATH" unless rg_on_path?

    Dir.mktmpdir do |dir|
      rows = [{ id: "sandbox", plugin: Terret::Exec::SandboxNone },
              { id: "subprocess", plugin: Terret::Exec::Subprocess }]
      ctx, = boot(workspace: [dir], extra_rows: rows)
      ctx[:fs].write(File.join(dir, "a.rb"), "alpha\nneedle here\n")
      ctx[:fs].write(File.join(dir, "lib", "b.rb"), "no match\n")

      through_rg = call(ctx, "Grep", pattern: "needle")
      assert_nil through_rg.error

      fallback, = boot(workspace: [dir], config: { rg: false })
      through_ruby = call(fallback, "Grep", pattern: "needle")

      assert_equal through_ruby.content.lines.map(&:chomp).sort,
                   through_rg.content.lines.map(&:chomp).sort
    end
  end
end
