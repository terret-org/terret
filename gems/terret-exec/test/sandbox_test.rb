# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret/exec"

class SandboxNoneTest < Minitest::Test
  def boot(extra_rows: [])
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "sandbox", plugin: Terret::Exec::SandboxNone, config: {} },
      *extra_rows
    ])
    [loader.boot!, loader]
  end

  def test_wrap_returns_the_argv_untouched
    ctx, = boot
    argv = ["echo", "hi"]
    assert_equal argv, ctx[:sandbox].wrap(argv, cwd: "/tmp")
  end

  def test_wrap_ignores_cwd_and_still_returns_the_argv_untouched
    ctx, = boot
    argv = ["ls", "-la"]
    assert_equal argv, ctx[:sandbox].wrap(argv, cwd: "/some/other/dir")
  end

  def test_isolated_is_false
    ctx, = boot
    refute ctx[:sandbox].isolated?
  end

  def test_workspace_ready_is_a_callable_no_op
    ctx, = boot
    assert_nil ctx[:sandbox].workspace_ready!
  end
end
