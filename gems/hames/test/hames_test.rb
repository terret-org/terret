# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/hames"

class HamesEventsTest < Minitest::Test
  def setup
    Hames.reset_events!
    @ctx = Hames::Context.new
  end

  def test_undeclared_event_rejected_on_listen_and_dispatch
    assert_raises(Hames::ContractError) { @ctx.on("nope") { } }
    assert_raises(Hames::ContractError) { @ctx.emit("nope") }
  end

  def test_wrong_mode_dispatch_rejected
    Hames.event "a/b", mode: :waterfall
    assert_raises(Hames::ContractError) { @ctx.emit("a/b") }
  end

  def test_redeclaration_with_conflicting_mode_rejected
    Hames.event "a/b", mode: :emit
    assert_raises(Hames::ContractError) { Hames.event "a/b", mode: :serial }
  end

  def test_emit_runs_in_registration_order
    Hames.event "tick", mode: :emit
    seen = []
    @ctx.on("tick") { |n| seen << [:first, n] }
    @ctx.on("tick") { |n| seen << [:second, n] }
    @ctx.on("tick", prepend: true) { |n| seen << [:pre, n] }
    @ctx.emit("tick", 7)
    assert_equal [[:pre, 7], [:first, 7], [:second, 7]], seen
  end

  def test_waterfall_rewrites_propagate_through_next
    Hames.event "req", mode: :waterfall
    @ctx.on("req") { |v, next_| next_.(v + "-a") }
    @ctx.on("req") { |v, next_| next_.(v + "-b") }
    assert_equal "x-a-b", @ctx.waterfall("req", "x")
  end

  def test_waterfall_short_circuit_skips_downstream_and_base
    Hames.event "req", mode: :waterfall
    downstream = false
    base = false
    @ctx.on("req") { |_v, _next_| :vetoed } # owns the decision: no next_
    @ctx.on("req") { |v, next_| downstream = true; next_.(v) }
    result = @ctx.waterfall("req", "x") { |_v| base = true; :base }
    assert_equal :vetoed, result
    refute downstream
    refute base
  end

  def test_waterfall_base_block_runs_when_all_delegate
    Hames.event "req", mode: :waterfall
    @ctx.on("req") { |v, next_| next_.(v * 2) }
    assert_equal 20, @ctx.waterfall("req", 5) { |v| v * 2 }
  end

  def test_serial_first_non_nil_wins
    Hames.event "decide", mode: :serial
    order = []
    @ctx.on("decide") { |x| order << 1; nil }
    @ctx.on("decide") { |x| order << 2; x + 1 }
    @ctx.on("decide") { |x| order << 3; x + 100 }
    assert_equal 42, @ctx.serial("decide", 41)
    assert_equal [1, 2], order
  end

  def test_parallel_completes_all_listeners
    Hames.event "fan", mode: :parallel
    hits = []
    @ctx.on("fan") { hits << :a }
    @ctx.on("fan") { hits << :b }
    @ctx.parallel("fan")
    assert_equal %i[a b], hits.sort
  end

  def test_lookup_of_an_undeclared_event_raises_contract_error_naming_it
    err = assert_raises(Hames::ContractError) { Hames.event("nope/nothing") }
    assert_match %r{nope/nothing}, err.message
  end
end

class HamesEffectsAndForkTest < Minitest::Test
  def setup
    Hames.reset_events!
    Hames.event "e", mode: :emit
    @ctx = Hames::Context.new
  end

  def test_effects_dispose_in_reverse_order_per_owner
    disposed = []
    @ctx.with_owner("p1") do
      @ctx.effect { -> { disposed << :first } }
      @ctx.effect { -> { disposed << :second } }
    end
    @ctx.with_owner("p2") { @ctx.effect { -> { disposed << :other } } }
    @ctx.dispose_owner!("p1")
    assert_equal %i[second first], disposed
    @ctx.dispose!
    assert_equal %i[second first other], disposed
  end

  def test_listener_registration_is_a_reversible_effect
    hits = 0
    @ctx.with_owner("p1") { @ctx.on("e") { hits += 1 } }
    @ctx.emit("e")
    @ctx.dispose_owner!("p1")
    @ctx.emit("e")
    assert_equal 1, hits
  end

  def test_fork_sees_parent_listeners_and_services_but_disposes_alone
    seen = []
    @ctx.on("e") { seen << :parent }
    @ctx.register_service(:store, { k: 1 })
    child = @ctx.fork
    child.on("e") { seen << :child }
    child.emit("e")
    assert_equal %i[parent child], seen
    assert_equal({ k: 1 }, child[:store])

    child.dispose!
    seen.clear
    @ctx.emit("e")
    assert_equal %i[parent], seen
  end

  def test_service_resolution_raises_helpfully
    err = assert_raises(Hames::ServiceMissingError) { @ctx[:missing] }
    assert_match(/ctx\[:missing\]/, err.message)
  end
end

class HamesLoaderTest < Minitest::Test
  class Store < Hames::Service
    service_key :store
    def start(_ctx) = (@data = [])
    def push(x) = @data << x
    def data = @data
  end

  class Feeder < Hames::Service
    inject :store
    def start(ctx) = ctx[:store].push(config[:value])
  end

  def setup
    Hames.reset_events!
  end

  def test_boot_orders_by_inject_regardless_of_row_order
    loader = Hames::Loader.new
    loader.layer([
      { id: "feeder", plugin: Feeder, config: { value: 42 } },
      { id: "store",  plugin: Store }
    ])
    ctx = loader.boot!
    assert_equal [42], ctx[:store].data
  end

  def test_missing_provider_reports_the_unmet_need
    loader = Hames::Loader.new
    loader.layer([{ id: "feeder", plugin: Feeder }])
    err = assert_raises(Hames::CycleError) { loader.boot! }
    assert_match(/feeder \(needs store\)/, err.message)
  end

  def test_later_layer_replaces_row_config_wholesale
    loader = Hames::Loader.new
    loader.layer([{ id: "store", plugin: Store },
                  { id: "feeder", plugin: Feeder, config: { value: 1, extra: true } }])
    loader.layer([{ id: "feeder", config: { value: 99 } }]) # patch: whole replacement
    ctx = loader.boot!
    assert_equal [99], ctx[:store].data
    row = loader.dump_config.find { |r| r[:id] == "feeder" }
    refute row[:config].key?(:extra), "patch must replace config, not merge"
  end

  def test_disabled_rows_do_not_mount
    loader = Hames::Loader.new
    loader.layer([{ id: "store", plugin: Store },
                  { id: "feeder", plugin: Feeder, config: { value: 1 }, disabled: true }])
    ctx = loader.boot!
    assert_equal [], ctx[:store].data
  end

  def test_unload_disposes_effects_and_service
    loader = Hames::Loader.new
    loader.layer([{ id: "store", plugin: Store }])
    ctx = loader.boot!
    assert ctx.service?(:store)
    loader.unload!("store")
    refute ctx.service?(:store)
    assert_equal 0, ctx.instance_variable_get(:@effects).size
  end
end

class HamesMountUnloadSafetyTest < Minitest::Test
  # Registers a service and a listener (both owner effects) and THEN raises, so
  # a mount that does not roll back leaves those registrations live with no
  # entry in @mounted for any teardown to find them by.
  class Exploder < Hames::Service
    service_key :exploder
    def start(ctx)
      ctx.on("boom") { }
      raise "start exploded"
    end
  end

  class StubbornStop < Hames::Service
    service_key :stubborn_stop
    def start(_ctx); end
    def stop(_ctx) = raise "stop exploded"
  end

  # Raises on the first stop, succeeds on the second: a failed unload has to
  # leave the entry behind so a retry can actually finish the teardown.
  class FlakyStop < Hames::Service
    service_key :flaky_stop
    def start(_ctx) = @stops = 0
    def stop(_ctx)
      @stops += 1
      raise "stop flaked" if @stops == 1
    end
  end

  def setup
    Hames.reset_events!
    Hames.event "boom", mode: :emit
  end

  def effects_count(ctx) = ctx.instance_variable_get(:@effects).size

  def test_apply_raising_mid_mount_rolls_back_and_leaves_nothing_live
    loader = Hames::Loader.new
    loader.layer([{ id: "exploder", plugin: Exploder }])
    err = assert_raises(RuntimeError) { loader.boot! }
    assert_equal "start exploded", err.message

    ctx = loader.ctx
    refute ctx.service?(:exploder), "a service registered before the raise must not survive a failed mount"
    assert_equal 0, effects_count(ctx), "a failed mount must leave no live registrations"
    refute loader.mounted.key?("exploder"), "a plugin that failed to mount is not in @mounted"
  end

  def test_unload_disposes_owner_effects_even_when_stop_raises
    loader = Hames::Loader.new
    loader.layer([{ id: "ss", plugin: StubbornStop }])
    ctx = loader.boot!
    assert ctx.service?(:stubborn_stop)

    err = assert_raises(RuntimeError) { loader.unload!("ss") }
    assert_equal "stop exploded", err.message
    refute ctx.service?(:stubborn_stop),
           "owner effects must be disposed even when stop raises"
    assert_equal 0, effects_count(ctx)
  end

  def test_a_failed_unload_keeps_the_entry_so_it_can_be_retried_to_completion
    loader = Hames::Loader.new
    loader.layer([{ id: "fs", plugin: FlakyStop }])
    ctx = loader.boot!

    assert_raises(RuntimeError) { loader.unload!("fs") } # stop raises the first time
    refute ctx.service?(:flaky_stop), "owner effects disposed despite the raise"
    assert loader.mounted.key?("fs"), "a stop that raised must not lose the entry a retry needs"

    loader.unload!("fs") # the retry: stop succeeds, the entry finally goes
    refute loader.mounted.key?("fs")
  end
end

class HamesServiceInheritanceTest < Minitest::Test
  def test_service_key_and_inject_are_inherited_by_subclasses
    parent = Class.new(Hames::Service) do
      service_key :thing
      inject :dep
    end
    child = Class.new(parent)

    assert_equal :thing, child.service_key
    assert_equal [:dep], child.inject
  end

  def test_subclass_declarations_extend_rather_than_shadow
    parent = Class.new(Hames::Service) do
      service_key :thing
      inject :dep
    end
    child = Class.new(parent) do
      service_key :other
      inject :dep2
    end

    assert_equal :other, child.service_key
    assert_equal %i[dep dep2], child.inject
    # the parent is untouched
    assert_equal :thing, parent.service_key
    assert_equal [:dep], parent.inject
  end

  def test_the_base_service_class_has_no_key_and_no_deps
    assert_nil Hames::Service.service_key
    assert_equal [], Hames::Service.inject
  end

  def test_inheritance_walks_the_whole_chain_not_one_level
    parent = Class.new(Hames::Service) do
      service_key :thing
      inject :dep
    end
    child = Class.new(parent) { inject :dep2 }
    grandchild = Class.new(child)

    assert_equal :thing, grandchild.service_key
    assert_equal %i[dep dep2], grandchild.inject
  end
end

class HamesEffectHygieneTest < Minitest::Test
  def setup
    Hames.reset_events!
    @ctx = Hames::Context.new
  end

  def effects_count = @ctx.instance_variable_get(:@effects).size

  def test_a_called_disposer_removes_its_own_effect_entry
    calls = 0
    disposer = @ctx.effect { -> { calls += 1 } }
    assert_equal 1, effects_count

    disposer.call
    assert_equal 1, calls
    assert_equal 0, effects_count, "a disposed effect must not stay pinned in @effects"
  end

  def test_a_disposer_is_idempotent
    calls = 0
    disposer = @ctx.effect { -> { calls += 1 } }
    disposer.call
    disposer.call
    assert_equal 1, calls
  end

  def test_dispose_owner_still_runs_everything_once_in_reverse
    order = []
    @ctx.with_owner("me") do
      @ctx.effect { -> { order << :a } }
      @ctx.effect { -> { order << :b } }
    end
    @ctx.dispose_owner!("me")
    assert_equal %i[b a], order
    assert_equal 0, effects_count
  end

  def test_manually_disposing_then_owner_disposal_does_not_double_run
    calls = 0
    disposer = nil
    @ctx.with_owner("me") { disposer = @ctx.effect { -> { calls += 1 } } }
    disposer.call
    @ctx.dispose_owner!("me")
    assert_equal 1, calls
  end

  def test_a_disposed_listener_leaves_no_effect_entry
    Hames.event "tick", mode: :emit
    seen = []
    disposer = @ctx.on("tick") { seen << 1 }
    assert_equal 1, effects_count

    disposer.call
    @ctx.emit("tick")
    assert_empty seen, "a disposed listener must not fire"
    assert_equal 0, effects_count, "a disposed listener must not stay pinned in @effects"
  end

  def test_a_listener_disposer_is_idempotent_across_owner_disposal
    Hames.event "tock", mode: :emit
    disposer = nil
    @ctx.with_owner("me") { disposer = @ctx.on("tock") { } }
    disposer.call
    @ctx.dispose_owner!("me") # must not double-run or raise
    disposer.call             # nor this
    assert_equal 0, effects_count
  end
end

class HamesReconfigureTest < Minitest::Test
  class Knobbed < Hames::Service
    service_key :knobbed
    attr_reader :knob, :seen

    def start(_ctx)
      @knob = config[:knob]
      @seen = []
    end

    def reconfigure(config)
      @knob = config[:knob]
    end
  end

  class Stubborn < Hames::Service
    service_key :stubborn
    def start(_ctx); end
    # no reconfigure override
  end

  def setup
    Hames.reset_events!
  end

  def boot(rows)
    loader = Hames::Loader.new
    loader.layer(rows)
    [loader.boot!, loader]
  end

  def test_reconfigure_swaps_config_wholesale_and_invokes_the_hook
    ctx, loader = boot([{ id: "knobbed", plugin: Knobbed, config: { knob: 1, extra: true } }])
    loader.reconfigure!("knobbed", { knob: 2 })
    assert_equal 2, ctx[:knobbed].knob
    assert_equal({ knob: 2 }, ctx[:knobbed].config, "wholesale replace: :extra must be gone")
  end

  def test_reconfigure_emits_config_updated_when_declared
    Hames.event("config/updated", mode: :emit)
    ctx, loader = boot([{ id: "knobbed", plugin: Knobbed, config: { knob: 1 } }])
    seen = []
    ctx.on("config/updated") { |id, cfg| seen << [id, cfg] }
    loader.reconfigure!("knobbed", { knob: 3 })
    assert_equal [["knobbed", { knob: 3 }]], seen
  end

  def test_reconfigure_without_the_declaration_does_not_raise
    ctx, loader = boot([{ id: "knobbed", plugin: Knobbed, config: { knob: 1 } }])
    loader.reconfigure!("knobbed", { knob: 4 }) # no config/updated declared: no emit, no raise
    assert_equal 4, ctx[:knobbed].knob
  end

  def test_a_service_without_the_hook_warns_and_keeps_running
    _ctx, loader = boot([{ id: "stubborn", plugin: Stubborn, config: {} }])
    warned = capture_warn { loader.reconfigure!("stubborn", { x: 1 }) }
    assert_match(/does not support hot-reconfigure/, warned)
  end

  def test_reconfiguring_an_unknown_row_raises
    _ctx, loader = boot([])
    assert_raises(KeyError) { loader.reconfigure!("ghost", {}) }
  end

  private

  def capture_warn
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end
end

class HamesPatchSwapTest < Minitest::Test
  class ProviderA < Hames::Service
    service_key :greeter
    def start(_ctx); end
    def greet = "A:#{config[:tone]}"
  end

  class ProviderB < Hames::Service
    service_key :greeter
    def start(_ctx); end
    def greet = "B:#{config[:tone]}"
  end

  def setup = Hames.reset_events!

  def test_a_patch_row_swaps_the_plugin_class_wholesale
    loader = Hames::Loader.new
    loader.layer([{ id: "greeter", plugin: ProviderA, config: { tone: "warm" } }])
    loader.layer([{ id: "greeter", plugin: ProviderB, config: { tone: "cold" } }])
    ctx = loader.boot!
    assert_equal "B:cold", ctx[:greeter].greet, "the later layer's plugin class must win"
  end

  def test_a_patch_row_without_a_plugin_keeps_the_class_and_replaces_config
    loader = Hames::Loader.new
    loader.layer([{ id: "greeter", plugin: ProviderA, config: { tone: "warm", extra: 1 } }])
    loader.layer([{ id: "greeter", config: { tone: "cold" } }])
    ctx = loader.boot!
    assert_equal "A:cold", ctx[:greeter].greet
    assert_equal({ tone: "cold" }, ctx[:greeter].config, "wholesale, not merged")
  end
end

class HamesReconfigureAtomicityTest < Minitest::Test
  class Fragile < Hames::Service
    service_key :fragile
    attr_reader :knob

    def start(_ctx) = @knob = config[:knob]

    def reconfigure(config)
      raise "hook exploded" if config[:explode]

      @knob = config[:knob]
    end
  end

  def setup = Hames.reset_events!

  def test_a_raising_hook_rolls_the_row_and_config_back
    loader = Hames::Loader.new
    loader.layer([{ id: "fragile", plugin: Fragile, config: { knob: 1 } }])
    ctx = loader.boot!
    assert_raises(RuntimeError) { loader.reconfigure!("fragile", { knob: 2, explode: true }) }
    assert_equal({ knob: 1 }, ctx[:fragile].config, "config must roll back when the hook raises")
    assert_equal 1, ctx[:fragile].knob
    loader.reconfigure!("fragile", { knob: 3 }) # and the row still works afterward
    assert_equal 3, ctx[:fragile].knob
  end

  def test_hook_registrations_are_owned_by_the_row
    loader = Hames::Loader.new
    loader.layer([{ id: "fragile", plugin: Fragile, config: { knob: 1 } }])
    ctx = loader.boot!
    owner_seen = nil
    ctx[:fragile].define_singleton_method(:reconfigure) do |_config|
      owner_seen = ctx.instance_variable_get(:@owner)
    end
    loader.reconfigure!("fragile", { knob: 9 })
    assert_equal "fragile", owner_seen, "reconfigure hooks must run under with_owner(id)"
  end
end

class HamesEmitIsolationTest < Minitest::Test
  def setup
    Hames.reset_events!
    Hames.event "boom", mode: :emit
    Hames.event "flow", mode: :waterfall
    @ctx = Hames::Context.new
  end

  def test_a_raising_emit_listener_is_isolated_and_later_listeners_still_run
    seen = []
    @ctx.on("boom") { |_| raise "listener bug" }
    @ctx.on("boom") { |x| seen << x }

    warned = capture_warn { @ctx.emit("boom", 1) } # must not raise
    assert_equal [1], seen
    assert_includes warned, "listener bug"
    assert_includes warned, "RuntimeError"
  end

  def test_waterfall_listeners_still_raise_through
    @ctx.on("flow") { |_x, _next_| raise "load-bearing" }
    assert_raises(RuntimeError) { @ctx.waterfall("flow", 1) }
  end

  private

  def capture_warn
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end
end
