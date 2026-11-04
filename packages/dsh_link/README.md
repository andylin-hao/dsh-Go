# dsh_link

Pure-Dart phone end of [dsh-go-link](../../host/dsh-go-link/README.md): the link DSH Go dials to a computer so agents there can use the phone's MCP tools. Design: [docs/design/remote-agents.md](../../docs/design/remote-agents.md).

- `LinkSession.open(input, output, token, phone, mcp)` sends the hello over any byte stream (an SSH direct-tcpip channel in the app), then turns the daemon's frames into `ChannelOpened` / `ChannelData` / `ChannelClosed` events. It pings every 20 s, ends after 50 s of silence, and reports why it ended (`done`; `replaced` means another phone took the computer).
- `LinkMcpRouter` hands each agent channel to the phone (`open` before its first line, `close` for every channel opened) and answers every request, with an error result when the phone side fails.
- `splitLines` splits a byte stream into bounded UTF-8 lines; cancelling it cancels the input at once.

The app wires it in `app/lib/remote/link/phone_link.dart`.

## Tests

```bash
dart test                 # in-memory daemon, plus test/daemon_e2e_test.dart against the real Node daemon (skipped without node)
```
