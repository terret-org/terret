# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/terret/exec"

class FSTest < Minitest::Test
  def boot(workspace:, extra_rows: [])
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "fs", plugin: Terret::Exec::FS, config: { workspace: workspace } },
      *extra_rows
    ])
    [loader.boot!, loader]
  end

  # -- read/write round-trip -----------------------------------------------

  def test_write_then_read_round_trips_inside_the_workspace
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      path = File.join(dir, "note.txt")
      ctx[:fs].write(path, "hello")
      assert_equal "hello", ctx[:fs].read(path)
    end
  end

  def test_write_creates_intermediate_directories
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      path = File.join(dir, "a", "b", "c.txt")
      ctx[:fs].write(path, "deep")
      assert_equal "deep", ctx[:fs].read(path)
    end
  end

  # -- edit -------------------------------------------------------------

  def test_edit_replaces_a_unique_string
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      path = File.join(dir, "f.txt")
      ctx[:fs].write(path, "the quick brown fox")
      ctx[:fs].edit(path, "brown", "red")
      assert_equal "the quick red fox", ctx[:fs].read(path)
    end
  end

  def test_edit_raises_when_the_target_appears_zero_times
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      path = File.join(dir, "f.txt")
      ctx[:fs].write(path, "the quick brown fox")
      err = assert_raises(Terret::Exec::EditAmbiguous) { ctx[:fs].edit(path, "purple", "red") }
      assert_match(/appears 0 times/, err.message)
    end
  end

  def test_edit_raises_when_the_target_appears_more_than_once
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      path = File.join(dir, "f.txt")
      ctx[:fs].write(path, "brown brown fox")
      err = assert_raises(Terret::Exec::EditAmbiguous) { ctx[:fs].edit(path, "brown", "red") }
      assert_match(/appears 2 times/, err.message)
    end
  end

  def test_edit_treats_the_target_as_a_literal_string_not_a_regexp
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      path = File.join(dir, "f.txt")
      # a literal "a.b" must not match "aXb" the way /a.b/ would
      ctx[:fs].write(path, "a.b and aXb")
      ctx[:fs].edit(path, "a.b", "Z")
      assert_equal "Z and aXb", ctx[:fs].read(path)
    end
  end

  # -- stat -----------------------------------------------------------------

  def test_stat_returns_primitive_metadata
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      path = File.join(dir, "f.txt")
      ctx[:fs].write(path, "12345")
      info = ctx[:fs].stat(path)
      assert_equal 5, info[:size]
      assert_kind_of String, info[:mtime]
      refute info[:directory]

      dir_info = ctx[:fs].stat(dir)
      assert dir_info[:directory]
    end
  end

  # -- glob -------------------------------------------------------------

  def test_glob_finds_matches_inside_the_workspace
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      ctx[:fs].write(File.join(dir, "a.rb"), "")
      ctx[:fs].write(File.join(dir, "b.rb"), "")
      ctx[:fs].write(File.join(dir, "c.txt"), "")
      matches = ctx[:fs].glob("*.rb")
      real_dir = File.realpath(dir)
      assert_equal ["a.rb", "b.rb"].map { |f| File.join(real_dir, f) }.sort, matches.sort
    end
  end

  def test_glob_never_escapes_via_a_symlinked_entry
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |outside|
        ctx, = boot(workspace: [dir])
        secret = File.join(outside, "secret.rb")
        File.write(secret, "top secret")
        File.symlink(secret, File.join(dir, "link.rb"))

        matches = ctx[:fs].glob("*.rb")
        refute matches.any? { |m| m.include?(outside) }, "a symlinked entry must never surface an outside path"
      end
    end
  end

  # -- containment: absolute path outside the workspace ----------------------

  def test_an_absolute_path_outside_the_workspace_is_denied
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |outside|
        ctx, = boot(workspace: [dir])
        target = File.join(outside, "f.txt")
        File.write(target, "nope")
        assert_raises(Terret::Exec::Denied) { ctx[:fs].read(target) }
      end
    end
  end

  # -- containment: `../` traversal -----------------------------------------

  def test_dotdot_traversal_out_of_the_workspace_is_denied
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      traversal = File.join(dir, "..", File.basename(dir) + "-not-real", "etc", "passwd")
      # regardless of whether the tail exists, this must resolve outside `dir`
      assert_raises(Terret::Exec::Denied) { ctx[:fs].read(traversal) }
    end
  end

  def test_dotdot_traversal_to_a_real_outside_file_is_denied
    Dir.mktmpdir do |parent|
      dir = File.join(parent, "ws")
      Dir.mkdir(dir)
      outside_file = File.join(parent, "secret.txt")
      File.write(outside_file, "shh")
      ctx, = boot(workspace: [dir])

      traversal = File.join(dir, "..", "secret.txt")
      assert_raises(Terret::Exec::Denied) { ctx[:fs].read(traversal) }
    end
  end

  # -- containment: symlink inside the workspace pointing outside -----------

  def test_a_symlink_inside_the_workspace_pointing_outside_is_denied
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |outside|
        ctx, = boot(workspace: [dir])
        secret = File.join(outside, "secret.txt")
        File.write(secret, "shh")
        link = File.join(dir, "escape")
        File.symlink(outside, link)

        assert_raises(Terret::Exec::Denied) { ctx[:fs].read(File.join(link, "secret.txt")) }
      end
    end
  end

  # -- containment: sibling directory sharing the prefix --------------------

  def test_a_sibling_directory_sharing_the_prefix_is_denied
    Dir.mktmpdir do |parent|
      ws = File.join(parent, "ws")
      evil = File.join(parent, "ws-evil")
      Dir.mkdir(ws)
      Dir.mkdir(evil)
      File.write(File.join(evil, "f.txt"), "nope")
      ctx, = boot(workspace: [ws])

      assert_raises(Terret::Exec::Denied) { ctx[:fs].read(File.join(evil, "f.txt")) }
    end
  end

  # -- containment: not-yet-existing path deep in the workspace -------------

  def test_a_not_yet_existing_path_deep_in_the_workspace_is_allowed_for_write
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      deep = File.join(dir, "new", "nested", "dirs", "file.txt")
      refute File.exist?(File.dirname(deep))

      ctx[:fs].write(deep, "brand new")
      assert_equal "brand new", ctx[:fs].read(deep)
    end
  end

  # -- containment: multi-root ----------------------------------------------

  def test_a_path_in_a_second_granted_workspace_dir_is_allowed
    Dir.mktmpdir do |dir_a|
      Dir.mktmpdir do |dir_b|
        ctx, = boot(workspace: [dir_a, dir_b])
        path_a = File.join(dir_a, "a.txt")
        path_b = File.join(dir_b, "b.txt")
        ctx[:fs].write(path_a, "A")
        ctx[:fs].write(path_b, "B")
        assert_equal "A", ctx[:fs].read(path_a)
        assert_equal "B", ctx[:fs].read(path_b)
      end
    end
  end

  def test_glob_covers_every_granted_root
    Dir.mktmpdir do |dir_a|
      Dir.mktmpdir do |dir_b|
        ctx, = boot(workspace: [dir_a, dir_b])
        ctx[:fs].write(File.join(dir_a, "a.rb"), "")
        ctx[:fs].write(File.join(dir_b, "b.rb"), "")
        matches = ctx[:fs].glob("*.rb")
        assert_equal [File.join(File.realpath(dir_a), "a.rb"), File.join(File.realpath(dir_b), "b.rb")].sort,
                     matches.sort
      end
    end
  end

  # -- containment: empty workspace list denies everything -------------------

  def test_an_empty_workspace_list_denies_everything
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [])
      target = File.join(dir, "f.txt")
      File.write(target, "hi")
      assert_raises(Terret::Exec::Denied) { ctx[:fs].read(target) }
    end
  end

  def test_a_missing_workspace_config_key_denies_everything
    Dir.mktmpdir do |dir|
      Hames.reset_events!
      Terret.declare_events!
      loader = Hames::Loader.new
      loader.layer([{ id: "fs", plugin: Terret::Exec::FS, config: {} }])
      ctx = loader.boot!
      target = File.join(dir, "f.txt")
      File.write(target, "hi")
      assert_raises(Terret::Exec::Denied) { ctx[:fs].read(target) }
    end
  end

  # -- fs/authorize waterfall veto -------------------------------------------

  def test_an_fs_authorize_veto_denies_the_operation_with_its_reason
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      path = File.join(dir, "f.txt")
      ctx[:fs].write(path, "hi")

      ctx.with_owner("watcher") do
        ctx.on("fs/authorize") do |call, _next|
          Terret::Tools::Veto.new(reason: "reads are off today") if call[:op] == :read
        end
      end

      err = assert_raises(Terret::Exec::Denied) { ctx[:fs].read(path) }
      assert_equal "reads are off today", err.message

      # writes are untouched by the listener, and still work
      ctx[:fs].write(path, "still fine")
    end
  end

  def test_an_fs_authorize_listener_sees_the_op_and_the_resolved_path
    Dir.mktmpdir do |dir|
      ctx, = boot(workspace: [dir])
      path = File.join(dir, "f.txt")
      ctx[:fs].write(path, "hi")

      seen = nil
      ctx.with_owner("watcher") do
        ctx.on("fs/authorize") do |call, next_|
          seen = call
          next_.(call)
        end
      end

      ctx[:fs].read(path)
      assert_equal :read, seen[:op]
      assert_equal File.realpath(path), seen[:path]
    end
  end
end
