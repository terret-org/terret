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
