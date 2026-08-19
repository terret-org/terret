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

  def boot(script:, config: { patterns: ["sk-[a-z0-9]+"] }, redactor: true, loop_config: {},
           extra_rows: [])
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
      *(redactor ? [{ id: "redactor", plugin: Terret::Redactor, config: config }] : []),
      *extra_rows
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

  # The approvals gate matches a recorded verdict on CONTENT, not just on a
  # call id — and one side of that comparison comes out of the log, which is
  # now scrubbed. Compare a live secret argument against its redacted stored
  # form and nothing ever matches: an approved call asks a second time.
  def test_a_recorded_verdict_still_matches_a_call_whose_args_were_redacted
    ctx, = boot(script: [], extra_rows: [{ id: "approvals", plugin: Terret::Tools::Approvals }])
    ctx.with_owner("deploy-plugin") do
      ctx[:tools].register(name: "deploy", description: "", params: {}, mutating: true,
                           approval: :always) { |key:| "deployed with #{key}" }
    end
    session = ctx[:sessions].create
    sid = session.id
    agent = ctx[:loop].spawn_agent(session_id: sid)
    args = { key: SECRET }
    ctx[:sessions].append(sid, "turn/start", { agent: agent.id })
    ctx[:sessions].append(sid, "approval/requested", { call_id: "tc1", name: "deploy", args: args })
    ctx[:sessions].append(sid, "approval/resolved", { call_id: "tc1", verdict: "approved" })

    call = Terret::Tools::Call.new(id: "tc1", name: "deploy", args: args, session_id: sid)
    t = Thread.new { ctx[:tools].execute(call, ctx: agent.ctx) }
    assert t.join(2), "the gate re-parked: a recorded verdict no longer matches its stored args"
    assert_equal "deployed with [REDACTED]", t.value.content
  end

  # Two paths into the log that no tool result passes through. Both are the
  # reason the backstop exists rather than the post_execute layer alone.

  class LeakySummarizer < Hames::Service
    service_key :summarizer
    def start(_ctx); end
    def summarize(_history) = "the user's key is #{SECRET}"
  end

  def test_a_compaction_summary_is_scrubbed_at_its_own_append
    ctx, = boot(script: [], extra_rows: [{ id: "summarizer", plugin: LeakySummarizer },
                                         { id: "compactor", plugin: Terret::Compactor }])
    session = ctx[:sessions].create
    ctx[:sessions].append(session.id, "user/message", { text: "hello" })

    ev = ctx[:compactor].compact!(session.id)
    assert_equal "the user's key is [REDACTED]", ev.payload[:summary]
  end

  def test_an_injected_steer_is_scrubbed
    ctx, = boot(script: [{ text: "ok" }])
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    agent.inject("remember #{SECRET}")
    ctx[:loop].run_turn(agent, "go")

    injected = session.events.find { |e| e.type == "context/injected" }
    assert_equal "remember [REDACTED]", injected.payload[:text]
  end

  # -- resume ---------------------------------------------------------------

  # The log a process death leaves behind: an open turn whose last assistant
  # message owes a tool call that never produced a result.
  def stage_owed_call(ctx, args, name: "shell")
    session = ctx[:sessions].create
    sid = session.id
    agent = ctx[:loop].spawn_agent(session_id: sid)
    call = Terret::LLM::ToolCall.new(id: "tc1", name: name, args: args)
    ctx[:sessions].append(sid, "turn/start", { agent: agent.id })
    ctx[:sessions].append(sid, "step/start", { n: 1 })
    ctx[:sessions].append(sid, "user/message", { text: "go" })
    ctx[:sessions].append(sid, "assistant/message", { parts: [Terret::LLM.encode_part(call)] })
    [agent, session]
  end

  def register_shell(ctx, ran)
    ctx.with_owner("shell-plugin") do
      ctx[:tools].register(name: "shell", description: "", params: {}) do |cmd:|
        ran << cmd
        "ran it"
      end
    end
  end

  # Resume decodes owed calls from the log, and the log is redacted: replaying
  # `deploy --key [REDACTED]` is a different command wearing the same name.
  def test_resume_refuses_to_replay_a_call_whose_args_the_log_redacted
    ctx, = boot(script: [{ text: "wrapped up" }])
    ran = []
    register_shell(ctx, ran)
    agent, session = stage_owed_call(ctx, { cmd: "deploy --key #{SECRET}" })

    ctx[:loop].resume_turn(agent)

    assert_empty ran, "resume re-ran the command with a substituted literal"
    result = session.events.find { |e| e.type == "tool/result" }
    assert_nil result.payload[:content]
    assert_match(/redacted/, result.payload[:error])
  end

  # A redacted NAME resolves to nothing, so the call already could not run —
  # but "no such tool" reads to a model as a broken roster rather than as the
  # log having rewritten its own record. Resume refuses any owed call the log
  # redacted, wherever the token landed, and says so.
  def test_resume_refuses_to_replay_a_call_whose_name_the_log_redacted
    ctx, = boot(script: [{ text: "wrapped up" }])
    ran = []
    ctx.with_owner("shell-plugin") do
      ctx[:tools].register(name: "run_#{SECRET}", description: "", params: {}) do
        ran << :called
        "ran it"
      end
    end
    _agent, session = stage_owed_call(ctx, { cmd: "ls -la" }, name: "run_#{SECRET}")

    ctx[:loop].resume_turn(ctx[:loop].agent_for_session(session.id))

    assert_empty ran
    error = session.events.find { |e| e.type == "tool/result" }.payload[:error]
    assert_match(/was not replayed/, error)
    refute_match(/KeyError/, error, "a redacted call must not read as a missing tool")
  end

  def test_resume_still_replays_a_call_the_log_recorded_faithfully
    ctx, = boot(script: [{ text: "wrapped up" }])
    ran = []
    register_shell(ctx, ran)
    agent, session = stage_owed_call(ctx, { cmd: "ls -la" })

    ctx[:loop].resume_turn(agent)

    assert_equal ["ls -la"], ran
    assert_equal "ran it", session.events.find { |e| e.type == "tool/result" }.payload[:content]
  end

  def approvals_row = [{ id: "approvals", plugin: Terret::Tools::Approvals }]

  def await(message, timeout: 2)
    deadline = Time.now + timeout
    until yield
      raise message if Time.now > deadline

      sleep 0.005
    end
  end

  # A tool name scrubs like any other content now, so the gate has to compare
  # names the same way it compares args: against what the log actually holds.
  def test_a_recorded_verdict_still_matches_a_call_whose_name_was_redacted
    ctx, = boot(script: [], extra_rows: approvals_row)
    ctx.with_owner("deploy-plugin") do
      ctx[:tools].register(name: SECRET, description: "", params: {}, mutating: true,
                           approval: :always) { "shipped" }
    end
    session = ctx[:sessions].create
    sid = session.id
    agent = ctx[:loop].spawn_agent(session_id: sid)
    ctx[:sessions].append(sid, "turn/start", { agent: agent.id })
    ctx[:sessions].append(sid, "approval/requested", { call_id: "tc1", name: SECRET, args: {} })
    ctx[:sessions].append(sid, "approval/resolved", { call_id: "tc1", verdict: "approved" })

    call = Terret::Tools::Call.new(id: "tc1", name: SECRET, args: {}, session_id: sid)
    t = Thread.new { ctx[:tools].execute(call, ctx: agent.ctx) }
    assert t.join(2), "the gate re-parked: a recorded verdict no longer matches its stored name"
    assert_equal "shipped", t.value.content
  end

  # Sessions refuses values the old JSON round trip coerced silently — a Time
  # a plugin synthesized into args has no stored form at all. That is a
  # comparison the gate cannot make, not a verdict, so it must park like it
  # always did rather than tearing the raise through the tools pipeline.
  def test_args_with_no_stored_form_park_instead_of_raising
    ctx, = boot(script: [], extra_rows: approvals_row)
    ctx.with_owner("deploy-plugin") do
      ctx[:tools].register(name: "deploy", description: "", params: {}, mutating: true,
                           approval: :always) { |at:| "deployed at #{at.year}" }
    end
    session = ctx[:sessions].create
    sid = session.id
    agent = ctx[:loop].spawn_agent(session_id: sid)
    ctx[:sessions].append(sid, "turn/start", { agent: agent.id })
    # a standing request, unresolved: park re-uses it instead of appending
    ctx[:sessions].append(sid, "approval/requested",
                          { call_id: "tc1", name: "deploy", args: { at: "earlier" } })

    call = Terret::Tools::Call.new(id: "tc1", name: "deploy", args: { at: Time.now },
                                   session_id: sid)
    t = Thread.new { ctx[:tools].execute(call, ctx: agent.ctx) }
    await("never parked (status=#{agent.status})") { agent.status == :waiting_approval }
    ctx[:sessions].append(sid, "approval/resolved", { call_id: "tc1", verdict: "approved" })

    assert t.join(2), "the parked call never woke"
    assert_equal "deployed at #{Time.now.year}", t.value.content
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

  # The window was the whole bug. `append` was only ever handed the flushed
  # PREFIX — the held bytes were scrubbed later, in a different append — so no
  # scrubber ever saw text spanning the cut, and in steady state every emitted
  # chunk was byte-identical to one provider delta. Only a secret inside the
  # final window survived, which is all any earlier test happened to check.
  LONG_PREFIX = "lorem ipsum dolor sit amet " * 12
  LONG_SUFFIX = " and then some trailing words" * 12

  def test_a_secret_mid_stream_never_lands_in_a_chunk_however_long_the_stream
    text = "#{LONG_PREFIX}#{SECRET}#{LONG_SUFFIX}"
    assert_operator text.length, :>, 500, "the stream has to dwarf any window"
    ctx, = boot(script: [{ text: text }])
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    ctx[:loop].run_turn(agent, "go")

    # No FRAGMENT either: the filler carries none of these, so any hit is the
    # secret arriving through a delta boundary.
    stored = chunks_of(session)
    refute(stored.any? { |c| c.match?(/sk-|abc|123|def/) },
           "a chunk carried part of the secret: #{stored.grep(/sk-|abc|123|def/).inspect}")
    assert_equal "#{LONG_PREFIX}[REDACTED]#{LONG_SUFFIX}", assistant_text(session)
    assert_equal assistant_text(session), stored.join
  end

  # The anatomy the guarantee rests on: one chunk per text run while anything
  # is scrubbing (the scrubber always sees a complete run), and untouched
  # delta-for-delta streaming when nothing is.
  def test_scrubbing_coalesces_each_text_run_into_a_single_chunk
    ctx, = boot(script: [{ text: SPLIT_TEXT }])
    session = ctx[:sessions].create
    agent = ctx[:loop].spawn_agent(session_id: session.id)
    ctx[:loop].run_turn(agent, "go")

    assert_equal ["your key is [REDACTED] and it works"], chunks_of(session)
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
