# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret"

# The two redaction layers of docs/exec.md §6, through a real turn: the
# tools/post_execute listener that rewrites a Result before it is ever
# appended, and the Sessions scrubber that catches everything reaching the log
# by any other path.
class RedactorTest < Minitest::Test
  SECRET = "sk-abc123"

  LEAK_CALL = Terret::LLM::ToolCall.new(id: "tc1", name: "leak", args: {})

  def boot(script:, config: { patterns: ["sk-[a-z0-9]+"] })
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop",     plugin: Terret::Loop },
      { id: "redactor", plugin: Terret::Redactor, config: config }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new(script))
    [ctx, loader]
  end

  def leaking_script
    [{ text: "Reading the key.", tool_calls: [LEAK_CALL] }, { text: "Done." }]
  end

  def register(ctx, name, &handler)
    ctx.with_owner("leaky-plugin") do
      ctx[:tools].register(name: name, description: "", params: {}, &handler)
    end
  end

  def run_leaking_turn(ctx)
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    status = ctx[:loop].run_turn(agent, "my key is #{SECRET}, use it")
    [status, session]
  end

  def payload_of(session, type) = session.events.find { |e| e.type == type }.payload

  def test_a_leaked_credential_is_redacted_in_the_durable_tool_result
    ctx, = boot(script: leaking_script)
    register(ctx, "leak") { "the key is #{SECRET}" }

    status, session = run_leaking_turn(ctx)
    assert_equal :completed, status # run_turn asserts the log invariant
    assert_equal "the key is [REDACTED]", payload_of(session, "tool/result")[:content]
  end

  # The append backstop: a secret the user typed never touched a tool result.
  def test_a_credential_in_a_user_message_is_scrubbed_at_the_append_boundary
    ctx, = boot(script: leaking_script)
    register(ctx, "leak") { "the key is #{SECRET}" }

    _status, session = run_leaking_turn(ctx)
    assert_equal "my key is [REDACTED], use it", payload_of(session, "user/message")[:text]
    refute(session.events.any? { |e| e.payload.inspect.include?(SECRET) },
           "the secret survived somewhere in the log")
  end

  # The layers are distinct: post_execute rewrites the Result object itself,
  # so an in-memory consumer that never appends still sees redacted content.
  def test_post_execute_rewrites_the_result_before_anything_logs_it
    ctx, = boot(script: [])
    register(ctx, "leak") { "the key is #{SECRET}" }

    result = ctx[:tools].execute(
      Terret::Tools::Call.new(id: "c1", name: "leak", args: {}, session_id: "s1"), ctx: ctx
    )
    assert_equal "the key is [REDACTED]", result.content
  end

  def test_a_non_string_result_passes_through_untouched
    ctx, = boot(script: [])
    register(ctx, "count") { 42 }
    register(ctx, "quiet") { nil }

    %w[count quiet].each do |name|
      result = ctx[:tools].execute(
        Terret::Tools::Call.new(id: "c1", name: name, args: {}, session_id: "s1"), ctx: ctx
      )
      assert_nil result.error, name
    end
    assert_equal 42, ctx[:tools].execute(
      Terret::Tools::Call.new(id: "c1", name: "count", args: {}, session_id: "s1"), ctx: ctx
    ).content
  end

  def test_the_replacement_token_is_configurable
    ctx, = boot(script: [], config: { patterns: ["sk-[a-z0-9]+"], replacement: "<gone>" })
    register(ctx, "leak") { "the key is #{SECRET}" }

    result = ctx[:tools].execute(
      Terret::Tools::Call.new(id: "c1", name: "leak", args: {}, session_id: "s1"), ctx: ctx
    )
    assert_equal "the key is <gone>", result.content
  end

  # A replacement carrying \0 would paste the whole match back in — the one
  # way a redactor can silently un-redact. gsub's block form is what stops it.
  def test_a_replacement_token_with_a_backreference_is_inserted_literally
    ctx, = boot(script: [], config: { patterns: ["sk-[a-z0-9]+"], replacement: '[\0]' })
    register(ctx, "leak") { "the key is #{SECRET}" }

    result = ctx[:tools].execute(
      Terret::Tools::Call.new(id: "c1", name: "leak", args: {}, session_id: "s1"), ctx: ctx
    )
    assert_equal 'the key is [\0]', result.content
  end

  # A pattern that does not compile is a configuration bug, and it is loud at
  # boot rather than once per append forever after.
  def test_an_uncompilable_pattern_fails_at_boot
    err = assert_raises(RegexpError) { boot(script: [], config: { patterns: ["sk-["] }) }
    assert_match(/sk-\[/, err.message)
  end

  # Both layers install through ctx.effect under the row's ownership, so
  # unloading the row takes the listener AND the scrubber with it.
  def test_unloading_the_row_removes_both_layers
    ctx, loader = boot(script: [])
    register(ctx, "leak") { "the key is #{SECRET}" }
    call = Terret::Tools::Call.new(id: "c1", name: "leak", args: {}, session_id: "s1")
    session = ctx[:sessions].create

    assert_equal "the key is [REDACTED]", ctx[:tools].execute(call, ctx: ctx).content
    loader.unload!("redactor")
    assert_equal "the key is #{SECRET}", ctx[:tools].execute(call, ctx: ctx).content
    ev = ctx[:sessions].append(session.id, "user/message", { text: SECRET })
    assert_equal SECRET, ev.payload[:text]
  end

  def test_hot_reconfigure_recompiles_the_patterns
    ctx, loader = boot(script: [], config: { patterns: [] })
    register(ctx, "leak") { "the key is #{SECRET}" }
    call = Terret::Tools::Call.new(id: "c1", name: "leak", args: {}, session_id: "s1")

    assert_equal "the key is #{SECRET}", ctx[:tools].execute(call, ctx: ctx).content
    loader.reconfigure!("redactor", { patterns: ["sk-[a-z0-9]+"] })
    assert_equal "the key is [REDACTED]", ctx[:tools].execute(call, ctx: ctx).content
  end
end
