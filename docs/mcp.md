# Terret and MCP (v1)

`terret-mcp` mounts Model Context Protocol servers as tool sources. It is
a client only, built on the manceps gem. It invents no execution path: a
discovered MCP tool registers into `ctx[:tools]` as an ordinary
definition whose handler calls the server. The pipeline, the policy
waterfalls, the approval metadata, and the session log treat MCP tools
exactly like local ones. Tool results are data (see
docs/terret-implementation-plan.md §13); nothing a server returns is
executed except through the model.

## Wire target

The deployed MCP ecosystem speaks the "legacy" wire (protocol revisions
2025-11-25 / 2025-06-18): the `initialize` handshake, `Mcp-Session-Id`, and
JSON-or-SSE POST responses. That is what manceps implements and what v1
targets. The 2026-07-28 stateless revision is not deployed anywhere yet and
is out of scope (recorded in the plan's §14). Deprecated-in-current-spec
features (sampling, elicitation, roots) are not used.

## Configuration

One config row, servers as a keyed hash (the `roles:`/`tokens:` idiom):

    { id: "mcp", plugin: Terret::MCP::Service, config: {
        servers: {
          "nexus" => { url: "https://nexus.example/mcp",
                       bearer: ENV["NEXUS_TOKEN"],
                       approval: :policy, timeout: 30 },
          "files" => { command: "npx",
                       args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
                       approval: :always }
        },
        strict: false } }

Per-server keys: `url:` (streamable HTTP) or `command:` + `args:`/`env:`
(stdio; exactly one of url or command); `bearer:` (HTTP auth);
`approval:` (`:never` | `:policy` | `:always`, default `:policy`)
stamped onto every tool the server contributes; `timeout:` seconds per
call (default 30).

Connecting is explicit and happens after boot, inside the reactor:

    ctx[:mcp].mount!            # all configured servers
    ctx[:mcp].mount!("nexus")   # one
    ctx[:mcp].unmount!("nexus") # reverses every registration it made

## Namespacing

A tool `search` from server `nexus` registers as `mcp__nexus__search`. The
double-underscore namespace is the same convention orchestrator allow lists
already use, so `mcp__nexus__*` in an allow list means "everything this
server offers". Server names must match `/\A[a-z0-9_-]+\z/`.

## Policy

Three layers, all existing seams:

1. **Per-server approval**: the `approval:` config value lands on each
   `Definition`; the approval machinery that consumes it is M6.
2. **The allow list**: `Terret::Tools::AllowList.install(ctx, patterns)`
   installs a deny-by-default `tools/pre_execute` veto; installed on an
   agent's forked context it governs that agent alone (tool waterfalls
   dispatch on the calling agent's context).
3. **Strict mode**: `strict: true` refuses to mount any server that did
   not come from this config row. Today all servers come from the config
   row, so strict changes nothing observable; it exists so that when
   profile/home-level ambient config arrives (plan §7), a strict row is
   already contractually closed to it.

## Calls, timeouts, failures

A tool call round-trips through manceps inside the agent's turn fiber; IO
yields to the reactor, so other agents proceed. Every call is wrapped in
`Async::Task#with_timeout` (per-server `timeout:`). A timeout returns an
error `tool/result` ("mcp timeout after Ns") and tears the connection
down for a reconnect on next use. The stdio transport has no timeout of
its own. It correlates responses by ordering. It does not correlate them
by id, so a late reply to an abandoned request must never be misread as
the answer to the next one. Server-side tool failures (`isError`) and
transport errors also come back as error results; they never raise into
the loop.

## Results

`ToolResult#structured_content` wins when present (already primitives);
otherwise the text content items joined by newlines. Image/audio/resource
items degrade to a text placeholder naming the type and mime type; v1
carries no binary payloads into the log.

## Change notifications

Given a reactor, the service runs a listener task per mounted server; on
`notifications/tools/list_changed` it re-lists and reconciles: new tools
register, vanished tools dispose, changed schemas re-register. A failed
re-list leaves the current roster in place and retries on the next
notification.

## Resources

`ctx[:mcp].register_resource_section(server, uri, name:, priority: 100)`
reads the resource once and registers its text as a prompt section (an
effect; disposing unregisters). Live refresh on `resources/updated` is
deferred until a consumer needs it. Unmounting the server also
unregisters every section it served.
