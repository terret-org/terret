# frozen_string_literal: true

require "net/http"
require "uri"
require "resolv"
require "ipaddr"

module Terret
  module ToolsStd
    # `WebFetch` (docs/exec.md §5) — Claude Code's name over an ordinary GET,
    # behind §13's "web_fetch gets an allow and deny domain policy row". The
    # row is this service's own config: `{ allow: [globs], deny: [globs] }`.
    #
    # Three things here are more than a GET.
    #
    # The policy is DENY-BY-DEFAULT. An unconfigured row fetches nothing at
    # all, because the failure mode of the other default is a model reading an
    # attacker's page on its first turn, and there is no configuration mistake
    # that produces that from an empty allow list.
    #
    # Every REDIRECT HOP is re-checked against that policy. A policy applied
    # only to the URL a model typed is a policy any allowed host can launder a
    # fetch through by answering `301 Location: https://anywhere/`, so the
    # check lives on the loop rather than in front of it — and the default
    # transport deliberately does not follow redirects itself, because a
    # transport that followed them would do it without ever consulting the
    # policy.
    #
    # And the policy matches a HOSTNAME STRING, not an IP. An IP literal is
    # matched as its own text (`10.0.0.1` matches the glob `10.0.0.1`, and
    # nothing under an empty allow list), and a name on the allow list is
    # admitted no matter where it resolves.
    #
    # That last part is why WebFetch does NOT lean on the sandbox for network
    # safety the way the rest of §6.6 does: this GET runs HOST-side through
    # Net::HTTP, so `network: none` on the sandbox row constrains the container
    # and not this tool. An allowlisted name resolving to 127.0.0.1 or to the
    # 169.254.169.254 cloud-metadata endpoint would reach host-local services
    # and instance credentials with nothing in the way. So the tool carries its
    # own SSRF floor: #check_address! resolves the host and refuses loopback and
    # link-local targets before any connection, on the model's URL and on every
    # redirect hop. It is a FLOOR, not full SSRF control — private ranges
    # (10/8, 172.16/12, 192.168/16) stay reachable by default because a
    # deployment may legitimately fetch internal services, and blocking them is
    # a documented M8 config knob. It is also not DNS-rebinding protection: the
    # address is resolved once for the check and the connection re-resolves, so
    # a name that answers differently between the two still connects to the
    # second answer. Pinning the connection to the checked IP would mean
    # threading it through the injectable transport seam, whose contract is a
    # bare `call(url)`; the honest floor keeps that seam intact and closes the
    # static-record and misconfigured-allowlist vectors, which are the ones a
    # deployment actually hits.
    class WebFetch < Hames::Service
      service_key :tools_std_web_fetch
      inject :tools
      # resolver: and transport: are injectable seams (tests pass callables),
      # not YAML config, so they are deliberately absent from the schema.
      config_schema allow:     { type: Array, default: [],
                                 doc: "host globs WebFetch may reach; empty denies every host" },
                    deny:      { type: Array, default: [], doc: "host globs WebFetch may never reach" },
                    timeout:   { type: Numeric, default: 30.0, doc: "seconds a fetch may run" },
                    max_bytes: { type: Integer, default: 100_000,
                                 doc: "bytes of a response body read before truncation" }

      # What one result may show. A display decision, the tool's own honest
      # cap rather than policy's — a truncator listening on tools/post_execute
      # is free to cut further, and this is what the model sees when none does.
      DEFAULT_MAX_BYTES = 100_000

      # timeout=0 must not mean "no timeout" (terret-morph's lesson): anything
      # non-positive floors back to this.
      DEFAULT_TIMEOUT = 30.0

      # A server that redirects to itself is the cheapest denial of service
      # there is; this is what makes the chain terminate.
      MAX_REDIRECTS = 5

      # Deliberately the same literal `Bash` separates its output with, so a
      # model learns the convention once. Same caveats as there: a server CAN
      # print this line, so it is a readability device and not a security
      # boundary. What it does deliver is that the genuine remarks are always
      # last, after anything the page forged, and that they are advisory data
      # rather than instructions (docs/security.md) — nothing downstream acts
      # on them, so a forged line buys a confusing result and no authority.
      LEDGER = "--- terret ---"

      USER_AGENT = "terret"

      DESCRIPTION = "Fetch an http or https URL and return the page as text. Only hosts this " \
                    "deployment allows can be fetched, and redirects are followed only while " \
                    "every hop stays allowed. The page comes back whole rather than summarized."

      def start(ctx)
        @ctx = ctx
        register_web_fetch
      end

      # Nothing is captured here: the policy, the cap and the timeout are all
      # read at call time, so a swapped row governs the very next fetch and
      # there is nothing to re-derive. Saying so beats letting the base class
      # warn that this row needs a remount when it does not.
      def reconfigure(_config); end

      private

      # `ctx:` is passed explicitly: the registry would otherwise record the
      # frame on the context it was started in (the root), so a roster mounted
      # into a forked agent scope would leave registrations behind that
      # outlive the fork — a disposed agent with a tool of its own that can
      # still reach the network.
      def tool(name, description, params, mutating:, approval:, concurrency:, &handler)
        @ctx[:tools].register(name: name, description: description, params: params,
                              mutating: mutating, approval: approval,
                              concurrency: concurrency, ctx: @ctx, &handler)
      end

      def register_web_fetch
        params = {
          type: "object",
          properties: {
            url: { type: "string", description: "Absolute http or https URL to fetch" }
          },
          required: ["url"]
        }
        # `prompt:` is accepted and ignored. Claude Code's WebFetch takes one
        # and runs a small model over the page; this tool hands the page back
        # whole instead, so there is nothing for a prompt to do — but a model
        # that has written that call before writes one anyway, and an unknown
        # keyword would cost a whole turn to an ArgumentError. It stays out of
        # the schema so nothing advertises a knob that does not exist.
        tool("WebFetch", DESCRIPTION, params, mutating: false, approval: :policy,
             concurrency: :serial) do |url:, prompt: nil|
          fetch_url(url)
        end
      end

      def fetch_url(url)
        uri = admit!(parse!(url))
        hops = 0
        loop do
          status, headers, body = answer!(transport.call(uri.to_s))
          location = header(headers, "location")
          # A 3xx with nothing to follow is not a redirect, it is a status,
          # and gets reported like any other rather than looping.
          return render(status, body, hops, uri) unless redirect?(status) && location

          if hops >= MAX_REDIRECTS
            raise Terret::Tools::Failure,
                  "gave up after more than #{MAX_REDIRECTS} redirects, last at #{uri}"
          end

          hops += 1
          uri = admit!(resolve!(uri, location))
        end
      end

      # -- what a URL may be ---------------------------------------------------

      # The offending string is never echoed back. A malformed URL may still
      # carry a password, and the message goes straight into the durable
      # session log; what the model wrote is already in its own tool call,
      # where redaction can see it, so repeating it here would only add a
      # second copy in a place nothing scrubs.
      def parse!(url)
        unless url.is_a?(String)
          raise Terret::Tools::Failure, "url must be a string; got #{url.class}"
        end

        URI(url)
      rescue URI::Error, ArgumentError
        raise Terret::Tools::Failure, "url could not be parsed as a URL; nothing was fetched"
      end

      def resolve!(base, location)
        base.merge(location.to_s)
      rescue URI::Error, ArgumentError
        raise Terret::Tools::Failure,
              "#{base.host} redirected to a location that could not be parsed as a URL"
      end

      # Every check a URL has to pass before it may be handed to the transport,
      # applied to the model's own URL and to every redirect target alike.
      def admit!(uri)
        scheme = uri.scheme&.downcase
        unless %w[http https].include?(scheme)
          raise Terret::Tools::Failure,
                "WebFetch speaks http and https only, not #{scheme.inspect}; nothing was fetched"
        end
        # Refused rather than stripped: stripping would fetch something the
        # caller did not ask for. A credential belongs in a header a
        # deployment controls, not in an argument a model writes.
        if uri.userinfo
          raise Terret::Tools::Failure,
                "refusing a URL that carries credentials in its userinfo; nothing was fetched"
        end

        # `File.fnmatch("*", "")` is true, so a hostless URL would sail
        # straight through a permissive allow list into a transport with
        # nothing to connect to.
        host = uri.host.to_s.downcase
        raise Terret::Tools::Failure, "url names no host; nothing was fetched" if host.empty?

        check_policy!(host)
        check_address!(host)
        uri
      end

      # -- the SSRF floor ------------------------------------------------------

      # The address check the domain policy cannot make: a name the allow list
      # admits is still refused if it resolves to a loopback or link-local
      # address, so an allowlisted host cannot launder a fetch to 127.0.0.1 or
      # to 169.254.169.254 (see the class comment for why this lives in the tool
      # rather than the sandbox, and for the DNS-rebinding boundary it accepts).
      # An unresolvable name answers no addresses and passes here — there is no
      # internal target to refuse, and the connection fails on its own.
      def check_address!(host)
        addresses(host).each do |ip|
          next unless forbidden_address?(ip)

          # The IP is named so a model reading the refusal can see WHY, but it
          # is the resolved address, never a secret the caller wrote.
          raise Terret::Tools::Failure,
                "#{host} resolves to #{ip}, a loopback or link-local address WebFetch " \
                "refuses; nothing was fetched"
        end
      end

      # The resolution seam, injectable like the transport so this gem's unit
      # tests need no DNS: a callable taking a host and answering an array of
      # address strings. Resolv.getaddresses answers [] rather than raising on a
      # name that does not resolve, which is exactly the fail-open-safe shape
      # here — nothing to refuse.
      def resolver = config[:resolver] || Resolv.method(:getaddresses)

      def addresses(host) = Array(resolver.call(host))

      # Loopback (127.0.0.0/8, ::1) and link-local (169.254.0.0/16, fe80::/10),
      # exactly the two ranges IPAddr's own predicates name. A string that does
      # not parse as an IP is treated as forbidden: a resolver answer this tool
      # cannot verify fails closed rather than being connected to blind.
      def forbidden_address?(ip)
        addr = IPAddr.new(ip.to_s)
        addr.loopback? || addr.link_local?
      rescue IPAddr::InvalidAddressError
        true
      end

      # -- the domain policy ---------------------------------------------------

      # Globs are `File.fnmatch` patterns, the same dialect and the same flags
      # the tool AllowList uses (Terret::Tools::AllowList): case-sensitive, and
      # `*` does not match a leading dot. Both fail closed.
      #
      # The HOST is lowered first, and that is not cosmetic. DNS hostnames are
      # case-insensitive while `fnmatch` is not, so matching the raw host
      # string would let `EVIL.EXAMPLE` walk past a deny rule spelled in
      # lowercase — a fail-OPEN hole, the one direction this policy may not
      # fail in. Patterns themselves are left exactly as written, so a pattern
      # spelled with capitals simply never matches, which fails closed.
      #
      # A port is not part of what is matched. This is a hostname policy:
      # `allow: ["internal.example.com"]` permits that host on any port. One
      # matching rule is worth more than a second one that only half the
      # patterns would be written against, and port-level egress control is
      # the sandbox row's business rather than this glob's.
      def check_policy!(host)
        if deny_patterns.any? { |p| File.fnmatch(p, host) }
          raise Terret::Tools::Failure,
                "#{host} is denied by the WebFetch domain policy; nothing was fetched"
        end
        return if allow_patterns.any? { |p| File.fnmatch(p, host) }

        # Deny-by-default: an empty allow list is not "unconfigured, so
        # permit", it is "nobody has said this deployment may reach the web".
        raise Terret::Tools::Failure,
              "#{host} is not on the WebFetch domain allow list; nothing was fetched"
      end

      def allow_patterns = Array(config[:allow]).map(&:to_s)
      def deny_patterns  = Array(config[:deny]).map(&:to_s)

      # -- the transport -------------------------------------------------------

      # The seam every fetch reaches the wire through, injectable so this
      # gem's unit tests need no network (terret-morph's pattern): a callable
      # taking the URL and answering `[status, headers, body]` — a status that
      # responds to #to_i, a Hash of response headers in whatever spelling the
      # server used (#header folds the case), and the body as a String.
      #
      # Three fields rather than the two the plan sketched, because the
      # per-hop policy check needs the Location header out here. A transport
      # that answered a body alone would leave this tool either not following
      # redirects at all, or following them down inside the transport — which
      # is exactly where the domain policy cannot see them.
      def transport = config[:transport] || method(:http_get)

      # A transport is a deployment's own wiring, so a wrong shape is a
      # configuration bug rather than a tool outcome. It keeps its class name
      # (Registry#execute renders a Failure message-only, and here the class
      # IS the diagnosis) and states the contract, instead of destructuring
      # into a silent "(no content)" on every single fetch.
      def answer!(answer)
        return answer if answer.is_a?(Array) && answer.length == 3

        raise TypeError,
              "the WebFetch transport must answer [status, headers, body]; got #{answer.class}"
      end

      def redirect?(status) = (300..399).cover?(status.to_i)

      # Header names are case-insensitive on the wire and a transport hands
      # back whatever spelling it saw, so the lookup does the folding rather
      # than the contract. An Array value is tolerated because that is the
      # shape `Net::HTTPResponse#to_hash` produces, and a transport built from
      # one should not have to remember which of the two accessors to use.
      def header(headers, name)
        return nil unless headers.respond_to?(:each_pair)

        _, value = headers.each_pair.find { |k, _| k.to_s.downcase == name }
        value.is_a?(Array) ? value.first : value
      end

      # The default transport: one GET, no redirect following. Following them
      # here would be following them without the policy, which is the whole
      # thing #fetch_url's loop exists to prevent.
      def http_get(url)
        uri = URI(url)
        request = Net::HTTP::Get.new(uri.request_uri, "User-Agent" => USER_AGENT)
        connection(uri).start do |http|
          # Captured rather than returned: `Net::HTTP#request` hands back the
          # RESPONSE, not its block's value, so returning the tuple from the
          # inner block would send a Net::HTTPOK where a status was expected.
          # Nothing driving a stub transport can see that — the live lane is
          # what this line was written against.
          answer = nil
          http.request(request) do |response|
            answer = [response.code.to_i, response.each_header.to_h, read_bounded(response)]
          end
          answer
        end
      end

      # A server answering with a terabyte must cost this process max_bytes and
      # not a terabyte, so chunks past the cap are dropped as they arrive.
      #
      # Dropped, and NOT `break`-ed out of: abandoning Net::HTTP's read_body
      # mid-body leaves the socket positioned inside the response, and the
      # `self.body` in Net::HTTPResponse#reading_body's ensure then reads the
      # remaining payload as a fresh chunk-size line — "Net::HTTPBadResponse:
      # wrong chunk size line" on roughly every other chunked, gzipped page,
      # depending on whether the leftover bytes happened to parse as hex. The
      # stream is therefore drained to its end; what is bounded here is memory,
      # and duration stays the read timeout's job.
      def read_bounded(response)
        limit = max_bytes
        # A binary buffer: chunks arrive as bytes, and appending them to a
        # UTF-8 string raises the moment one is not ASCII. #scrub is the layer
        # that turns them into text.
        body = +"".b
        # `<=`, so a body exactly the size of the cap still takes on the chunk
        # that makes the truncation visible. `<` would truncate silently at
        # the boundary.
        response.read_body { |chunk| body << chunk if body.bytesize <= limit }
        body
      end

      def connection(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = timeout
        http.read_timeout = timeout
        http.write_timeout = timeout
        http
      end

      def timeout
        configured = config[:timeout].to_f
        configured.positive? ? configured : DEFAULT_TIMEOUT
      end

      # -- rendering -----------------------------------------------------------

      # Clamped rather than trusted: a row carrying a negative cap would
      # otherwise byteslice its way to nil and raise on every single call,
      # turning one bad config value into a tool that never works. Zero is
      # then an honest answer — the result says it kept nothing and how much
      # it dropped, which is visible in the very next tool result instead of
      # in a crash a turn later.
      def max_bytes = [config[:max_bytes] || DEFAULT_MAX_BYTES, 0].max

      def render(status, body, hops, uri)
        text, dropped = cap(scrub(body))
        remarks = remarks_for(status, text, dropped, hops, uri)
        return text.empty? ? "(no content)" : text if remarks.empty?

        # The page's own bytes are never rewritten: the newline below only
        # puts the separator on a line of its own, and a body that already
        # ended in one simply gets a blank line before the ledger.
        "#{text.empty? ? '' : "#{text}\n"}#{LEDGER}\n#{remarks.join("\n")}"
      end

      def remarks_for(status, text, dropped, hops, uri)
        remarks = []
        # 2xx is the silent case — announcing success on every call would be
        # noise in every result a model reads. Everything else is reported: a
        # 404 is an answer the server gave, not a crash, and a model that is
        # shown the error page without the status will read it as content.
        remarks << "HTTP #{status}" unless (200..299).cover?(status.to_i)
        # The model asked for one URL and is looking at another's bytes. It
        # has to be told which, or every relative link on the page resolves
        # against the wrong base.
        remarks << "followed #{hops} redirect#{'s' unless hops == 1} to #{uri}" if hops.positive?
        # Both counts measure the RENDERED text — what a model would have been
        # shown — rather than what the server sent. Two things separate them:
        # scrubbing has already replaced anything that was not valid UTF-8 (a
        # replacement character is three bytes where the original may have
        # been one), and the default transport stops KEEPING bytes past the
        # cap, so a page much larger than max_bytes reports the bytes it
        # actually held on to. "of rendered text" is what keeps this line from
        # claiming it measured the page.
        if dropped.positive?
          remarks << "content truncated at max_bytes: kept the first #{text.bytesize} bytes " \
                     "of rendered text and dropped #{dropped} more"
        end
        remarks
      end

      # A server's body is whatever bytes it felt like sending, and the
      # session log refuses invalid UTF-8 at the durable append boundary, so
      # this is the layer where they have to become storable — replacing what
      # was never valid rather than dropping the whole answer on the floor.
      #
      # No transcoding by declared charset: a page labelled iso-8859-1 comes
      # back with its non-ASCII bytes replaced rather than converted. Guessing
      # an encoding from a header the server may have got wrong is a second
      # way to corrupt text, and the honest note beats the half-measure.
      def scrub(body)
        text = body.to_s
        text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
        text.scrub
      end

      def cap(text)
        limit = max_bytes
        return [text, 0] if text.bytesize <= limit

        kept = whole_characters(text.byteslice(0, limit))
        [kept, text.bytesize - kept.bytesize]
      end

      # Cutting at a byte offset can split a character in half, and those
      # halves are bytes this file manufactured — the server never sent them,
      # and a durable append JSON-encodes the payload, so a manufactured half
      # raises a layer away from the code that broke it. At most three bytes
      # come back off, the longest tail a split UTF-8 character can leave.
      # Belt and braces after #scrub, and kept anyway: the same rule Bash
      # holds itself to, for the same reason.
      def whole_characters(text)
        text = text.byteslice(0, text.bytesize - 1) until text.valid_encoding?
        text
      end
    end
  end
end
