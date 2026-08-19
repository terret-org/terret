# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret"

# AdapterBase carries the retry/backoff policy shared by every real adapter:
# retryable failures (429, 5xx, transport drops before any bytes stream) are
# retried with jittered exponential backoff; anything else raises through.
class AdapterBaseTest < Minitest::Test
  class Probe < Terret::LLM::AdapterBase
  end

  def setup
    @slept = []
    @probe = Probe.new(max_attempts: 4, base_delay: 0.5, sleeper: ->(s) { @slept << s })
  end

  def test_retries_retryable_errors_until_success
    attempts = 0
    result = @probe.with_retries do
      attempts += 1
      raise Terret::LLM::RetryableError.new("overloaded", status: 429) if attempts < 3

      "ok"
    end

    assert_equal "ok", result
    assert_equal 3, attempts
    assert_equal 2, @slept.length
  end

  def test_raises_after_exhausting_attempts
    attempts = 0
    err = assert_raises(Terret::LLM::RetryableError) do
      @probe.with_retries do
        attempts += 1
        raise Terret::LLM::RetryableError.new("still overloaded", status: 429)
      end
    end

    assert_equal 4, attempts
    assert_equal 429, err.status
  end

  def test_does_not_retry_non_retryable_adapter_errors
    attempts = 0
    assert_raises(Terret::LLM::AdapterError) do
      @probe.with_retries do
        attempts += 1
        raise Terret::LLM::AdapterError.new("bad key", status: 401, body: "{}")
      end
    end

    assert_equal 1, attempts
    assert_empty @slept
  end

  def test_backoff_delays_are_jittered_and_exponentially_capped
    assert_raises(Terret::LLM::RetryableError) do
      @probe.with_retries { raise Terret::LLM::RetryableError.new("nope", status: 503) }
    end

    assert_equal 3, @slept.length
    @slept.each_with_index do |delay, i|
      assert_operator delay, :>, 0
      assert_operator delay, :<=, 0.5 * (2**i)
    end
  end
end

class LLMServiceRolesTest < Minitest::Test
  def test_set_role_repoints_a_role_at_a_new_provider_and_model
    service = Terret::LLM::Service.new(roles: { main: "fake/one" })
    service.start(nil)
    a = Object.new
    b = Object.new
    service.register_adapter("fake", a)
    service.register_adapter("alt", b)

    assert_equal [a, "one"], service.resolve(:main)

    service.set_role(:main, "alt/two")
    assert_equal [b, "two"], service.resolve(:main)

    assert_raises(ArgumentError) { service.set_role(:main, "no-slash") }
    assert_raises(ArgumentError) { service.set_role(:main, "trailing/") }
    assert_raises(ArgumentError) { service.set_role(nil, "alt/two") }
    assert_raises(ArgumentError) { service.set_role(123, "alt/two") }
  end

  def test_set_role_rejects_a_provider_with_no_registered_adapter
    service = Terret::LLM::Service.new(roles: { main: "fake/one" })
    service.start(nil)
    service.register_adapter("fake", Object.new)

    assert_raises(ArgumentError) { service.set_role(:main, "ghost/x") }
    assert_equal [service.instance_variable_get(:@adapters)["fake"], "one"], service.resolve(:main)
  end

  def test_reconfigure_swaps_the_roles_and_keeps_registered_adapters
    service = Terret::LLM::Service.new(roles: { main: "fake/one" })
    service.start(nil)
    a = Object.new
    b = Object.new
    service.register_adapter("fake", a)
    service.register_adapter("alt", b)

    warned = capture_warn do
      service.replace_config!({ roles: { main: "alt/two", compactor: "fake/small" } })
      service.reconfigure({ roles: { main: "alt/two", compactor: "fake/small" } })
    end

    assert_empty warned, "roles are hot-swappable; the base warning would be a lie"
    assert_equal [b, "two"], service.resolve(:main)
    assert_equal [a, "small"], service.resolve(:compactor)
    # config layering replaces wholesale, so a role the new config drops is gone
    assert_raises(KeyError) { service.resolve(:titler) }
  end

  def capture_warn
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  def test_start_does_not_alias_the_callers_config_hash
    original_roles = { main: "fake/one" }
    service = Terret::LLM::Service.new(roles: original_roles)
    service.start(nil)
    a = Object.new
    b = Object.new
    service.register_adapter("fake", a)
    service.register_adapter("alt", b)

    service.set_role(:main, "alt/two")

    assert_equal "fake/one", original_roles[:main]
  end
end
