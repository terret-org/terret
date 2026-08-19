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

  def boot(script:, config: { patterns: ["sk-[a-z0-9]+"] }, redactor: true, loop_config: {})
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop",     plugin: Terret::Loop, config: loop_config },
      *(redactor ? [{ id: "redactor", plugin: Terret::Redactor, config: config }] : [])
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

  # -- streamed chunks ------------------------------------------------------

  # FakeAdapter slices text into 8-character deltas, which is exactly what a
  # real provider does at token boundaries: "sk-abc123def" arrives as
  # " is sk-a" + "bc123def", and a per-delta append redacts the first half
  # while storing the second verbatim. The pattern is perfect; the chunking
  # defeats it.
  SPLIT_TEXT = "your key is sk-abc123def and it works"

  def chunks_of(session)
    session.events.select { |e| e.type == "assistant/chunk" }.map { |e| e.payload[:text] }
  end

  def assistant_text(session)
    session.events.select { |e| e.type == "assistant/message" }
           .flat_map { |e| e.payload[:parts] }
           .select { |p| p[:type] == "text" }.map { |p| p[:text] }.join
  end

  def test_a_secret_split_across_deltas_never_lands_in_a_durable_chunk
    ctx, = boot(script: [{ text: SPLIT_TEXT }])
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    ctx[:loop].run_turn(agent, "go")

    stored = chunks_of(session)
    refute(stored.any? { |c| c.include?("bc123def") },
           "a delta boundary carried the tail of the secret into the log: #{stored.inspect}")
    refute(stored.any? { |c| c.include?("sk-abc") }, stored.inspect)
    assert_equal "your key is [REDACTED] and it works", assistant_text(session)
    assert_equal assistant_text(session), stored.join,
                 "re-chunked text must still reassemble to the authoritative message"
  end

  # The carry costs nothing when nothing is scrubbing: chunks are the deltas.
  def test_with_no_scrubbers_chunks_pass_through_unbuffered
    ctx, = boot(script: [{ text: SPLIT_TEXT }], redactor: false)
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    ctx[:loop].run_turn(agent, "go")

    assert_equal SPLIT_TEXT.chars.each_slice(8).map(&:join), chunks_of(session)
  end

  # Text longer than the carry window still streams: the window is what is
  # held back, not what is buffered forever.
  def test_a_long_stream_flushes_prefixes_while_holding_only_the_window
    long = ("filler " * 60) + "and sk-abc123def ends it"
    ctx, = boot(script: [{ text: long }], loop_config: { scrub_carry: 32 })
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    ctx[:loop].run_turn(agent, "go")

    stored = chunks_of(session)
    assert_operator stored.length, :>, 1, "a long stream must flush before it ends"
    refute(stored.any? { |c| c.include?("bc123def") }, stored.inspect)
    assert_equal assistant_text(session), stored.join
  end

  # Re-chunking is only safe because chunks are replay/UI fidelity and never
  # model history — nothing here reaches derive_messages or the digest.
  def test_chunks_are_invisible_to_the_projection
    ctx, = boot(script: [{ text: SPLIT_TEXT }])
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    ctx[:loop].run_turn(agent, "go")

    refute_empty chunks_of(session)
    assert_equal %i[user assistant], ctx[:sessions].derive_messages(session.id).map(&:role)
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
