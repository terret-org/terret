# Bench lane

Plan §11's bench lane: track chunk throughput and per-event dispatch
overhead so a kernel change cannot silently regress streaming.

```bash
rake bench                  # runs both benches, prints a combined table
rake bench BENCH_FLOORS=1   # also asserts each metric >= bench/floors.yml, exits 1 if any is below
```

Two scripts, two metrics:

- `dispatch_overhead.rb` — events/sec for `Hames::Context#emit` (one
  listener) and `#waterfall` (three deep), on a bare bus with no LLM and no
  session store. This isolates the bus's own dispatch cost.
- `chunk_throughput.rb` — chunks/sec for a full `run_turn` streaming
  `assistant/chunk` events through the real session log (in-memory store),
  via `Terret::LLM::FakeAdapter`. This is the whole loop, not the bus alone.

Both use `Process.clock_gettime(Process::CLOCK_MONOTONIC)`, one warmup pass
before the measured pass, and no gems beyond stdlib. Neither runs as part of
`rake test` — this is a separate lane, run standalone (`ruby
bench/dispatch_overhead.rb`) or via `rake bench`.

`bench/floors.yml` holds the regression floors, set at roughly 10% of a
dev-box baseline — enough margin to absorb machine noise and a slower CI
runner while still catching an order-of-magnitude regression. See the
comment at the top of that file for the rationale and the raw numbers it
was derived from. CI runs `rake bench BENCH_FLOORS=1` after the test
suites (`.github/workflows/ci.yml`).
