# Cookbook: Adding a Provider

A **provider** is an implementation of a sole-provider seam — a service key
that exactly one row may claim, where nothing sits behind the key
dispatching between implementations (`docs/subagents.md` §1). Adding a tool
(`docs/cookbook/adding-a-tool.md`) grows an agent's roster; adding a
provider swaps out a whole capability the harness resolves by key. This
page walks it using `ctx[:summarizer]` as the model, because Terret already
ships **two** implementations of that one seam — so the pattern is on the
page, not invented for it.

The two are `Terret::RoleSummarizer` (the no-signup default, a model call
through a configured role) and `Terret::Morph::Summarizer` (Morph's
extractive Compact API over the wire). Both live in the tree —
`gems/terret-core/lib/terret/compactor.rb` and `gems/terret-morph` — and
both claim `service_key :summarizer`. Only one is ever mounted at a time,
and §3 is why that is a guarantee rather than a hope.

Read `docs/hames-primer.md` §1 first: a provider is a Hames service, and
"sole-provider seam" is just the kernel's one-key-one-registration rule
(there enforced by `register_service` raising `ContractError`) put to work.

## 1. The seam contract

A seam is a method signature and a discipline, agreed between the provider
and whatever injects the key. For `ctx[:summarizer]` the whole contract is
one method:

```ruby
ctx[:summarizer].summarize(history) # => a String, or nil to decline
```

`history` is the projected message history; the return is a compacted
string, or `nil`/empty to **decline** (§4). The consumer is the compactor
(`gems/terret-core/lib/terret/compactor.rb`), which injects the key and
treats a decline as "skip this boundary":

```ruby
class Compactor < Hames::Service
  service_key :compactor
  inject :sessions, :summarizer
  # ...
  def compact!(session_id)
    # ...
    summary = @ctx[:summarizer].summarize(history)
    unless summary.is_a?(String) && !summary.strip.empty?
      warn "terret: compaction skipped for #{session_id}: summarizer declined"
      return nil
    end
    # ... append the boundary event
  end
end
```

That `inject :summarizer` line is the entire coupling. The compactor never
names Morph or the role summarizer; it names the key, and boot resolves
whichever provider a profile mounted. A new provider is a new class that
answers `summarize` the same way — nothing about the consumer changes.

Before you write one, find the seam's contract the same way: the injecting
service and its call site tell you the method, the argument, and what a
decline means. Get the return discipline wrong — raise where the consumer
expects `nil` — and you turn an optimization that degrades into a crash.

## 2. `service_key` claims the seam

A provider declares the seam it implements with `service_key`, and injects
whatever it needs to do the job. `RoleSummarizer` needs the model seam;
`Morph::Summarizer` needs no seam at all, only config and a network call:

```ruby
# gems/terret-core/lib/terret/compactor.rb
class RoleSummarizer < Hames::Service
  service_key :summarizer
  inject :llm
  config_schema role: { type: [String, Symbol], default: :compactor,
                        doc: "llm role a summary is produced under" }

  def summarize(history)
    request = LLM::Request.new(model: nil, system: PROMPT, messages: history, tools: [])
    @ctx[:llm].stream(@ctx, role: config[:role] || :compactor, request: request) { |_ev| }.text
  end
end
```

```ruby
# gems/terret-morph/lib/terret/morph/summarizer.rb
class Summarizer < Hames::Service
  service_key :summarizer
  config_schema compression_ratio: { type: Numeric, default: 0.4,
                                     doc: "target fraction of the original token count" },
                api_key:  { type: String,
                            doc: "Morph key; falls back to ENV MORPH_API_KEY when unset" },
                api_base: { type: String, default: "https://api.morphllm.com/v1",
                            doc: "Morph Compact API base URL" },
                timeout:  { type: Numeric, default: 30.0,
                            doc: "seconds a compaction request may run" }
  # ...
end
```

Both declare `config_schema` (`docs/hames-primer.md` §6) so `trt doctor` and
the config catalog can read them — a provider that reads config without a
schema is reported `unschema'd` and is the exact signal an unaudited plugin
gives off (`docs/composition.md` §9). Note what is **not** in Morph's
schema: `transport:` (§5). It is a test seam, not YAML config, so it is read
from the config hash but deliberately left out of the schema — an operator
never sets it, and a doctor should not invite them to.

## 3. The sole-provider refusal

Two rows both claiming `:summarizer` do not "last one wins" — they collide
at boot. `Context#register_service` refuses a second claim on a key that is
taken, and `Service#apply` registers through it, so the second row to mount
raises `Hames::ContractError` naming the key (`docs/hames-primer.md` §1).
That refusal is the whole meaning of "sole-provider": the answer to "what
summarizes in this deployment" is decided once, by which single row mounts,
and cannot be quietly doubled.

Which means **choosing** a provider is choosing which row is enabled — not
mounting both and hoping. A profile mounts exactly one summarizer row.
Swapping RoleSummarizer for Morph is a `plugin:` swap on that one row, the
same single-row move the sandbox seam uses (`docs/composition.md` §4):

```yaml
# in a profile's patch.yml — one row, plugin swapped, config restated whole
rows:
  - id: summarizer
    plugin: Terret::Morph::Summarizer
    config:
      api_key: !env MORPH_API_KEY
      compression_ratio: 0.4
```

Because a patch replaces config wholesale (`docs/composition.md` §4), the
swap carries the new provider's config with it; a swap that should inherit
nothing from the row it replaces says `config: {}` out loud. The base
bundle ships **no** summarizer row at all — compaction is opt-in, so a
profile that wants it adds both a summarizer provider row and a `compactor`
row (`gems/terret/config/bundle.yml` has neither). That is the ordinary
shape for an optional seam: the consumer and its provider are mounted
together by the profile that wants the capability.

A provider gem also does not have to be a bundle. `terret-morph` ships **no**
`terret` metadata key in its gemspec — it is a library of one provider
class, mounted by a profile that lists `terret/morph` in its `requires:` (or
a bundle's) and names `Terret::Morph::Summarizer` in a row.
`docs/cookbook/adding-a-bundle.md` covers when a gem should ship a bundle of
its own versus be mounted by a row someone else writes.

## 4. Nil-on-failure, where it applies

`ctx[:summarizer]` is an **optimization** seam: compaction makes a long
history cheaper, and a compaction that cannot happen should leave the
session exactly as it was, not end the turn. So both providers decline
rather than raise, and every failure mode in Morph funnels through one
helper:

```ruby
def summarize(history)
  key = api_key
  return decline("MORPH_API_KEY not configured") if key.nil? || key.empty?
  # ... POST ...
  return decline("HTTP #{status}") unless (200..299).cover?(status)
  # ... parse ...
  output.empty? ? decline("empty output") : output
rescue JSON::ParserError => e
  decline("invalid JSON: #{e.message}")
rescue StandardError => e
  decline("#{e.class}: #{e.message}")
end

def decline(message)
  warn "terret-morph: compact declined: #{message}"
  nil
end
```

A missing key, a non-2xx status, unparseable JSON, an unexpected response
shape, a non-string output, an empty output, a transport exception — all
decline to `nil` with a warn, and the compactor skips the boundary and
retries on the next overweight turn. The warn is not decoration: a seam
that silently returns `nil` is a capability that quietly stopped working,
and the log line is how an operator finds out.

**This discipline is specific to seams whose absence is survivable.** It is
not a house style to copy blindly onto every provider. A sole-provider seam
the harness cannot proceed without — the session store, say — must raise on
failure, because a `nil` there is data loss dressed as success. The rule is
the consumer's: read what the injecting service does with your return
value. The compactor treats `nil` as "skip"; a store's caller treats a lost
write as a bug. Match the discipline to what a failure actually means, and
say which one you chose in a comment, the way Morph's class doc says
"every failure declines to nil with a warn — compaction is an optimization".

## 5. An injectable transport, so tests need no network

Morph talks to a real HTTP API, and its unit tests touch no network. The
trick is one seam: the network call is read from the config hash, defaulting
to the real implementation, so a test injects a callable and asserts against
what the provider sent:

```ruby
def transport
  config[:transport] || method(:http_post)
end

def http_post(url, headers, body)
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.open_timeout = http.read_timeout = http.write_timeout = timeout
  response = http.post(uri.request_uri, body, headers)
  [response.code.to_i, response.body]
end
```

The transport's contract is `call(url, headers, body) => [status, body]` —
a plain callable, so `method(:http_post)` satisfies it and so does a lambda.
This is the same injectable-seam move the OpenRouter adapter uses for its
HTTP transport (`gems/terret-openrouter`): keep the one line that touches
the network behind a callable the config can replace, and the whole provider
becomes testable without mocking a library. Keeping it **out of the schema**
(§2) is deliberate — an injectable test seam is not an operator knob, and a
doctor listing it would invite someone to set it in YAML.

## 6. The test

With the transport injectable, a provider test is a fake transport, a boot,
and assertions on both what went over the wire and what came back. The
example below is **adapted from** `terret-morph`'s own test and abridged for
the page — the real file (`gems/terret-morph/test/summarizer_test.rb`) walks
six decline cases and richer wire assertions than the two shown here — but the
shape is the template:

```ruby
# frozen_string_literal: true
require "minitest/autorun"
require_relative "../lib/terret/morph"

class MorphSummarizerTest < Minitest::Test
  HISTORY = [
    Terret::LLM::Message.new(role: :user, parts: [Terret::LLM::Text.new(text: "deploy the thing")]),
    Terret::LLM::Message.new(role: :assistant, parts: [Terret::LLM::Text.new(text: "Deployed.")])
  ].freeze

  def boot(transport:, config: {})
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "summarizer", plugin: Terret::Morph::Summarizer,
        config: { api_key: "test-key", transport: transport }.merge(config) }
    ])
    loader.boot!
  end

  def test_happy_path_posts_the_wire_shape_and_returns_output
    seen = nil
    transport = lambda do |url, headers, body|
      seen = [url, headers, JSON.parse(body, symbolize_names: true)]
      [200, JSON.generate({ output: "compressed transcript" })]
    end
    ctx = boot(transport: transport)

    assert_equal "compressed transcript", ctx[:summarizer].summarize(HISTORY)
    url, headers, body = seen
    assert_equal "https://api.morphllm.com/v1/compact", url
    assert_equal "Bearer test-key", headers["Authorization"]
    assert_in_delta 0.4, body[:compression_ratio]
  end

  def test_every_failure_mode_declines_to_nil_with_a_warn
    cases = {
      "HTTP 500"          => ->(*) { [500, "boom"] },
      "invalid JSON"      => ->(*) { [200, "not json"] },
      "non-string output" => ->(*) { [200, JSON.generate({ output: 42 })] },
      "transport error"   => ->(*) { raise IOError, "connection reset" }
    }
    cases.each do |label, transport|
      ctx = boot(transport: transport)
      result = nil
      warned = capture_warn { result = ctx[:summarizer].summarize(HISTORY) }
      assert_nil result, "#{label} must decline to nil"
      assert_match(/terret-morph/, warned, "#{label} must warn")
    end
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
```

The shape generalizes to any provider: `boot` layers just the provider row
and injects the fake transport; the happy-path test asserts on what the
provider *sent* (the wire shape is a contract too, and this is where you
pin it); and a table-driven test walks every decline path, asserting `nil`
and a warn. A `MORPH_LIVE=1`-gated test in the same file exercises the real
API when a key is present and skips otherwise — the way to keep a real
integration honest without making the default test run depend on a network
or a secret.

## 7. What you have when this is done

A provider is a class claiming a seam key, injecting what it needs,
declaring a schema, and answering the seam's one method with the seam's
return discipline. Mounting it is choosing which single row claims the key;
the kernel's sole-provider refusal (§3) guarantees nobody else quietly does.
Testing it is a fake transport and a boot — no network, no secret, no mocks.

For the other two build-on-Terret recipes: `docs/cookbook/adding-a-tool.md`
grows the roster instead of swapping a seam, and
`docs/cookbook/adding-a-bundle.md` is how any of this reaches a running
Terret through a profile.
