# frozen_string_literal: true
# Bench: end-to-end streaming chunk throughput through a full run_turn (plan
# §11) — the whole loop (session log appends, tool-call check, the
# session/event fan-out), not the bus in isolation. See
# bench/dispatch_overhead.rb for the bare-bus half of §11's metric.
#
# A FakeAdapter script streams N chunks through one run_turn against the
# in-memory session store — no network, no tool calls (so the turn closes
# after its single step).
#
#   ruby bench/chunk_throughput.rb

require_relative "../gems/terret-core/lib/terret"

module Bench
  module ChunkThroughput
    module_function

    N = (ENV["BENCH_CHUNKS"] || 10_000).to_i

    # FakeAdapter#stream slices its text 8 chars at a time
    # (gems/terret-core/lib/terret/llm.rb); a text of n*8 chars yields
    # exactly n assistant/chunk events.
    CHUNK_CHARS = 8

    def boot
      Hames::Loader.new.tap do |loader|
        loader.layer([
          { id: "session_store", plugin: Terret::Store::Memory },
          { id: "sessions", plugin: Terret::Sessions },
          { id: "prompt",   plugin: Terret::Prompt },
          { id: "tools",    plugin: Terret::Tools::Registry },
          { id: "llm",      plugin: Terret::LLM::Service, config: { roles: { main: "fake/scripted" } } },
          { id: "loop",     plugin: Terret::Loop }
        ])
      end.boot!
    end

    # A single scripted reply with no tool calls: one step, one turn.
    def turn(n_chunks) = { text: "a" * (n_chunks * CHUNK_CHARS) }

    def run(n: N)
      ctx = boot
      ctx[:llm].register_adapter("fake", Terret::LLM::FakeAdapter.new([turn(n), turn(n)]))

      warmup_session = ctx[:sessions].create
      warmup_agent = ctx[:loop].spawn_agent(session_id: warmup_session.id)
      ctx[:loop].run_turn(warmup_agent, "go") # warmup pass: JIT/caches warm

      session = ctx[:sessions].create
      agent = ctx[:loop].spawn_agent(session_id: session.id)

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ctx[:loop].run_turn(agent, "go")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      rate = (n / elapsed).round
      puts "Chunk throughput (N=#{n} chunks, one run_turn end-to-end)"
      puts "-" * 72
      puts format("%-30s %12d chunks  %10.4fs  %14s chunks/sec", "assistant/chunk stream", n, elapsed, rate)
      { "chunk_throughput_chunks_per_sec" => rate }
    end
  end
end

Bench::ChunkThroughput.run if $PROGRAM_NAME == __FILE__
