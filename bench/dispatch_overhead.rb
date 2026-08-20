# frozen_string_literal: true
# Bench: per-event dispatch overhead on the bare Hames bus (plan §11). No
# LLM, no session store — this isolates ctx.emit/ctx.waterfall's own cost
# from everything Loop wraps around it, so a bus-level regression cannot
# hide behind (or get blamed on) a regression somewhere else in the loop.
# See bench/chunk_throughput.rb for the whole-loop half of §11's metric.
#
#   ruby bench/dispatch_overhead.rb

require_relative "../gems/hames/lib/hames"

module Bench
  module DispatchOverhead
    module_function

    N = (ENV["BENCH_N"] || 100_000).to_i

    # A fresh root Context per shape (no parent chain): the purest
    # measurement of one dispatch's own cost — mode assertion, listener
    # lookup, invocation — which is exactly what a declared listener pays on
    # the hot path.
    def emit_ctx
      Hames.event("bench/emit", mode: :emit) unless Hames.declared?("bench/emit")
      ctx = Hames::Context.new
      ctx.on("bench/emit") { |x| x + 1 }
      ctx
    end

    def waterfall_ctx
      Hames.event("bench/waterfall", mode: :waterfall) unless Hames.declared?("bench/waterfall")
      ctx = Hames::Context.new
      3.times { ctx.on("bench/waterfall") { |x, next_| next_.(x + 1) } }
      ctx
    end

    # Builds the context once, then times N dispatches against it — context
    # construction is not part of the per-event cost being measured. One
    # warmup pass (JIT/inline caches warm) precedes the measured pass.
    # Returns events/sec.
    def rate_for(ctx, n)
      n.times { yield ctx }
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      n.times { yield ctx }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      (n / elapsed).round
    end

    def run(n: N)
      emit_rate = rate_for(emit_ctx, n) { |ctx| ctx.emit("bench/emit", 0) }
      waterfall_rate = rate_for(waterfall_ctx, n) { |ctx| ctx.waterfall("bench/waterfall", 0) }
      results = {
        "dispatch_emit_events_per_sec" => emit_rate,
        "dispatch_waterfall_events_per_sec" => waterfall_rate
      }

      puts "Hames bus dispatch overhead (N=#{n})"
      puts "-" * 72
      puts format("%-30s %12d events  %14s events/sec", "emit (1 listener)", n, emit_rate)
      puts format("%-30s %12d events  %14s events/sec", "waterfall (3 deep)", n, waterfall_rate)
      results
    end
  end
end

Bench::DispatchOverhead.run if $PROGRAM_NAME == __FILE__
