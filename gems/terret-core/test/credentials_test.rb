# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "base64"
require "openssl"
require "json"
require_relative "../lib/terret"

# ctx[:credentials] (plan §6.9): ENV-first resolution, an optional AES-256-GCM
# file store, and — the security point of the whole service — every resolved
# value fed to the session scrubber so it can never reach the durable log.
class CredentialsTest < Minitest::Test
  def creds_ctx(config = {})
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "credentials", plugin: Terret::Credentials, config: config }
    ])
    loader.boot!
  end

  # Build a store on disk in exactly the format the service reads, so the real
  # crypto path is exercised rather than a mock: JSON of provider =>
  # base64(iv(12) || auth_tag(16) || ciphertext), AES-256-GCM under `key`.
  def write_store(path, key, entries)
    blob = entries.transform_values do |value|
      cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
      cipher.key = key
      iv = cipher.random_iv
      ciphertext = cipher.update(value) + cipher.final
      Base64.strict_encode64(iv + cipher.auth_tag + ciphertext)
    end
    File.write(path, JSON.generate(blob))
  end

  def with_env(vars)
    old = vars.to_h { |k, _| [k, ENV[k]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
  end

  # -- resolution order -----------------------------------------------------

  def test_env_wins
    ctx = creds_ctx
    with_env("OPENROUTER_API_KEY" => "sk-from-env-0123456789") do
      assert_equal "sk-from-env-0123456789", ctx[:credentials].resolve(:openrouter)
    end
  end

  def test_the_file_store_resolves_when_env_is_silent
    Dir.mktmpdir do |dir|
      key = OpenSSL::Random.random_bytes(32)
      path = File.join(dir, "creds.json")
      write_store(path, key, { "openrouter" => "sk-from-file-0123456789" })
      ctx = creds_ctx(file: path)
      with_env("OPENROUTER_API_KEY" => nil,
               "TERRET_CREDENTIALS_KEY" => Base64.strict_encode64(key)) do
        assert_equal "sk-from-file-0123456789", ctx[:credentials].resolve(:openrouter)
      end
    end
  end

  def test_env_wins_even_when_a_file_entry_exists
    Dir.mktmpdir do |dir|
      key = OpenSSL::Random.random_bytes(32)
      path = File.join(dir, "creds.json")
      write_store(path, key, { "openrouter" => "sk-from-file-0123456789" })
      ctx = creds_ctx(file: path)
      with_env("OPENROUTER_API_KEY" => "sk-from-env-0123456789",
               "TERRET_CREDENTIALS_KEY" => Base64.strict_encode64(key)) do
        assert_equal "sk-from-env-0123456789", ctx[:credentials].resolve(:openrouter)
      end
    end
  end

  # A present store with no master key must REFUSE — never read plaintext,
  # never fall back to anything unprotected.
  def test_a_present_file_with_no_master_key_refuses
    Dir.mktmpdir do |dir|
      key = OpenSSL::Random.random_bytes(32)
      path = File.join(dir, "creds.json")
      write_store(path, key, { "openrouter" => "sk-from-file-0123456789" })
      ctx = creds_ctx(file: path)
      with_env("OPENROUTER_API_KEY" => nil, "TERRET_CREDENTIALS_KEY" => nil) do
        err = assert_raises(Terret::Credentials::Error) { ctx[:credentials].resolve(:openrouter) }
        assert_match(/master key/, err.message)
      end
    end
  end

  def test_a_missing_provider_resolves_to_nil
    ctx = creds_ctx
    with_env("OPENROUTER_API_KEY" => nil) do
      assert_nil ctx[:credentials].resolve(:openrouter)
    end
  end

  # -- the payoff -----------------------------------------------------------

  # The security point: a value credentials resolved never reaches the durable
  # log, even when a tool echoes it straight back into its result.
  def test_a_resolved_credential_is_scrubbed_from_a_later_append
    ctx = creds_ctx
    with_env("OPENROUTER_API_KEY" => "sk-resolved-abcdef123456") do
      ctx[:credentials].resolve(:openrouter)
    end
    s = ctx[:sessions].create
    ev = ctx[:sessions].append(s.id, "tool/result",
                               { id: "tc1", content: "the key is sk-resolved-abcdef123456" })
    assert_equal "the key is [REDACTED]", ev.payload[:content]
    refute(s.events.any? { |e| e.payload.inspect.include?("sk-resolved-abcdef123456") })
  end

  # The exact-string match is literal, not a regex: a value whose bytes contain
  # regex metacharacters scrubs the value itself, not whatever it might mean as
  # a pattern.
  def test_a_resolved_value_is_matched_literally_not_as_a_regexp
    ctx = creds_ctx
    with_env("WEIRD_API_KEY" => "a.b.c+xyz(secret)1234") do
      ctx[:credentials].resolve(:weird)
    end
    s = ctx[:sessions].create
    ev = ctx[:sessions].append(s.id, "user/message",
                               { text: "value a.b.c+xyz(secret)1234 and axbxc are different" })
    assert_equal "value [REDACTED] and axbxc are different", ev.payload[:text]
  end

  # The guard: an empty or too-short resolved value must never feed the
  # scrubber, or an exact-string gsub would paint the whole log (the empty
  # string inserts the token between every character).
  def test_a_short_or_empty_resolved_value_never_becomes_a_scrub_pattern
    ctx = creds_ctx
    with_env("OPENROUTER_API_KEY" => "") do
      assert_nil ctx[:credentials].resolve(:openrouter), "an empty env var reads as silent"
    end
    with_env("TINY_API_KEY" => "ab") do
      assert_equal "ab", ctx[:credentials].resolve(:tiny)
    end
    s = ctx[:sessions].create
    ev = ctx[:sessions].append(s.id, "user/message", { text: "a message mentioning ab twice: ab" })
    assert_equal "a message mentioning ab twice: ab", ev.payload[:text],
                 "a two-character value must not be an active scrub pattern"
  end

  # -- a corrupted store fails closed ---------------------------------------

  # A store whose entry is not valid Base64 is a tampered or half-written store.
  # It must fail closed through the friendly Error — never a raw ArgumentError
  # from the Base64 decoder, and never plaintext — so the operator gets a
  # message that names the store rather than a decoder backtrace.
  def test_a_bad_base64_store_entry_raises_the_friendly_error_never_plaintext
    Dir.mktmpdir do |dir|
      key = OpenSSL::Random.random_bytes(32)
      path = File.join(dir, "creds.json")
      File.write(path, JSON.generate({ "openrouter" => "not valid base64 !!!" }))
      ctx = creds_ctx(file: path)
      with_env("OPENROUTER_API_KEY" => nil,
               "TERRET_CREDENTIALS_KEY" => Base64.strict_encode64(key)) do
        assert_raises(Terret::Credentials::Error) { ctx[:credentials].resolve(:openrouter) }
      end
    end
  end

  # Valid Base64, but far too few bytes to hold an iv, an auth tag, and any
  # ciphertext — a truncated store. The cipher setup raises before it ever
  # decrypts anything, and that too must surface as the friendly Error.
  def test_a_truncated_store_entry_raises_the_friendly_error_never_plaintext
    Dir.mktmpdir do |dir|
      key = OpenSSL::Random.random_bytes(32)
      path = File.join(dir, "creds.json")
      File.write(path, JSON.generate({ "openrouter" => Base64.strict_encode64("short") }))
      ctx = creds_ctx(file: path)
      with_env("OPENROUTER_API_KEY" => nil,
               "TERRET_CREDENTIALS_KEY" => Base64.strict_encode64(key)) do
        assert_raises(Terret::Credentials::Error) { ctx[:credentials].resolve(:openrouter) }
      end
    end
  end

  # -- reversibility --------------------------------------------------------

  def test_unloading_the_row_removes_its_scrubber
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "session_store", plugin: Terret::Store::Memory },
      { id: "sessions", plugin: Terret::Sessions },
      { id: "credentials", plugin: Terret::Credentials }
    ])
    ctx = loader.boot!
    with_env("OPENROUTER_API_KEY" => "sk-resolved-abcdef123456") do
      ctx[:credentials].resolve(:openrouter)
    end
    loader.unload!("credentials")
    s = ctx[:sessions].create
    ev = ctx[:sessions].append(s.id, "user/message", { text: "sk-resolved-abcdef123456" })
    assert_equal "sk-resolved-abcdef123456", ev.payload[:text]
  end
end
