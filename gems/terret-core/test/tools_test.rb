# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret"

# The registry's execution contract, at the registry rather than through the
# loop: what a handler is handed, and what it is deliberately not.
class ToolsRegistryTest < Minitest::Test
  def boot
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([{ id: "tools", plugin: Terret::Tools::Registry }])
    [loader.boot!, loader]
  end

  def call(ctx, name, session_id: "s1", **args)
    ctx[:tools].execute(
      Terret::Tools::Call.new(id: "c1", name: name, args: args, session_id: session_id), ctx: ctx
    )
  end

  def test_a_handler_that_asks_for_the_session_is_told_which_one_it_is_running_for
    ctx, = boot
    ctx[:tools].register(name: "whoami", description: "", params: {}) do |session_id:|
      "running for #{session_id}"
    end

    assert_equal "running for agent-7", call(ctx, "whoami", session_id: "agent-7").content
  end

  # A block reports an optional keyword as :key and a required one as
  # :keyreq, and a lambda handler reports :keyreq as well. A tool that needs
  # its session must not depend on which of the three forms it was written in.
  def test_the_session_reaches_every_shape_a_handler_can_be_written_in
    ctx, = boot
    ctx[:tools].register(name: "required_kw", description: "", params: {}) { |session_id:| session_id }
    ctx[:tools].register(name: "optional_kw", description: "", params: {}) { |session_id: nil| session_id }
    ctx[:tools].register(name: "lambda_kw", description: "", params: {}, &->(session_id:) { session_id })

    %w[required_kw optional_kw lambda_kw].each do |name|
      assert_equal "agent-7", call(ctx, name, session_id: "agent-7").content, name
    end
  end

  def test_a_handler_that_does_not_ask_is_handed_its_arguments_and_nothing_else
    ctx, = boot
    ctx[:tools].register(name: "shout", description: "", params: {}) { |text:| text.upcase }
    seen = nil
    ctx[:tools].register(name: "spy", description: "", params: {}) { |**args| seen = args }

    result = call(ctx, "shout", text: "hi")
    assert_nil result.error, "an unrequested keyword would raise here: #{result.error}"
    assert_equal "HI", result.content

    call(ctx, "spy", text: "hi")
    assert_equal({ text: "hi" }, seen, "nothing is injected into a handler that did not ask")
  end

  # A model that writes session_id into its arguments is naming somebody
  # else's per-session state — another agent's shell, another agent's
  # terminals. The executing call's session is the only answer.
  def test_an_argument_cannot_impersonate_another_session
    ctx, = boot
    ctx[:tools].register(name: "whoami", description: "", params: {}) do |session_id:|
      session_id
    end

    result = ctx[:tools].execute(
      Terret::Tools::Call.new(id: "c1", name: "whoami",
                              args: { session_id: "theirs" }, session_id: "mine"), ctx: ctx
    )
    assert_equal "mine", result.content
  end

  # The session is harness-injected, so it must not appear on the wire: a
  # model that could see the keyword in a tool's parameters would learn that
  # sessions are addressable at all, and might start filling it in.
  # The floor is the autonomous safety mechanism (docs/security.md). Installing
  # the first one is ordinary; a SECOND install silently replacing it would swap
  # out the deny-by-default gate with no trace, so a replace warns. It is not
  # refused — a legitimate re-mount or reconfigure re-installs — only surfaced.
  def test_installing_a_second_floor_warns_while_the_first_is_silent
    ctx, = boot
    _out, err1 = capture_io { ctx[:tools].install_floor(ctx) { |_call| nil } }
    assert_empty err1, "the initial floor install must not warn"

    _out, err2 = capture_io { ctx[:tools].install_floor(ctx) { |_call| nil } }
    assert_match(/floor/, err2, "replacing an active floor must warn")
  end

  # A replace that is undone (the disposer restores the previous floor) leaves
  # no active floor behind, so re-installing after disposal is a first install
  # again and stays silent — which is the reconfigure path (dispose, then
  # re-install) and must not warn on every hot policy change.
  def test_reinstalling_after_disposing_the_floor_is_silent
    ctx, = boot
    disposer = ctx[:tools].install_floor(ctx) { |_call| nil }
    disposer.call
    _out, err = capture_io { ctx[:tools].install_floor(ctx) { |_call| nil } }
    assert_empty err, "installing after the previous floor was disposed must not warn"
  end

  def test_asking_for_the_session_does_not_change_what_the_model_is_shown
    ctx, = boot
    params = { type: "object", properties: { text: { type: "string" } }, required: ["text"] }
    ctx[:tools].register(name: "whoami", description: "d", params: params) do |text:, session_id:|
      "#{text} #{session_id}"
    end

    schema = ctx[:tools].schemas.fetch(0)
    assert_equal params, schema[:parameters], "the wire schema is exactly what was registered"
    refute_includes schema[:parameters][:properties].keys, :session_id
    assert_equal "hi s1", call(ctx, "whoami", text: "hi").content, "and it still arrives"
  end
end
