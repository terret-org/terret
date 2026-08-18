# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/terret/store/sqlite"
require_relative "../../terret-core/test/store_contract"

class SQLiteStoreTest < Minitest::Test
  include StoreContract

  def build_store
    store = Terret::Store::SQLite.new(path: File.join(Dir.mktmpdir("terret-sqlite"), "t.sqlite3"))
    store.start(nil)
    store
  end
end

# The M3 acceptance: a full tool turn written through SQLite, reopened by a
# FRESH store instance on the same file, resumes with a byte-identical
# derived-context digest and keeps appending after the last seq.
class SQLiteRestartTest < Minitest::Test
  def boot(path)
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::SQLite, config: { path: path } },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "prompt",   plugin: Terret::Prompt },
      { id: "tools",    plugin: Terret::Tools::Registry },
      { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
      { id: "loop",     plugin: Terret::Loop }
    ])
    ctx = loader.boot!
    ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new([
      { text: "Checking.", tool_calls: [
        Terret::LLM::ToolCall.new(id: "t1", name: "weather", args: { city: "CDMX" })
      ] },
      { text: "22C.", usage: { prompt_tokens: 9, completion_tokens: 3, cost: 0.0001 } }
    ]))
    ctx.with_owner("t") do
      ctx[:tools].register(name: "weather", description: "w", params: {}) { |city:| "22C in #{city}" }
    end
    ctx
  end

  def test_a_session_survives_a_restart_with_byte_identical_derived_context
    path = File.join(Dir.mktmpdir("terret-sqlite"), "restart.sqlite3")

    ctx1 = boot(path)
    s = ctx1[:sessions].create
    agent = ctx1[:loop].spawn_agent(session_id: s.id)
    assert_equal :completed, ctx1[:loop].run_turn(agent, "Weather in CDMX?")
    before = ctx1[:sessions].derive_messages(s.id).map(&:inspect)

    ctx2 = boot(path) # fresh store instance, fresh Sessions — a real restart
    resumed = ctx2[:sessions].resume(s.id)
    after = ctx2[:sessions].derive_messages(s.id).map(&:inspect)
    assert_equal before, after

    n = resumed.events.length
    assert_equal n, ctx2[:sessions].append(s.id, "user/message", { text: "still here" }).seq
    assert_equal [s.id], ctx2[:sessions].session_ids
  end
end
