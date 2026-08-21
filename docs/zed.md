# Driving Terret from Zed

Wiring Terret into Zed as an external ACP agent is the fastest way to
exercise the harness by hand, and it is why there is no TUI. This page is
the working setup. The wire contract, the mapping, and what is
deliberately absent live in `docs/acp.md`.

Proven working end to end: handshake negotiates protocol version 1,
`session/new` returns a session id, prompts stream back as
`agent_message_chunk`, and tools execute and report `completed`.

## 1. A profile that mounts the ACP row

`terret-base` does not depend on `terret-acp`, so a profile has to name
the gem and the row. Without both, `trt acp` boots a Terret that has no
stdio server.

```yaml
# ~/.terret/profiles/zed/profile.yml
bundles: [terret]
plugins: [terret/acp]
settings:
  workspace: [/absolute/path/to/your/project]
```

```yaml
# ~/.terret/profiles/zed/patch.yml
rows:
  - id: acp
    plugin: Terret::ACP::Service
    config: {}
    after: loop
```

`workspace:` is the containment list every filesystem tool is held to
(`docs/exec.md` §3, `docs/composition.md` §6). An empty or missing list
denies every fs operation. Zed's `cwd` on `session/new` does not widen
it: the editor can name a directory, and the profile is still the
authority (`docs/acp.md`, "Resolved in Task 7").

The rest of what this profile grants is inherited from `terret-base`
unless you patch it:

- **Approvals are off.** The `approvals` row ships `disabled: true`. An
  editor-driven agent has nobody sitting on a prompt to click Allow, so
  that default is the one you want until you decide otherwise.
- **Bash, jobs, and terminals run in Docker with `network: none`.** That
  is the sandbox row, not a convenience default a profile forgets to
  opt out of. Uncommenting the `SandboxNone` swap in the shipped
  `headless` template is how you run tools on the host; do not copy that
  into a Zed profile by accident (`docs/security.md`).
- **The allow list starts with the std roster only.** A third-party tool
  gem is denied until this profile says otherwise.
- **WebFetch allow is empty.** The tool is mounted and still reaches no
  host.

Read `trt dump-config --profile zed` before the first prompt. An
editor-driven agent can reach exactly what that dump shows, and nothing
the editor adds on the wire.

## 2. A launcher, then Zed

The command an editor spawns is `trt acp --profile zed`. Put it behind a
launcher rather than a bare command, because the launcher is where you
pin the Ruby version and the load path. stdout is the ACP stream; a
`puts` anywhere in the boot is a protocol violation (`docs/acp.md`,
"Framing"). Keep logs on stderr.

```sh
#!/bin/sh
# ~/bin/trt-acp-launcher — pin Ruby, then serve ACP on stdio.
exec mise exec -- trt acp --profile zed
```

`chmod +x` it. Then in `~/.config/zed/settings.json`:

```json
{
  "agent_servers": {
    "terret": {
      "type": "custom",
      "command": "/path/to/trt-acp-launcher",
      "args": [],
      "env": {}
    }
  }
}
```

Zed spawns that process per project. The pipes are private to the pair,
so there is no bearer token: an ACP client is exactly as trusted as the
editor that spawned it (`docs/acp.md`, "What is deliberately absent").

## 3. The things that actually cost time

- **Zed keeps one agent process per agent per project.** A new thread on
  a live connection is a `session/new`, not a respawn, so an edited
  profile is not picked up until the process exits. This is the single
  most confusing behavior for someone changing a model and wondering why
  nothing changed. Kill the agent (or close the project) after a profile
  edit.
- **`agent: new thread` starts a thread on the default agent.** The
  external agent picker is behind `agent: toggle new thread menu`. If
  Terret is configured and every new thread still talks to Zed's built-in
  agent, that is why.
- **`dev: open acp logs` shows every frame,** and is the right first
  stop when a thread hangs. A prompt that never answers is almost always
  a pending `session/prompt` that never got a `stopReason`, which the
  log will show as a request with no matching response.

## 4. What "working" looks like

Handshake answers `protocolVersion` **1** (an integer). `session/new`
answers a `sessionId`. Typed prompts arrive as `agent_message_chunk`. A
tool call opens as `tool_call` with `status: "pending"` and closes as
`tool_call_update` with `completed` or `failed`. Closing the window
disposes the connection, not the agent: the session is durable, and
re-attaching is another `session/prompt` against the same id
(`docs/acp.md`, "EOF disposes the connection, not the agent").

The ACP reference (`docs/acp.md`) is the contract. This page is only
how to drive it from Zed.
