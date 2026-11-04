# dsh-go-link

Lets agents on this computer (Claude Code, Codex, OpenCode, Antigravity, and other MCP clients) use the phone-control tools of a phone running DSH Go. The phone dials in through SSH, or over the local network after `pair`; until then nothing here listens on the network. Design: [docs/design/remote-agents.md](../../docs/design/remote-agents.md).

You normally don't install this yourself. In DSH Go, open `Settings › Phone control › Computers` and turn on an SSH host. The app copies `bin/dsh-go-link.cjs` to `~/.dsh-go/link/bin/` on that computer, starts the daemon and stays connected. Tap the host for the line to add to each agent.

## Commands

```
node ~/.dsh-go/link/bin/dsh-go-link.cjs mcp              # what agents run (stdio MCP server)
node ~/.dsh-go/link/bin/dsh-go-link.cjs config [agent]   # registration snippets (claude-code, codex, opencode, antigravity, other)
node ~/.dsh-go/link/bin/dsh-go-link.cjs status           # is a phone attached, which agents are connected
node ~/.dsh-go/link/bin/dsh-go-link.cjs stop             # stop the daemon (DSH Go starts it again)
node ~/.dsh-go/link/bin/dsh-go-link.cjs pair             # pair a phone on this network (QR code; no SSH needed)
node ~/.dsh-go/link/bin/dsh-go-link.cjs lan off          # stop listening on the network
node ~/.dsh-go/link/bin/dsh-go-link.cjs peers [remove ID]  # phones paired over the network
```

Without SSH, get the file first: `curl -fsSL https://raw.githubusercontent.com/ccch1mneyyy/dsh-go/main/host/dsh-go-link/bin/dsh-go-link.cjs -o dsh-go-link.cjs`, then `node dsh-go-link.cjs pair`. It shows a QR code for the phone's camera (and the link it holds); the code works once, for 10 minutes. `--address HOST:PORT` (repeatable) and `--port N` set what goes in it when the phone reaches this computer another way (a VPN, a forwarded port).

`start [--json]` and `daemon` are what the app runs. `DSH_GO_LINK_HOME` moves the state directory (default `~/.dsh-go/link`, mode 700).

## How it works

- **Daemon**: a unix socket for agents (`link.sock`) and a loopback TCP port for the phone, which reaches it through its SSH tunnel and proves itself with a token that changes on every start (`daemon.json`, mode 600).
- **Agents**: `dsh-go-link mcp` answers `initialize`, `ping` and `tools/list` from the phone's last catalog (`catalog.json`) even while no phone is attached, and sends `notifications/tools/list_changed` when one attaches. Tool calls go to the phone; without one they return `[PHONE_NOT_ATTACHED] …`.
- **The phone decides**: confirmation, app rules and limits run on the phone, as for DSH there. Agents are shown by the name they report (`clientInfo`), which is not verified.
- **Logs**: `daemon.log` has events only, never screen text, typed text, screenshots or tokens.

- **Network pairing**: Noise IK (`Noise_IK_25519_ChaChaPoly_SHA256`, the suite `packages/dsh_remote` speaks) on a listener that is off until `pair`; only phones whose key was paired get in. The daemon's key is in `identity.json`, the paired phones in `peers.json`.
- **Agent sessions** (the phone as the cockpit): the phone asks the daemon to run Claude Code, Codex, Antigravity (`agy acp`), OpenCode or Gemini CLI over ACP (one process per session, in a folder the phone picks). Sessions keep running while the phone is away and their events are kept in `sessions/`; after a restart they resume with `session/load`. Each session's agent gets the phone tools (`mcp --bind`). `agents.json` overrides an agent's command, e.g. `{"claude-code": {"command": ["claude-agent-acp"]}}`. Agents sign in on this computer with their own accounts.
- **Earlier sessions**: the phone lists a folder's sessions, the daemon's and the agent's own (ACP `session/list`, which includes ones started in a terminal), and continues one: a session the daemon runs is only watched; another is loaded with its history.
- **Environment and bypass**: the phone sends each agent's environment variables with the requests that may start it; the daemon keeps them in memory only. Bypass runs the agent without permission prompts: Claude Code's `bypassPermissions` mode, Codex's `agent-full-access` mode, Antigravity's `--dangerously-skip-permissions` (the agent restarts between turns to switch). Another agent can declare one in `agents.json`: `{"opencode": {"bypass": {"args": ["--some-flag"]}}}` or `{"bypass": {"mode": "<mode id>"}}`.
- **Updates**: a newer copy's `start` replaces the running daemon, unless an agent there is working; then that daemon keeps serving and exits once none is, so no turn is cut off.
- The daemon exits after 30 minutes with no phone, no agent connected, nothing running and the network listener off; the app or an agent starts it again.

`handoff` waits for the person for up to 11 minutes. Agents with a short MCP tool timeout need it raised; the Codex snippet sets `tool_timeout_sec = 660`.

## Development

```
node --test test/*.test.mjs
node scripts/sync-asset.mjs           # copy into app/assets/link/ (CI checks it with --check)
```
