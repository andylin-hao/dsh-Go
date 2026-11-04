# Remote agents: Claude Code, Codex, OpenCode and Antigravity work on a computer and operate the phone

> 2026-11-04. Status: **P1, P2 and P3 implemented** (code, desktop tests; see §9 for what ran on a phone). P4 waits on upstream. Decisions from the owner on 11-04 are in §8. It builds on phone control (`app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/phone/`, design in [phone-overlay.md](phone-overlay.md)), SSH hosts (`app/lib/remote/ssh/`) and the Noise IK in `packages/dsh_remote/lib/src/crypto/noise_ik.dart`. Roadmap P3 #4 ("Claude Code / Codex backend") and P3 #5 ("phone control") meet here.

## 0. Conclusion

There are two capabilities and one new host-side component.

1. **The phone as a tool (MCP).** Any MCP-capable agent on a computer (Claude Code, Codex, OpenCode, Antigravity, Gemini CLI and others) gets the same `phone` tools DSH has today. It gets them through a channel that **the phone dials out**. The phone keeps the same fixed catalog, the same `SafetyGate`, the same approval cards, the same overlay and the same stop button. Nothing about the gate moves off the phone.
2. **The phone as the cockpit (ACP).** You start and steer Claude Code, Codex or OpenCode sessions on that computer from DSH Go's native chat. Those sessions get phone tools automatically, and they are *bound* to the phone task. Stop cancels exactly that turn, and the end of the turn closes the overlay. This removes the guessing in `PhoneTurnLink`.
3. **One host component, `dsh-go-link`** (one Node file, installed by the app over SSH). It is a daemon that the phone attaches to, plus a stdio MCP shim that agents register (`dsh-go-link mcp`), plus (in P3) an ACP supervisor that keeps agent processes alive across phone disconnects.

Order of work:

| Phase | What | Transport | Agents |
|---|---|---|---|
| **P1** | Phone as a tool | SSH hosts that already exist | All MCP agents, incl. Antigravity (DSH itself on SSH hosts is a follow-up) |
| **P2** | Pairing without sshd | LAN / Tailscale: QR code + Noise IK, phone dials | Same |
| **P3** | Phone as the cockpit | P1/P2 link | Claude Code, Codex, OpenCode (and Gemini CLI) over ACP |
| **P4** | Relay | ds-harness-remote | Needs an upstream capability (§6.4) |

Antigravity: its IDE uses the phone as a tool (MCP); its CLI (`agy`, 1.5.0) also speaks ACP (`agy acp`), so the phone can drive it like the others (checked 11-04; this corrects the earlier assumption that it couldn't).

## 1. Where we are (from the code)

| Area | Today | Consequence |
|---|---|---|
| Phone MCP server | `McpServer.kt`: newline JSON-RPC 2.0, `initialize` / `ping` / `tools/list` / `tools/call`, protocol versions up to 2025-11-25. Calls run off the reader thread, so pings keep flowing during a long `handoff` | Reusable as is for any MCP client |
| Tool catalog | `PhoneToolCatalog.kt`: 13 fixed tools, hash-pinned by a JVM test (DeepSeek KV cache) | Serve it unchanged to remote clients; guidance goes in `initialize.instructions`, not in the tool text |
| Gate | `PhoneCore` → `SafetyGate`, `PhoneTasks` (one task, 3 min idle, 30 s stop hold, interjections), `PhonePrompts` (approval cards), masking | Transport-independent. It needs an **origin** but no new logic |
| Transport | `PhoneBridge.kt`: per-launch abstract unix socket, `SO_PEERCRED` = app uid, hello token. Loopback TCP fallback. `PhoneGuest.kt` writes `relay.cjs` + a `--patch` overlay into the PRoot rootfs | Local-engine-only by design |
| Lifecycle | Bridge starts in `PhoneControl.prepareLaunch` and stops with the engine; not loaded in safe mode | Remote serving must not depend on the local engine |
| Flutter gates | `phoneBlockerProvider` → `PhoneBlocker.remoteHost` when the active host isn't local. `phoneStopWatcherProvider` cancels **every** running local turn on stop | Both need origin awareness |
| Turn link | `phone_turn_end.dart`: "the MCP bridge does not carry a conversation identity", so auto-finish only when exactly one local conversation runs | ACP sessions fix this for remote agents |
| Remote transports | SSH: dartssh2 `forwardLocal`, remote bootstrap with state in `$HOME/.dsh-app-remote`. Relay: `RemoteTunnelCarrier` has an endpoint allowlist and `supportsUplink = false` | SSH can carry a new stream today; Relay cannot |
| Chat model | `ChatItem` (User / Assistant / Tool / Notice) in `packages/dsh_client/lib/src/transcript.dart`; `chatProvider` → `ChatController` (≈2 000 lines) is bound to `DshClient` | ACP can produce the same `ChatItem`s; the controller stays separate |
| Policy | Roadmap P3 #4: Claude Code / Codex only via API key or **the original CLI's own login** (Anthropic terms) | The app never handles agent credentials |

## 2. Goals and non-goals

Goals:

- Claude Code, Codex, OpenCode or Antigravity on the user's own computer can read the phone screen, tap, type and use intents. It goes through the same gate, approvals and overlay as DSH, and the phone shows who is acting ("Claude Code on dev-box").
- From the phone, the user can start, follow, approve and stop Claude Code, Codex and OpenCode sessions on that computer. Work survives the phone losing signal.
- The phone never listens on a network port. Every link is phone → computer, encrypted (SSH or Noise).

Non-goals (v1):

- Proxying, storing or entering any agent's login. Sign-in happens on the computer, in the agent's own CLI.
- Running Claude Code or Codex inside the phone's PRoot.
- Making "a computer with agents" a fourth `HostKind`. Agent chats get their own drawer row instead (§5.4).
- Changing the tool catalog DeepSeek sees.
- The Relay path (P4).

## 3. Architecture

```
 Computer (Linux / macOS / Windows)                          Phone (DSH Go)
┌────────────────────────────────────────────────┐        ┌───────────────────────────────────────────────┐
│ Claude Code · Codex · OpenCode · Antigravity   │        │ Dart  packages/dsh_link: LinkClient           │
│   └─ MCP stdio ─ `dsh-go-link mcp` (shim) ─┐   │        │   ├─ mcp:* channels ─ MethodChannel dsh/phone │
│                                            ▼   │ phone  │   │     remoteOpen / remoteLine / remoteClose │
│ dsh-go-link daemon ◄──── link protocol ────────┼─dials──┤   │            │                              │
│   ├─ ~/.dsh-go/link/link.sock (shims, 0600)    │ SSH or │   │            ▼                              │
│   ├─ 127.0.0.1:<port> (SSH-forwarded phone)    │ Noise  │   │  Kotlin: McpServer per channel + Origin  │
│   ├─ LAN port, Noise only, opt-in (P2)         │        │   │  → PhoneCore → SafetyGate · PhoneTasks    │
│   └─ ACP supervisor (P3)                       │        │   │    · approvals · overlay · masking        │
│        ├─ Claude Code ACP adapter              │        │   └─ acp:* channels → Agent chat UI (P3)      │
│        ├─ Codex ACP adapter                    │        │                                               │
│        └─ opencode acp / gemini (ACP)          │        │                                               │
└────────────────────────────────────────────────┘        └───────────────────────────────────────────────┘
```

### 3.1 `dsh-go-link` (host)

- One Node file (`host/dsh-go-link/bin/dsh-go-link.cjs`, Node 18+ in practice, no dependencies; Claude Code, Codex and OpenCode installs already bring Node). The app ships a copy as `app/assets/link/dsh-go-link.cjs` (kept equal by `scripts/sync-asset.mjs --check` in CI) and installs it over SSH into `~/.dsh-go/link/bin/`, rewriting it only when its SHA-256 differs. So the app and the daemon it talks to always match; publishing to npm is optional and not done.
- Commands:
  - `daemon`: started by the app over SSH (same pattern as the remote `dsh web` bootstrap) or by the user.
  - `mcp`: the stdio shim agents register.
  - `pair` (P2): prints a QR code.
  - `config <agent>`: prints, or with `--write` installs, the MCP snippet for that agent.
  - `status` and `peers`.
- State lives in `~/.dsh-go/link/` (0700):
  - `daemon.json`: pid, port, token, version. 0600, rewritten on every start.
  - `link.sock`: Windows uses a named pipe instead.
  - `catalog.json`: the last `tools/list` from the phone.
  - `peers.json`: pinned phone keys (P2).
  - `sessions/`: ACP logs (P3).
- The daemon never logs tool payloads (screen text, typed text, screenshots). It logs only method names, channel ids, sizes and error codes.

### 3.2 Link protocol (phone ↔ daemon)

- One byte stream carries newline-delimited JSON frames, at most 4 MiB each (the same `MAX_LINE` as `PhoneBridge`, which fits a screenshot).
- Hello (SSH path):

  ```
  phone → {"dshGoLink":1,"token":"…","phone":{"id","name","app"},"caps":["phone.mcp.v1"]}
  ← {"ok":true,"host":{"name","os","link"},"caps":["phone.mcp.v1"]}
  ```

  On the LAN path the same hello runs inside Noise IK (§6.2).
- Frames:
  - `{"t":"open","ch":"m7","kind":"mcp","origin":{"client":"claude-code","clientVersion":"…","bind":null}}`
  - `{"t":"data","ch":"m7","line":"<one JSON-RPC message>"}`
  - `{"t":"close","ch":"m7","code":"…"}`
  - `{"t":"ping"}`
- Direction: the daemon opens `mcp` channels, one per shim connection. The phone opens `acp` channels (P3). Payloads are untouched JSON-RPC lines.
- The daemon answers `initialize`, `ping` and `tools/list` itself, from the catalog (tools, instructions) the phone sent in its hello and cached in `catalog.json`; it forwards `tools/call` and any other request. That is what lets an agent started before the phone attached still see the tools, and what makes a phone that attaches later a `notifications/tools/list_changed`. Requests waiting on a phone that drops are answered by the daemon (`[PHONE_NOT_ATTACHED] …` for tool calls), never left hanging. The shim replays the agent's `initialize` after a daemon restart, so the daemon learns who it is again.
- Capabilities are negotiated through `caps`, and unknown frame types are ignored. One phone attaches per daemon; a second attach closes the first with `replaced`, the same idea as the relay's `CONNECTION_REPLACED`.

### 3.3 Phone side: one gate, many origins

Kotlin:

- **`Origin`**: either `Local` or `Remote(hostKey, hostLabel, client, bind?)`. `client` is the MCP `clientInfo.name` the agent *reports*. It is unauthenticated (any process of that user on the computer can claim it), so it is labelled, not trusted. The same reasoning appears in `PhoneBridge`: "Same-uid code … gets past both checks by design: the real gate is the person's tap."
- **`McpServer`** gets one instance per channel, built with its origin. The `instructions` agents get (`RemotePhoneSessions.INSTRUCTIONS`, English, a condensed `PhoneGuest.AGENTS_SECTION`) travel in the hello with the unchanged tool list, so the hash test stays green.
- **`PhoneCore.call(origin, name, args)`**: the origin reaches `PhoneTasks`, `ActionLog`, the overlay line and the approval card ("Claude Code on dev-box wants to tap 'Send'").
- **`PhoneTasks`**: the task owner is the origin. A call from another origin while a task is active returns `[PHONE_BUSY] The phone is being used by <origin>. Try again after it finishes.` Nothing is pre-empted. The stop hold is per owner, so stopping a remote agent doesn't block the next local turn.
- **`RemotePhoneSessions`** (new, small) maps channel id → dispatcher. On `dsh/phone` it serves `remoteOpen(ch, origin)`, `remoteLine(ch, line)` (cheap methods answered at once, `tools/call` on the existing call executor) and `remoteClose(ch)`. It emits `remoteStop(owner)` when the person stops.
- **Lifecycle**: remote serving needs only the phone-control switch, a per-computer grant and an attached link. It does not depend on the local engine, the PRoot bridge or safe mode.

Policy for remote origins (owner, 11-04): **the same as for this phone's engine.** Confirmation (Always ask / This task / Always skip), Lift limits, app rules, masking, screen-on, idle end and approval timeout all apply unchanged; there is no per-computer policy. What remote origins add is the per-computer switch with its own disclosure (§4), the origin on every card, and one owner per task.

Flutter:

- `phoneBlockerProvider` is unchanged in P1: it is about DSH on the active host, and DSH on SSH hosts doesn't mount the shim yet (follow-up).
- `phoneStopWatcherProvider` cancels by owner. A local owner keeps today's behaviour (cancel the local engine's running turns). An ACP owner sends `session/cancel` for that session only. A plain-MCP owner gets the task stop and stop hold; the agent's turn on the computer can't be cancelled from here, and the tool result tells it to stop.
- The links live in Dart, kept alive by the home shell (`PhoneStopWatcher` watches `phoneLinksProvider`); the Flutter engine outlives the activity (`MainActivity` caches one per process). P1 adds no notification of its own. Whether a link survives long in the background without the local engine's foreground service has to be checked on real devices; a dedicated foreground notification is the fallback.

## 4. P1: the phone as a tool over SSH hosts

Flow:

1. In `Settings › Phone control › Computers` (shown while phone control is on), the user turns on an SSH host. A risk sheet explains that screen text (and screenshots for vision models) goes to that computer and on to whichever model provider the agent there uses. The host's key must already be pinned (it was connected once); the link never asks about a key.
2. The app opens its own SSH connection to that host (independent of which host is active), finds Node (login PATH, then Homebrew, `/usr/local`, Volta, nvm), installs its copy of the script if the hash differs, and runs `dsh-go-link start --json`, which starts the daemon detached (or reuses a running one of the same version, replacing another version). `lib/remote/link/link_bootstrap.dart`.
3. The app opens `forwardLocal` to `127.0.0.1:<port>`, sends the hello with the token, and stays attached.
4. On attach, the daemon asks the phone for `tools/list`, writes `catalog.json` and sends `notifications/tools/list_changed` to connected shims.
5. An agent calls `phone.screen`. The call goes shim → daemon → `data` frame → `LinkClient` → `remoteLine` → `PhoneCore` with the remote origin. The overlay names the agent and the computer, and approvals appear as usual.
6. When the phone isn't attached, shims still answer `tools/list` from `catalog.json`, so agents started earlier see the tools. Calls return `isError: true` with `[PHONE_NOT_ATTACHED] DSH Go is not connected to this computer. …`

Agent setup. `dsh-go-link config <agent>` prints these, and the app shows them with copy buttons. Check each against the agent's current docs at implementation time, because their config formats change often.

| Agent | Registration |
|---|---|
| Claude Code | `claude mcp add --scope user phone -- dsh-go-link mcp` (raise `MCP_TOOL_TIMEOUT` if `handoff` times out) |
| Codex | `~/.codex/config.toml`: `[mcp_servers.phone]` `command = "dsh-go-link"`, `args = ["mcp"]`, `tool_timeout_sec = 660` |
| OpenCode | `opencode.json`: `"mcp": {"phone": {"type": "local", "command": ["dsh-go-link", "mcp"]}}` |
| Antigravity | MCP servers → custom config: `{"mcpServers": {"phone": {"command": "dsh-go-link", "args": ["mcp"]}}}` |
| DSH on the same SSH host | `dsh-go-bridge` inserts the same `@deepseek-ai/dsh-mcp-client` row as `PhoneGuest.PATCH_YAML`, pointing at `dsh-go-link mcp`. The model sees `mcp__phone__*` on remote DSH too |

Tool-call duration: `handoff` can wait up to 11 minutes (`PhoneGuest.TOOL_CALL_TIMEOUT_MS`). Each agent's MCP timeout has to cover that. Where a client can't be configured, send `notifications/progress` while waiting if the client supplied a `progressToken`. If neither works, `handoff` returns early with "still waiting for the person; call `screen` to check".

## 5. P3: the phone as the cockpit (ACP)

### 5.1 Why ACP

The Agent Client Protocol (Zed) is one JSON-RPC-over-stdio protocol. OpenCode (`opencode acp`) and Gemini CLI implement it natively, and there are adapters for Claude Code (built on the Claude Agent SDK) and Codex. It covers what the chat needs: streamed messages and thoughts, tool calls with diffs, plans, permission requests, cancel and modes. Crucially, it also has **per-session MCP servers** (`session/new.mcpServers`), which is how phone tools get attached to a session with known ownership.

Alternatives considered:

- Each agent's own API (Codex `app-server`, OpenCode HTTP server, Claude Code `stream-json`): three or four adapters to maintain, for no gain over ACP.
- A PTY running `claude` in the existing terminal page: no work at all, and it already works on DSH hosts. The UX is poor on a phone. It goes in the user guide as the fallback, not the product.

### 5.2 Daemon as ACP client

- For each agent kind, the daemon spawns the adapter (`which` detection plus a user-editable command in `~/.dsh-go/link/agents.json`). It runs `initialize`, then:

  ```
  session/new {cwd, mcpServers: [{name: "phone", command: "dsh-go-link", args: ["mcp", "--bind", "<one-time ticket>"]}]}
  ```

  The ticket binds the shim's MCP channel to this ACP session. The `origin.bind` sent to the phone carries the session id, so the phone knows exactly which turn is acting.
- It declares **no** `fs` or `terminal` client capabilities, so agents use their own file and shell tools on the computer. That keeps the protocol surface small.
- Durability: the daemon owns the agent processes, so a turn keeps running when the phone drops. Every `session/update` is appended to `sessions/<id>.jsonl` with a sequence number. The phone reattaches with `{resume: id, afterSeq: n}` and gets the tail. A pending `session/request_permission` stays open until the phone answers it or the agent times it out. After a daemon restart, sessions reopen with `session/load` when the agent advertises `loadSession`.
- The daemon keeps its own index (agent, cwd, title, created, last activity, running) and lists only the sessions it created. It doesn't depend on per-agent session listing.

### 5.3 Mapping to `ChatItem`

| ACP | DSH Go |
|---|---|
| `agent_message_chunk` | `AssistantChatItem.text` (streaming) |
| `agent_thought_chunk` | `AssistantChatItem.reasoning` (thinking row) |
| `tool_call` / `tool_call_update` (pending, in_progress, completed, failed) | `ToolChatItem` (running, succeeded, failed); `diff` content → change card / diff page |
| `plan` | Progress capsule and progress tab |
| `session/request_permission` (allow_once / allow_always / reject_once / reject_always) | Approval card; a turn notification when the app is in the background |
| `available_commands_update` | Slash palette |
| `current_mode_update` / `session/set_mode` | Permission pill (e.g. Claude Code's plan / acceptEdits) |
| `session/prompt` result `stopReason` | Turn end: `end_turn` ends normally; `cancelled`, `max_tokens` and `refusal` become `NoticeChatItem`s. It also calls `finishTask` for a phone task this session owns |
| Prompt with images | `image` content blocks when `promptCapabilities.image` is set |
| Files | Uploaded to the session cwd through the daemon, then sent as a `resource_link` |

### 5.4 App

- **Placement**: follow the DS Bot precedent. One drawer row, **Agents**, collapses every ACP session across computers (agent icon, computer, unread count). The host switcher and `activeConnectionProvider` stay DSH-only. Nothing that reads them changes.
- **New chat**: pick the computer, then the agent (only detected ones), then a folder (recent cwds plus a folder browser over the daemon).
- **`AgentChatController`** stays separate from `ChatController`. Before P3 starts, list exactly what `chat_list.dart`, `chat_rows.dart` and `composer.dart` read from `ChatState`. Extract the smallest read interface both controllers can satisfy. Don't refactor `ChatController`. Features ACP doesn't have stay hidden: trajectory, sub-agent tree, share replays, deliverables and model channels.
- **Sign-in**: when an agent reports that auth is required, the app shows "Sign in on the computer: run `claude` and `/login`" (or `codex login`, `opencode auth login`) and offers the SSH terminal. It never shows a login form of its own.
- **Phone tasks**: a Stop the person asks for (the overlay, the app, the notification, or 停止 while confirming) → `session/cancel` for the bound session. Screen off or the accessibility service going away end the phone task only (`stoppedByPerson` is false): the agent's turn goes on, and its next phone call hears why. The turn's end closes the overlay and, with "Back to DSH Go when done" on, returns to that agent chat.

## 6. Transports

### 6.1 SSH (P1)

The phone already holds the SSH connection, host-key TOFU and the reconnect logic. The daemon listens only on loopback, and its token rotates on every start and is read over SSH. Nothing new is exposed on the computer's network.

### 6.2 LAN pairing (P2)

This is for Macs and Windows PCs that don't run sshd, which covers most people sitting in Antigravity or Claude Code at their desk.

- `dsh-go-link pair` turns on a LAN listener (TCP or WebSocket) and prints a QR code. The QR holds the computer's addresses and port, the daemon's static X25519 key and a one-time pairing secret that expires after 5 minutes.
- The phone scans it and dials. Noise IK runs as initiator with the pinned daemon key; reuse `noise_ik.dart` from `dsh_remote` with a Node counterpart tested against the same vectors. The pairing secret goes in the first payload. The daemon pins the phone's static key in `peers.json`, and from then on only pinned keys are accepted.
- It works across networks over Tailscale or ZeroTier without changes. There is no UPnP and no public listener.

### 6.3 Remote DSH over Relay (P4)

`RemoteTunnelCarrier` allows only `harnessRemoteAllowlist` and has no uplink, so a reverse channel needs upstream ds-harness-remote support. The proposal is a capability such as `client.link.v1`: a Host-opened stream whose items flow both ways, gated like `workspace.upload.v1`. Until then, relay hosts keep `PhoneBlocker.remoteHost`.

## 7. Security and privacy

| Threat | Mitigation |
|---|---|
| Prompt injection from web pages, mail or issues read by a remote model | Same `SafetyGate` and the person's own confirmation and limit choices; Hands-off apps stay hands-off; approvals carry the origin; access is per computer and off by default |
| Another process on the computer posing as an agent | Accepted, as with same-uid on the phone. The label is shown as reported, and the approval tap is the gate |
| Network attacker | SSH or Noise only; no plaintext listener; LAN listener only after `pair`, pinned keys only; **the phone never listens** |
| Leaked daemon token | Bound to loopback behind SSH; rotated on every daemon start |
| Lost phone or ended access | Turning off a computer's access in the app closes its channels immediately; `dsh-go-link peers remove` on the computer |
| Screen data leaving the device | Separate disclosure per computer; masking stays on the phone; daemon logs carry no payloads; the action log keeps no screen contents (as today) |
| Two controllers at once | One owner per task; others get `[PHONE_BUSY]` |

Error codes are stable and appear as a prefix in the tool text, since MCP tool errors are text: `PHONE_NOT_ATTACHED`, `PHONE_BUSY`, `PHONE_STOPPED`, `ACCESS_OFF`, `SCREEN_LOCKED`, `DECLINED`. The phone's answer is authoritative; the daemon never infers an outcome.

## 8. Decisions

Owner, 11-04:

1. **Policy for remote origins**: Always skip and Lift limits are allowed; remote origins follow exactly the local policy (§3.3).
2. **Name and location**: `dsh-go-link`, source in `host/dsh-go-link/`, Dart in `packages/dsh_link/`. Agreed.
3. **Order**: P1 → P2 → P3. Agreed.

Still open:

4. **Tool text for remote clients**: the Chinese catalog stays (hash-pinned) with English `instructions`. Measure tool-use quality on Claude and GPT before considering a separate English catalog.
5. **More than one phone per daemon**: not in v1 (a second phone replaces the first, which then stops reconnecting).

## 9. Work breakdown and verification

### As built (P2, P3)

- **Link protocol additions** (`caps` in the hello reply: `phone.mcp.v1`, `rpc.v1`, `agents.acp.v1`, `lan.v1`): `{t: call, id, method, params}` → `{t: result, id, result | error}` from the phone, and `{t: event, name, data}` notices (`sessions` summaries, `session` events of watched sessions, `turn_end`). Older daemons send no `caps`; the phone then uses phone tools only.
- **P2**: the daemon's X25519 identity (`identity.json`), its paired phones (`peers.json`) and a listener on `0.0.0.0` (`lan.json`, same port after a restart) that accepts only Noise IK. `dsh-go-link pair` prints a terminal QR code (byte mode, level M, versions 1–10, no dependencies; checked with zxing-cpp) of `dshgo://link?v=1&n&k&s&a`; the secret is 128 bits, one use, 10 minutes. The app routes `dshgo://link` (camera or paste) to a confirmation that shows the key fingerprint, keeps the computer in preferences (no secret stored; the phone key lives in the secret store) and dials its addresses. A computer without SSH gets the script from the repository (`curl …/host/dsh-go-link/bin/dsh-go-link.cjs`).
- **P3**: the daemon runs one ACP process per session (`agents.json` may override the commands; defaults pin `@agentclientprotocol/claude-agent-acp@0.99.1` and `@agentclientprotocol/codex-acp@2.5.0` (the packages formerly published as `@zed-industries/*`) through npx, `agy acp`, `opencode acp`, `gemini --experimental-acp`), logs events to `sessions/<id>.jsonl`, keeps turns going while the phone is away, resumes after a daemon restart with `session/load`, and binds the phone tools to the session (`mcp --bind <ticket>`). Phone requests: `agents.list`, `sessions.list|new|watch|unwatch|prompt|cancel|permission|mode|close`, `fs.list`, `setup.agents`. On the phone: `dsh_link`'s `AgentTranscript` folds events into items; **Agents on computers** (drawer row and the computer's sheet) lists sessions, starts new ones (agent, folder), and opens a chat with streamed answers, collapsible thinking, tool calls with diffs, the plan, permission cards and Stop. The turn's end finishes the phone task its agent owns (`remoteFinish`); Stop on the overlay cancels that session's turn.
- **Background**: a vivo phone on Android 16 froze the app within seconds of going to the background, without the local engine running; the link stopped answering and an agent's call failed after the daemon's 90 s silence limit. `PhoneLinkService` (a `specialUse` foreground service, like `PetOverlayService`) now runs while any computer link exists.
- **On a phone** (vivo V2505A, Android 16, arm64; the computer was WSL2 behind `adb reverse` and a Windows relay): pairing from the link with the fingerprint check; Claude Code 2.1.318 calling `screen` through `dsh-go-link mcp`, with DSH Go in front (refused: DSH Go itself) and in the background (read the home screen); a cockpit session with the scripted ACP agent (streamed answer, permission card answered on the phone, the session's agent calling the phone, the action log naming it). Then with the real agents, all signed in on that computer with their own accounts: Claude Code (`claude-agent-acp` 0.99.1) started from the phone asked on the phone before `mcp__phone__screen` and answered from its result; Codex (`codex-acp` 2.5.0) ran a shell command and reported; Antigravity (`agy acp`, CLI 1.5.0) read the phone through the session's tools, and `agy -p` with `agy mcp add phone …` and the allow rule `mcp(phone/screen)` read the home screen. A phone task stopping (here: the accessibility service suppressed by `uiautomator`) cancelled the bound Claude Code turn; since then only a stop the person asks for does that (see §5.4). Not yet on a phone: the SSH path, the Stop button itself, network changes.
- **Found with real agents**: Antigravity echoes the prompt as `user_message_chunk` (the phone now ignores it, since the daemon logs the prompt itself; rechecked on the phone: one bubble); the new-session sheet now refreshes the agent list (agents installed after attaching were missing); an agent session's permission request is only visible in DSH Go, so while its phone task has moved to another app the person has to switch back (needs a notification or the overlay; not done).
- **Sessions that outlive the app, resume, environment, bypass** (`agents.acp.v2` in `caps`; older daemons lack it and the phone hides these):
  - *Keep running*: sessions were already the daemon's, so closing the app, a dropped link or a locked phone never touched them. Two things still could: `start` of a newer copy replaced the daemon and killed its agents, and any phone-task stop cancelled the bound turn. Now `start` asks a daemon with working sessions (`status.busy`: running, starting or waiting for an answer) to `retire`: it keeps serving and exits once none is working, and the phone's reconnect starts the new copy. Only a stop the person asks for cancels a turn.
  - *Earlier sessions*: `sessions.history {agent, cwd}` merges the sessions the daemon keeps in that folder with the agent's own list (ACP `session/list` from a short-lived process of that agent; Claude Code, Codex and Antigravity list terminal sessions too), newest first, one entry per agent session id. `sessions.resume {agent, agentSessionId, cwd}` only watches a session the daemon keeps (a running turn goes on); another becomes a daemon session marked `imported`, whose first `session/load` replay is recorded (user chunks become `user` events) instead of dropped. An agent without `loadSession` gets `resume_unsupported`, never a fresh session in its place. A session still open in a terminal is not stopped; both processes go on with the same history from that point.
  - *Environment*: per computer and agent, in the phone's secret store; every request that may start the agent (`new`, `resume`, `prompt`, `mode`, `bypass`, `history`) carries `env`; the daemon validates it (names, 100 vars, 64 KiB) and keeps the last one per agent in memory only: never in `index.json`, the session logs or `daemon.log`.
  - *Bypass*: per agent, `bypass: {mode}` (Claude Code `bypassPermissions`, Codex `agent-full-access`: switched with `session/set_mode` at any time) or `{args}` (Antigravity `--dangerously-skip-permissions`: the idle process stops and the next prompt starts it with or without them; refused with `busy` during a turn). `agents.json` can set it for others. The summary's `bypass` follows the mode the agent last reported, or the arguments it runs with; after a daemon restart the mode the session had is set again before the turn. The phone asks with a risk notice each time it is turned on. Phone control still follows the phone's own confirmation settings.
  - *Upload*: the script's base64 passed 128 KiB, the most Linux allows in one argument (`sh -c`); the bootstrap now sends it in 48 KiB pieces to `bin/dsh-go-link.b64` and installs it after the hash check.
  - *Checked* (same vivo, LAN link, daemon 0.3.0): through the daemon with the real agents, `sessions.history` listed Claude Code, Codex and Antigravity sessions in the folder (terminal ones included; Antigravity's list takes about 7 s), and a session started with `claude -p` in a terminal resumed with its history and its context (it recalled a code word given there); bypass at creation and both ways for Claude Code (`bypassPermissions` ↔ `default`), Codex (`agent-full-access` ↔ `agent`) and Antigravity (started with the flag; off stopped it). On the phone: the resumed session showing the terminal's turn, the notice and the next turn; bypass from the session menu after the risk notice, the mode following on the computer; an environment variable set in the editor reaching the agent; the folder's list merging the daemon's session with the agent's own; and a turn that kept running while the app was force-stopped (the daemon dropped the phone after 90 s of silence), then reopened from the folder's list without a restart (same agent process) and stopped from the phone. Not on a phone: the SSH path, the no-DSH hint, the chunked upload over real SSH, a screen-off stop leaving the turn running.
- **Not done**: background notifications for an agent's questions (the app's notifications are built around DSH conversations), images in prompts, and DSH on SSH hosts mounting the shim.


### P1: phone as a tool over SSH (implemented)

| Area | Change |
|---|---|
| `host/dsh-go-link/` | Daemon, shim, `config`, link protocol, `node --test` suite with a fake phone and a fake MCP client |
| `packages/dsh_link/` | `LinkClient` over an abstract byte stream: frames, channels, keepalive, backoff; `dart test` with an in-memory peer |
| Kotlin `phone/` | `Origin`, `RemotePhoneSessions`, origin through `PhoneCore` / `PhoneTasks` / `ActionLog` / overlay / prompts, `instructions` in `McpServer`; JVM tests for busy / stop-hold per owner / remote policy caps / unchanged catalog hash |
| `app/lib/remote/link/` | SSH bootstrap of the daemon, per-computer grant store, attach lifecycle, foreground notification |
| `app/lib/state/phone_state.dart`, `phone_turn_end.dart` | Stop cancels local turns only when this phone's engine owned the task; the turn link ignores tasks a computer's agent owns |
| UI | Settings › Phone control › **Computers**: a switch per SSH host with its link status, and a sheet with the per-agent setup snippets read from that computer |
| Not done in P1 | Mounting the shim for DSH itself on SSH hosts (so `PhoneBlocker.remoteHost` can go), and a separate foreground notification for the link (it rides the app process, which the engine's foreground service keeps) |
| l10n / guide | `app/lib/l10n/parts/*` zh + en → `l10n_merge.py`; `docs/guide/{zh,en}/04-phone-control.md` and `03-engine-hosts.md` → `guide_sync.py` |

Checks (AGENTS.md):

```bash
node --test host/dsh-go-link/test/*.test.mjs
(cd packages/dsh_link && dart pub get && dart analyze && dart test)
(cd app && flutter pub get && flutter analyze && flutter test)
(cd app/android && gradle :app:testArm64DebugUnitTest)
node host/dsh-go-link/scripts/sync-asset.mjs --check
python3 app/tool/l10n_merge.py --check && python3 app/tool/guide_sync.py --check
```

Real device (required, since this changes phone control): an arm64 phone and a Linux box over SSH. On that setup, check Claude Code, Codex and OpenCode each calling `screen` → `tap` → `handoff`; approval cards naming the origin; Stop during a call; `PHONE_BUSY` while a local DSH task runs; screen-off stop; the app in the background for 10 minutes with the link held; network switch Wi-Fi ↔ mobile and reattach; Antigravity on macOS through an SSH host.

### P2: LAN pairing

Node Noise IK checked against `noise-ik.json` vectors; QR scan → pin → reconnect; a wrong key fails closed; listener off after the pairing window; a test over Tailscale.

### P3: cockpit

Recorded ACP fixtures from each adapter (prompt, tool calls with diffs, permission, cancel, plan) replayed through `AcpTranscript` → `ChatItem` golden tests; daemon resume after a phone disconnect mid-turn; bound phone task ends on `stopReason`; `session/cancel` from the overlay. On a real device: a 30-minute Claude Code task with the phone locked and reconnecting.

### P4: relay

Blocked on the upstream capability. Write the proposal to ds-harness-remote once P1 has shown the protocol.
