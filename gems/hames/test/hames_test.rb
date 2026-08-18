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
