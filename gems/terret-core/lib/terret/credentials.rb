# frozen_string_literal: true

require "json"
require "base64"
require "openssl"

module Terret
  # ctx[:credentials] — plan §6.9. The one place a provider's secret is
  # resolved, and its security point: every value it resolves is fed to the
  # session scrubber (Sessions#register_scrubber), so a resolved credential can
  # never reach the durable log even if a tool echoes it back into a result.
  # That is what makes this more than a lookup table — it closes the loop the
  # config-pattern redactor (docs/exec.md §6) leaves open, catching a secret by
  # its exact bytes rather than by a shape a deployment had to name in advance.
  #
  # Resolution order is ENV-first by convention (`<PROVIDER>_API_KEY`), then an
  # optional encrypted file store. ENV ALWAYS wins; the file is consulted only
  # when ENV is silent (unset or empty), and a file present with no master key
  # REFUSES rather than falling back to anything unprotected.
  #
  # On-disk format (a deployment writes it; a `trt credentials set` CLI is
  # future work, plan §14 — only the format is promised here): JSON at the
  # configured `file:` path, mapping each provider name to
  #
  #   Base64.strict_encode64( iv(12 bytes) || auth_tag(16 bytes) || ciphertext )
  #
  # each entry AES-256-GCM under a 32-byte master key. The master key is ENV
  # `TERRET_CREDENTIALS_KEY`, itself Base64 of exactly 32 bytes — generate one
  # with `openssl rand -base64 32`. Both the file and the key are optional: with
  # neither, ENV `<PROVIDER>_API_KEY` resolves on its own and the file store is
  # inert, which is the shipped default.
  #
  # Deferred (plan §14): an OS-keychain backend, and the writer CLI above.
  class Credentials < Hames::Service
    service_key :credentials
    inject :sessions
    config_schema file: { type: String,
                          doc: "path to an AES-256-GCM encrypted credential store, provider => " \
                               "base64(iv+tag+ciphertext); the master key is ENV " \
                               "TERRET_CREDENTIALS_KEY (base64 of 32 bytes) and the per-provider " \
                               "ENV <PROVIDER>_API_KEY always wins — neither is config, and with " \
                               "no file only ENV resolves" }

    class Error < StandardError; end

    IV_LEN  = 12  # AES-GCM standard nonce
    TAG_LEN = 16  # AES-GCM authentication tag
    KEY_LEN = 32  # AES-256

    # Below this an exact-string scrub would match far too much: the empty
    # string inserts the token between every character, and a two-character
    # value paints ordinary prose. A real resolved credential dwarfs this
    # floor, so a value under it is still resolved and returned — it just does
    # not become an active scrub pattern (fail-safe: never corrupt the log to
    # chase a value too short to be a secret worth catching by its bytes).
    MIN_SCRUB_LENGTH = 8
    REPLACEMENT = "[REDACTED]"

    def start(ctx)
      @secrets = []
      @mutex = Mutex.new
      # ONE scrubber over the growing set rather than a fresh registration per
      # resolve: re-resolving a provider must not stack duplicate scrubbers, and
      # a scrubber reaches every append whether it was registered early or late.
      ctx[:sessions].register_scrubber(method(:scrub))
    end

    def reconfigure(_config); end # the file path is read per resolve

    # The credential for a provider by name, or nil. ENV wins; then the file
    # store when configured. A non-trivial resolved value is registered as an
    # exact-string scrub pattern before it is returned, so anything that later
    # echoes it into the log is caught.
    def resolve(provider)
      name = provider.to_s
      env = ENV["#{env_name(name)}_API_KEY"]
      value = (env unless env.nil? || env.empty?) || from_file(name)
      remember(value) if value
      value
    end

    private

    # Exact-string, block-form gsub: never a Regexp a value's own metacharacters
    # could turn into an over-match, and never gsub's STRING replacement (a `\0`
    # inside a secret would paste the secret back in). Reads a snapshot under
    # the lock so a concurrent resolve cannot mutate the set mid-fold.
    def scrub(text)
      @mutex.synchronize { @secrets.dup }.reduce(text) do |acc, secret|
        acc.gsub(secret) { REPLACEMENT }
      end
    end

    def remember(value)
      return unless value.length >= MIN_SCRUB_LENGTH

      @mutex.synchronize { @secrets << value unless @secrets.include?(value) }
    end

    # openrouter => OPENROUTER; a hyphen or dot in a provider name becomes an
    # underscore so the env var is a legal shell identifier.
    def env_name(name) = name.upcase.gsub(/[^A-Z0-9]/, "_")

    # nil when no file is configured or it does not exist; RAISES when the file
    # exists but no master key is set — never a plaintext or unprotected
    # fallback. Read fresh each resolve, so a deployment can rewrite the store
    # without a remount.
    def from_file(name)
      store = file_store or return nil
      entry = store[name] or return nil

      decrypt(Base64.strict_decode64(entry))
    end

    def file_store
      path = config[:file]
      return nil unless path && File.exist?(path)

      unless master_key
        raise Error, "credential store #{path.inspect} exists but TERRET_CREDENTIALS_KEY is not " \
                     "set; refusing to resolve credentials without the master key"
      end

      parsed = JSON.parse(File.read(path))
      raise Error, "credential store #{path.inspect} is not a JSON object" unless parsed.is_a?(Hash)

      parsed
    end

    # nil only when the key is absent/empty; a present-but-malformed key RAISES
    # rather than reading as absent, so a typo refuses instead of silently
    # skipping to a fallback.
    def master_key
      raw = ENV["TERRET_CREDENTIALS_KEY"]
      return nil if raw.nil? || raw.empty?

      key = begin
        Base64.strict_decode64(raw)
      rescue ArgumentError
        raise Error, "TERRET_CREDENTIALS_KEY is not valid Base64"
      end
      unless key.bytesize == KEY_LEN
        raise Error, "TERRET_CREDENTIALS_KEY must be Base64 of exactly #{KEY_LEN} bytes (an AES-256 key)"
      end

      key
    end

    def decrypt(blob)
      cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
      cipher.key = master_key
      cipher.iv = blob.byteslice(0, IV_LEN)
      cipher.auth_tag = blob.byteslice(IV_LEN, TAG_LEN)
      plaintext = cipher.update(blob.byteslice(IV_LEN + TAG_LEN..) || "") + cipher.final
      plaintext.force_encoding(Encoding::UTF_8)
    rescue OpenSSL::Cipher::CipherError => e
      raise Error, "a credential store entry failed to decrypt " \
                   "(wrong master key or a tampered store): #{e.message}"
    end
  end
end
