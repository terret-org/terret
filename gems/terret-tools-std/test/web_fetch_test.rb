# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret/tools_std"

class WebFetchToolTest < Minitest::Test
  # Stands in for the network. The transport is the whole seam this tool
  # reaches the wire through, so a stub here proves every behaviour that
  # matters without a socket — and, more importantly, records what was NOT
  # fetched, which is the only way a refusal can be shown to have refused
  # rather than merely to have discarded the answer.
  class Recorder
    attr_reader :urls

    def initialize(routes = {}, default: [200, {}, "body"])
      @routes = routes
      @default = default
      @urls = []
    end

    def call(url)
      @urls << url
      @routes.fetch(url, @default)
    end
  end

  def boot(config: {})
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    # A network-free resolver default so a unit test never performs real DNS;
    # the SSRF tests override it with an explicit host -> address map. The
    # default answers a public (TEST-NET-3) address so the address floor admits
    # every host these other tests fetch.
    config = { resolver: ->(_host) { ["203.0.113.10"] } }.merge(config)
    loader.layer([
      { id: "tools", plugin: Terret::Tools::Registry },
      { id: "std_web_fetch", plugin: Terret::ToolsStd::WebFetch, config: config }
    ])
    [loader.boot!, loader]
  end

  # allow: ["*"] is the permissive floor most of these tests want; policy has
  # tests of its own below and does not need re-proving in every fetch case.
  def boot_open(extra = {})
    recorder = extra.delete(:recorder) || Recorder.new
    ctx, loader = boot(config: { allow: ["*"], transport: recorder }.merge(extra))
    [ctx, loader, recorder]
  end

  # Every call goes through the pipeline, never straight at a handler: policy
  # listens on tools/pre_execute, so a tool proven only by calling its block
  # is a tool proven outside the thing that governs it.
  def call(ctx, name = "WebFetch", **args)
    ctx[:tools].execute(
      Terret::Tools::Call.new(id: "c1", name: name, args: args, session_id: "s1"), ctx: ctx
    )
  end

  # -- fetching --------------------------------------------------------------

  def test_a_fetch_returns_the_body_the_transport_handed_back
    ctx, _loader, recorder = boot_open(recorder: Recorder.new({ "https://example.com/x" => [200, {}, "hello"] }))
    result = call(ctx, url: "https://example.com/x")

    assert_nil result.error
    assert_equal "hello", result.content, "a clean 200 renders the body and nothing else"
    assert_equal ["https://example.com/x"], recorder.urls
  end

  def test_an_empty_body_says_so_rather_than_rendering_nothing
    ctx, = boot_open(recorder: Recorder.new(default: [200, {}, ""]))
    assert_equal "(no content)", call(ctx, url: "https://example.com/").content
  end

  # A model that has written Claude Code's WebFetch before writes a `prompt`
  # too. This tool hands back the page whole instead of running a model over
  # it, so there is nothing for a prompt to do — but an unknown keyword would
  # cost a turn to a crash, which is a worse answer than ignoring it.
  def test_a_prompt_argument_does_not_crash_the_call
    ctx, = boot_open(recorder: Recorder.new(default: [200, {}, "hello"]))
    result = call(ctx, url: "https://example.com/", prompt: "summarize this")

    assert_nil result.error
    assert_equal "hello", result.content
  end

  # -- the tool's own cap ----------------------------------------------------

  def test_a_body_past_max_bytes_is_truncated_with_a_marker_line
    ctx, = boot_open(max_bytes: 200, recorder: Recorder.new(default: [200, {}, "a" * 1000]))
    result = call(ctx, url: "https://example.com/")

    assert_nil result.error
    assert result.content.start_with?("a" * 200)
    assert_match(/kept the first 200 bytes of rendered text and dropped 800 more/, result.content)
    assert_match(/^--- terret ---$/, result.content)
  end

  def test_the_cap_defaults_to_100_000_bytes
    ctx, = boot_open(recorder: Recorder.new(default: [200, {}, "a" * 100_010]))
    result = call(ctx, url: "https://example.com/")
    assert_match(/kept the first 100000 bytes of rendered text and dropped 10 more/, result.content)
  end

  # A cut at a byte offset can split a character in half, and those halves are
  # bytes this tool manufactured — the server never sent them, and a durable
  # append JSON-encodes the payload, so a manufactured half raises a layer away
  # from the code that broke it.
  def test_truncation_cuts_on_a_character_boundary
    ctx, = boot_open(max_bytes: 11, recorder: Recorder.new(default: [200, {}, "é" * 20]))
    result = call(ctx, url: "https://example.com/")

    assert_nil result.error
    assert result.content.valid_encoding?, "a split character would be bytes nobody sent"
    assert_equal "é" * 5, result.content.lines.first.chomp, "the 11th byte is half a character"
    assert_match(/kept the first 10 bytes of rendered text and dropped 30 more/, result.content)
  end

  def test_a_swapped_row_governs_the_very_next_call
    recorder = Recorder.new(default: [200, {}, "a" * 1000])
    ctx, loader, = boot_open(max_bytes: 200, recorder: recorder)
    loader.reconfigure!("std_web_fetch", { allow: ["*"], transport: recorder, max_bytes: 50 })

    result = call(ctx, url: "https://example.com/")
    assert_match(/kept the first 50 bytes of rendered text and dropped 950 more/, result.content)
  end

  def test_a_non_positive_max_bytes_cannot_crash_every_call
    ctx, = boot_open(max_bytes: -1, recorder: Recorder.new(default: [200, {}, "hello"]))
    result = call(ctx, url: "https://example.com/")

    assert_nil result.error, "a nonsense cap degrades to showing nothing; it does not crash"
    assert_match(/kept the first 0 bytes/, result.content)
  end

  # -- bytes a server sent that are not text ---------------------------------

  # A server's body is whatever bytes it felt like sending, and the session log
  # REFUSES invalid UTF-8 at the durable append boundary. Scrubbing is this
  # layer's job, and the proof is the append itself: `valid_encoding?` alone
  # would pass for a binary string that `normalize_payload` still rejects.
  def test_a_server_sending_bytes_that_are_not_text_still_produces_a_storable_result
    body = (+"before\xff\xfeafter").force_encoding(Encoding::ASCII_8BIT)
    ctx, = boot_open(recorder: Recorder.new(default: [200, {}, body]))
    result = call(ctx, url: "https://example.com/")

    assert_nil result.error
    assert_equal Encoding::UTF_8, result.content.encoding
    assert result.content.valid_encoding?, "the tool's result must be storable text"

    store = Hames::Loader.new
    store.layer([{ id: "session_store", plugin: Terret::Store::Memory },
                 { id: "sessions", plugin: Terret::Sessions }])
    sctx = store.boot!
    session = sctx[:sessions].create
    sctx[:sessions].append(session.id, "tool/result",
                           { id: result.id, content: result.content, error: result.error })
    assert_equal result.content, sctx[:sessions].fetch(session.id).events.last.payload[:content]
  end

  # -- what the server answered ----------------------------------------------

  def test_a_non_2xx_status_is_reported_rather_than_passed_off_as_success
    ctx, = boot_open(recorder: Recorder.new(default: [404, {}, "Not Found"]))
    result = call(ctx, url: "https://example.com/gone")

    assert_nil result.error, "a 404 is an answer the server gave; that is a result, not a tool error"
    assert result.content.start_with?("Not Found")
    assert_match(/^HTTP 404$/, result.content)
  end

  def test_a_2xx_status_is_not_announced
    ctx, = boot_open(recorder: Recorder.new(default: [204, {}, "ok"]))
    assert_equal "ok", call(ctx, url: "https://example.com/").content
  end

  # A 3xx with nothing to follow is not a redirect; it is a status, and gets
  # reported like any other rather than looping or crashing.
  def test_a_redirect_with_no_location_is_reported_rather_than_followed
    ctx, _loader, recorder = boot_open(recorder: Recorder.new(default: [302, {}, "moved"]))
    result = call(ctx, url: "https://example.com/")

    assert_nil result.error
    assert_match(/^HTTP 302$/, result.content)
    assert_equal 1, recorder.urls.length
  end

  # -- the domain policy -----------------------------------------------------

  def test_an_empty_allow_list_denies_every_domain_and_fetches_nothing
    recorder = Recorder.new
    ctx, = boot(config: { transport: recorder })
    result = call(ctx, url: "https://example.com/")

    assert_nil result.content
    assert_match(/not on the WebFetch domain allow list/, result.error)
    assert_empty recorder.urls, "a refused domain must not be fetched and then discarded"
  end

  def test_a_host_outside_the_allow_list_is_refused
    recorder = Recorder.new
    ctx, = boot(config: { allow: ["*.example.com"], transport: recorder })
    result = call(ctx, url: "https://elsewhere.test/")

    assert_nil result.content
    assert_empty recorder.urls
  end

  def test_an_allowed_host_matches_by_glob
    recorder = Recorder.new(default: [200, {}, "docs"])
    ctx, = boot(config: { allow: ["*.example.com"], transport: recorder })

    assert_equal "docs", call(ctx, url: "https://docs.example.com/x").content
  end

  def test_deny_wins_over_allow
    recorder = Recorder.new
    ctx, = boot(config: { allow: ["*"], deny: ["evil.example"], transport: recorder })
    result = call(ctx, url: "https://evil.example/x")

    assert_nil result.content
    assert_match(/denied/, result.error)
    assert_empty recorder.urls
  end

  # DNS hostnames are case-insensitive; `File.fnmatch` is not. Matching a raw
  # host string would let `EVIL.EXAMPLE` walk straight past a deny rule spelled
  # in lowercase — a fail-OPEN hole, which is the one direction this policy is
  # not allowed to fail in.
  def test_an_uppercase_host_cannot_slip_a_deny_rule
    recorder = Recorder.new
    ctx, = boot(config: { allow: ["*"], deny: ["evil.example"], transport: recorder })
    result = call(ctx, url: "https://EVIL.EXAMPLE/x")

    assert_nil result.content
    assert_empty recorder.urls
  end

  # The other half of the same rule: an allow list spelled in lowercase still
  # has to admit the host a model typed in caps, or the fix above would just
  # trade a fail-open hole for a tool that refuses valid URLs.
  def test_an_uppercase_host_still_matches_a_lowercase_allow_rule
    recorder = Recorder.new(default: [200, {}, "ok"])
    ctx, = boot(config: { allow: ["example.com"], transport: recorder })

    assert_equal "ok", call(ctx, url: "https://EXAMPLE.COM/x").content
  end

  # Documented behaviour, asserted so it cannot drift silently: the policy is a
  # HOSTNAME policy. A port is not part of what it matches.
  def test_the_policy_matches_the_host_alone_so_a_port_rides_along
    recorder = Recorder.new(default: [200, {}, "ok"])
    ctx, = boot(config: { allow: ["example.com"], transport: recorder })

    assert_equal "ok", call(ctx, url: "https://example.com:8443/x").content
  end

  def test_a_refusal_renders_message_only
    ctx, = boot(config: { transport: Recorder.new })
    result = call(ctx, url: "https://example.com/")

    refute_match(/Terret|Failure|URI::/, result.error, "a Failure renders message-only")
  end

  # -- SSRF floor: loopback and link-local --------------------------------
  #
  # WebFetch egresses HOST-side via Net::HTTP, so `network: none` on the
  # sandbox does not constrain it. An allowlisted hostname resolving to
  # loopback or the cloud-metadata link-local address would otherwise reach
  # host-local and instance-credential endpoints; the address is checked on the
  # model's URL and on every redirect hop before anything is fetched.

  def test_a_host_resolving_to_loopback_is_refused_and_nothing_is_fetched
    recorder = Recorder.new
    ctx, = boot(config: { allow: ["*"], transport: recorder,
                          resolver: ->(_h) { ["127.0.0.1"] } })
    result = call(ctx, url: "https://sneaky.example/x")

    assert_nil result.content
    assert_match(/loopback or link-local/, result.error)
    assert_empty recorder.urls, "a host resolving to loopback must never reach the transport"
  end

  def test_a_host_resolving_to_the_cloud_metadata_address_is_refused
    recorder = Recorder.new
    ctx, = boot(config: { allow: ["*"], transport: recorder,
                          resolver: ->(_h) { ["169.254.169.254"] } })
    result = call(ctx, url: "https://metadata.example/latest/meta-data/")

    assert_nil result.content
    assert_match(/loopback or link-local/, result.error)
    assert_empty recorder.urls
  end

  # The refusal fires even when only ONE of several resolved addresses is
  # forbidden: a rebinding-adjacent record that answers both a public and a
  # link-local address must not slip the public one through.
  def test_a_host_resolving_to_a_mix_including_link_local_is_refused
    recorder = Recorder.new
    ctx, = boot(config: { allow: ["*"], transport: recorder,
                          resolver: ->(_h) { ["203.0.113.10", "169.254.169.254"] } })
    result = call(ctx, url: "https://mixed.example/x")

    assert_nil result.content
    assert_match(/loopback or link-local/, result.error)
    assert_empty recorder.urls
  end

  def test_a_redirect_to_a_link_local_host_is_refused_mid_chain
    recorder = Recorder.new({
      "https://entry.example/" => [302, { "location" => "https://internal.example/" }, "moved"]
    }, default: [200, {}, "SHOULD NOT REACH"])
    resolver = ->(host) { host == "internal.example" ? ["169.254.169.254"] : ["203.0.113.10"] }
    ctx, = boot(config: { allow: ["*"], transport: recorder, resolver: resolver })
    result = call(ctx, url: "https://entry.example/")

    assert_nil result.content
    assert_match(/loopback or link-local/, result.error)
    assert_equal ["https://entry.example/"], recorder.urls,
                 "the redirect target must be refused before it is fetched"
  end

  def test_a_host_resolving_to_a_public_address_is_allowed
    recorder = Recorder.new(default: [200, {}, "ok"])
    ctx, = boot(config: { allow: ["*"], transport: recorder,
                          resolver: ->(_h) { ["203.0.113.10"] } })

    assert_equal "ok", call(ctx, url: "https://public.example/x").content
    assert_equal ["https://public.example/x"], recorder.urls
  end

  # Private ranges are a documented M8 config knob, deliberately NOT part of
  # this floor: a deployment may legitimately fetch internal services.
  def test_a_private_range_address_is_not_blocked_by_the_floor
    recorder = Recorder.new(default: [200, {}, "ok"])
    ctx, = boot(config: { allow: ["*"], transport: recorder,
                          resolver: ->(_h) { ["10.0.0.5"] } })

    assert_equal "ok", call(ctx, url: "https://intranet.example/x").content
  end

  # -- what a URL may be -----------------------------------------------------

  def test_a_non_http_scheme_is_refused
    recorder = Recorder.new
    ctx, = boot(config: { allow: ["*"], transport: recorder })

    ["file:///etc/passwd", "ftp://example.com/x", "gopher://example.com/"].each do |url|
      result = call(ctx, url: url)
      assert_nil result.content, url
      assert_match(/http/, result.error, url)
    end
    assert_empty recorder.urls, "a scheme this tool does not speak must never reach the transport"
  end

  # A URL carrying credentials is a credential heading for the durable session
  # log by way of the tool's own arguments. Refused rather than stripped:
  # stripping would fetch something the caller did not ask for.
  def test_a_url_carrying_credentials_is_refused
    recorder = Recorder.new
    ctx, = boot(config: { allow: ["*"], transport: recorder })
    result = call(ctx, url: "https://user:hunter2@example.com/x")

    assert_nil result.content
    assert_match(/credential/i, result.error)
    refute_match(/hunter2/, result.error, "the refusal must not echo the secret back into the log")
    assert_empty recorder.urls
  end

  def test_a_malformed_url_refuses_cleanly_rather_than_leaking_a_ruby_class
    ctx, = boot(config: { allow: ["*"], transport: Recorder.new })
    result = call(ctx, url: "ht tp://nope")

    assert_nil result.content
    assert_match(/could not be parsed/, result.error)
    refute_match(/URI::InvalidURIError/, result.error)
  end

  def test_a_url_that_is_not_a_string_is_refused
    ctx, = boot(config: { allow: ["*"], transport: Recorder.new })
    [nil, 42, ["https://example.com"]].each do |url|
      result = call(ctx, url: url)
      assert_nil result.content, url.inspect
      refute_match(/ArgumentError|NoMethodError/, result.error, url.inspect)
    end
  end

  # `File.fnmatch("*", "")` is true, so a hostless URL would sail through a
  # permissive allow list into a transport with nothing to connect to.
  def test_a_url_with_no_host_is_refused
    recorder = Recorder.new
    ctx, = boot(config: { allow: ["*"], transport: recorder })

    ["https:///path", "https://"].each do |url|
      assert_nil call(ctx, url: url).content, url
    end
    assert_empty recorder.urls
  end

  # -- redirects -------------------------------------------------------------

  def test_a_redirect_is_followed_and_the_final_body_returned
    routes = { "https://example.com/a" => [301, { "location" => "https://example.com/b" }, ""],
               "https://example.com/b" => [200, {}, "arrived"] }
    ctx, _loader, recorder = boot_open(recorder: Recorder.new(routes))
    result = call(ctx, url: "https://example.com/a")

    assert_nil result.error
    assert result.content.start_with?("arrived")
    assert_match(%r{followed 1 redirect to https://example\.com/b}, result.content)
    assert_equal ["https://example.com/a", "https://example.com/b"], recorder.urls
  end

  # Response headers arrive however the server spelled them; HTTP header names
  # are case-insensitive and a tool that only looked for one spelling would
  # silently stop following redirects for half the web.
  def test_a_location_header_is_found_whatever_its_case
    routes = { "https://example.com/a" => [302, { "Location" => "https://example.com/b" }, ""],
               "https://example.com/b" => [200, {}, "arrived"] }
    ctx, = boot_open(recorder: Recorder.new(routes))

    assert_match(/arrived/, call(ctx, url: "https://example.com/a").content)
  end

  def test_a_relative_location_is_resolved_against_the_url_it_came_from
    routes = { "https://example.com/one/two" => [302, { "location" => "../three" }, ""],
               "https://example.com/three" => [200, {}, "arrived"] }
    ctx, _loader, recorder = boot_open(recorder: Recorder.new(routes))

    assert_match(/arrived/, call(ctx, url: "https://example.com/one/two").content)
    assert_equal "https://example.com/three", recorder.urls.last
  end

  # The reason every hop is re-checked: an allowed host can hand out a Location
  # pointing anywhere, so a policy applied only to the URL a model typed is a
  # policy any allowed server can launder a fetch through.
  def test_a_redirect_into_a_denied_host_is_refused_mid_chain
    routes = { "https://good.example/a" => [301, { "location" => "https://evil.example/x" }, ""] }
    recorder = Recorder.new(routes)
    ctx, = boot(config: { allow: ["*"], deny: ["evil.example"], transport: recorder })
    result = call(ctx, url: "https://good.example/a")

    assert_nil result.content
    assert_match(/denied/, result.error)
    assert_equal ["https://good.example/a"], recorder.urls, "the denied hop must never be fetched"
  end

  def test_a_redirect_out_of_the_allow_list_is_refused_mid_chain
    routes = { "https://docs.example.com/a" => [301, { "location" => "https://elsewhere.test/x" }, ""] }
    recorder = Recorder.new(routes)
    ctx, = boot(config: { allow: ["*.example.com"], transport: recorder })

    assert_nil call(ctx, url: "https://docs.example.com/a").content
    assert_equal ["https://docs.example.com/a"], recorder.urls
  end

  def test_a_redirect_to_a_non_http_scheme_is_refused
    routes = { "https://example.com/a" => [301, { "location" => "file:///etc/passwd" }, ""] }
    recorder = Recorder.new(routes)
    ctx, = boot(config: { allow: ["*"], transport: recorder })

    assert_nil call(ctx, url: "https://example.com/a").content
    assert_equal ["https://example.com/a"], recorder.urls
  end

  def test_five_redirects_are_followed
    routes = (0...5).to_h do |i|
      ["https://example.com/#{i}", [301, { "location" => "https://example.com/#{i + 1}" }, ""]]
    end
    routes["https://example.com/5"] = [200, {}, "arrived"]
    ctx, _loader, recorder = boot_open(recorder: Recorder.new(routes))
    result = call(ctx, url: "https://example.com/0")

    assert_nil result.error
    assert_match(/arrived/, result.content)
    assert_match(%r{followed 5 redirects to https://example\.com/5}, result.content)
    assert_equal 6, recorder.urls.length
  end

  def test_a_sixth_redirect_is_refused_rather_than_followed
    routes = (0..9).to_h do |i|
      ["https://example.com/#{i}", [301, { "location" => "https://example.com/#{i + 1}" }, ""]]
    end
    recorder = Recorder.new(routes)
    ctx, = boot(config: { allow: ["*"], transport: recorder })
    result = call(ctx, url: "https://example.com/0")

    assert_nil result.content
    assert_match(/more than 5 redirects/, result.error)
    assert_equal 6, recorder.urls.length, "the cap stops the chain; it does not keep walking it"
  end

  # A server that redirects to itself is the cheapest denial of service there
  # is, and the cap is what makes it terminate.
  def test_a_redirect_loop_terminates
    routes = { "https://example.com/a" => [301, { "location" => "https://example.com/a" }, ""] }
    recorder = Recorder.new(routes)
    ctx, = boot(config: { allow: ["*"], transport: recorder })

    assert_nil call(ctx, url: "https://example.com/a").content
    assert_equal 6, recorder.urls.length
  end

  # -- what the definition claims --------------------------------------------

  def test_web_fetch_declares_what_policy_reads
    ctx, = boot_open
    d = ctx[:tools].fetch("WebFetch")

    refute d.mutating, "fetching a page changes nothing on this side"
    assert_equal :policy, d.approval
    assert_equal :serial, d.concurrency
    assert_equal "string", d.params[:properties][:url][:type]
    assert_equal ["url"], d.params[:required]
  end

  def test_the_registration_dies_with_the_row_that_made_it
    ctx, loader, = boot_open
    refute_empty ctx[:tools].schemas

    loader.unload!("std_web_fetch")
    assert_empty ctx[:tools].schemas, "a tool registered by a plugin row must not outlive the row"
  end

  # -- the default transport -------------------------------------------------

  # The net/http transport cannot be exercised without a network, so what is
  # provable here is its configuration. timeout=0 must not mean "no timeout"
  # (terret-morph's lesson): anything non-positive floors back to the default.
  def test_the_default_transport_floors_a_nonsense_timeout
    ctx, = boot(config: { allow: ["*"] })
    service = ctx[:tools_std_web_fetch]

    assert_in_delta 30.0, service.send(:timeout)
    ctx, = boot(config: { allow: ["*"], timeout: 0 })
    assert_in_delta 30.0, ctx[:tools_std_web_fetch].send(:timeout)
    ctx, = boot(config: { allow: ["*"], timeout: -5 })
    assert_in_delta 30.0, ctx[:tools_std_web_fetch].send(:timeout)
    ctx, = boot(config: { allow: ["*"], timeout: 2.5 })
    assert_in_delta 2.5, ctx[:tools_std_web_fetch].send(:timeout)
  end

  def test_the_default_transport_carries_the_configured_timeouts_onto_the_connection
    ctx, = boot(config: { allow: ["*"], timeout: 7 })
    http = ctx[:tools_std_web_fetch].send(:connection, URI("https://example.com/x"))

    assert_in_delta 7.0, http.open_timeout
    assert_in_delta 7.0, http.read_timeout
    assert_in_delta 7.0, http.write_timeout
    assert http.use_ssl?, "an https URL must not be fetched in the clear"
  end

  # A deployment that wires a transport of the wrong shape has a configuration
  # bug, and the failure mode without a guard is the worst kind: `[status,
  # body]` destructures into a headers-shaped body and a nil body, so every
  # fetch quietly answers "(no content)" and nothing says why.
  def test_a_transport_of_the_wrong_shape_says_so_rather_than_rendering_nothing
    ctx, = boot(config: { allow: ["*"], transport: ->(_url) { [200, "body"] } })
    result = call(ctx, url: "https://example.com/")

    assert_nil result.content
    assert_match(/must answer \[status, headers, body\]/, result.error)
    assert_match(/TypeError/, result.error, "a wiring bug keeps its class; it is the diagnosis")
  end

  # Yields chunks the way Net::HTTPResponse#read_body does, so the default
  # transport's buffering is provable without a socket, and records how much of
  # itself was consumed.
  class ChunkedBody
    attr_reader :yielded

    def initialize(chunks)
      @chunks = chunks
      @yielded = 0
    end

    def read_body
      @chunks.each do |chunk|
        @yielded += 1
        yield chunk
      end
    end
  end

  # The bug the live lane found and the stubbed lanes could not: `break`-ing
  # out of Net::HTTP's read_body to stop at the cap leaves the socket inside
  # the response body, and Net::HTTP then reads the rest of the payload as a
  # chunk-size line — "wrong chunk size line" on roughly every other chunked,
  # gzipped page. The stream has to be drained; only what is KEPT is bounded.
  def test_the_default_transport_bounds_what_it_keeps_and_still_drains_the_stream
    ctx, = boot(config: { allow: ["*"], max_bytes: 10 })
    # A binary chunk among them: the buffer has to be binary, because
    # appending a high byte to a UTF-8 buffer raises on the spot.
    body = ChunkedBody.new(["a" * 8, "bbbbbbb\xFF".b, "c" * 8])
    kept = ctx[:tools_std_web_fetch].send(:read_bounded, body)

    assert_equal 3, body.yielded, "the stream is drained to its end, never abandoned mid-body"
    assert_equal 16, kept.bytesize, "the chunk that crosses the cap is taken; the next one is not"
  end

  # Env-gated and deliberately out of both default lanes: the only thing that
  # proves the stdlib transport really reaches the wire, run by hand when
  # someone is changing it.
  def test_the_default_transport_really_fetches
    skip "set TERRET_WEBFETCH_LIVE=1 to run the live fetch" unless ENV["TERRET_WEBFETCH_LIVE"] == "1"

    ctx, = boot(config: { allow: ["example.com"] })
    result = call(ctx, url: "https://example.com/")

    assert_nil result.error
    assert_match(/Example Domain/, result.content)
  end
end
