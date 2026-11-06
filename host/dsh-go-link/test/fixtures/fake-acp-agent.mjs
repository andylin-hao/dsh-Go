// A scripted ACP agent for the tests: what Claude Code, Codex or OpenCode do over ACP, on cue.
// The prompt text picks the script: hello, tool (asks permission), wait (until cancelled),
// phone (calls the phone's `screen` through its MCP server), crash, args (its arguments), env
// (FAKE_VAR). FAKE_AUTH=1 refuses sessions. It lists two sessions of its own in the folder (one
// the daemon made, s-1, and one from "a terminal", t-1) and one elsewhere; load replays a turn.
import { spawn } from 'node:child_process'
import readline from 'node:readline'

let nextId = 1
const pending = new Map()
let mcp = null
const mcpPending = new Map()
let cancelled = null

const out = (msg) => process.stdout.write(JSON.stringify(msg) + '\n')
const request = (method, params) => new Promise((resolve) => {
  const id = 'a' + nextId++
  pending.set(id, resolve)
  out({ jsonrpc: '2.0', id, method, params })
})
const update = (sessionId, u) => out({ jsonrpc: '2.0', method: 'session/update', params: { sessionId, update: u } })
const say = (sessionId, text) => update(sessionId, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text } })
const MODES = () => ({ currentModeId: 'default', availableModes: [{ id: 'default', name: 'Default' }, { id: 'plan', name: 'Plan' }, { id: 'yolo', name: 'Yolo' }] })

function startMcp (server) {
  const child = spawn(server.command, server.args, { stdio: ['pipe', 'pipe', 'inherit'], env: process.env })
  const lines = readline.createInterface({ input: child.stdout })
  lines.on('line', (line) => {
    const msg = JSON.parse(line)
    const resolve = mcpPending.get(msg.id)
    if (resolve) { mcpPending.delete(msg.id); resolve(msg) }
  })
  let n = 1
  const call = (method, params) => new Promise((resolve) => {
    const id = n++
    mcpPending.set(id, resolve)
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')
  })
  call('initialize', { protocolVersion: '2025-06-18', clientInfo: { name: 'fake-agent', version: '1' }, capabilities: {} })
  return { child, call }
}

async function prompt (id, params) {
  const sid = params.sessionId
  const text = params.prompt.map((p) => p.text || '').join('')
  if (text === 'hello') {
    say(sid, 'Hi')
    say(sid, '!')
    return out({ jsonrpc: '2.0', id, result: { stopReason: 'end_turn' } })
  }
  if (text === 'tool') {
    update(sid, { sessionUpdate: 'tool_call', toolCallId: 't1', title: 'Edit notes.md', kind: 'edit', status: 'pending' })
    const answer = await request('session/request_permission', {
      sessionId: sid,
      toolCall: { toolCallId: 't1', title: 'Edit notes.md' },
      options: [{ optionId: 'allow', name: 'Allow', kind: 'allow_once' }, { optionId: 'reject', name: 'Reject', kind: 'reject_once' }]
    })
    const allowed = answer.outcome && answer.outcome.outcome === 'selected' && answer.outcome.optionId === 'allow'
    update(sid, { sessionUpdate: 'tool_call_update', toolCallId: 't1', status: allowed ? 'completed' : 'failed' })
    say(sid, allowed ? 'done' : 'skipped')
    return out({ jsonrpc: '2.0', id, result: { stopReason: 'end_turn' } })
  }
  if (text === 'wait') {
    await new Promise((resolve) => { cancelled = resolve })
    return out({ jsonrpc: '2.0', id, result: { stopReason: 'cancelled' } })
  }
  if (text === 'phone') {
    const r = await mcp.call('tools/call', { name: 'screen', arguments: {} })
    say(sid, 'phone said: ' + (r.result ? r.result.content[0].text : JSON.stringify(r.error)))
    return out({ jsonrpc: '2.0', id, result: { stopReason: 'end_turn' } })
  }
  if (text === 'crash') process.exit(3)
  if (text === 'args') {
    say(sid, 'args: ' + process.argv.slice(2).join(' '))
    return out({ jsonrpc: '2.0', id, result: { stopReason: 'end_turn' } })
  }
  if (text === 'env') {
    say(sid, 'env: ' + [...(process.env.FAKE_VAR || '')].reverse().join(''))
    return out({ jsonrpc: '2.0', id, result: { stopReason: 'end_turn' } })
  }
  say(sid, 'echo: ' + text)
  out({ jsonrpc: '2.0', id, result: { stopReason: 'end_turn' } })
}

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  const msg = JSON.parse(line)
  if (msg.method === undefined) {
    const resolve = pending.get(msg.id)
    if (resolve) { pending.delete(msg.id); resolve(msg.result) }
    return
  }
  switch (msg.method) {
    case 'initialize':
      return out({ jsonrpc: '2.0', id: msg.id, result: { protocolVersion: 1, agentCapabilities: { loadSession: process.env.FAKE_NO_LOAD !== '1', sessionCapabilities: { list: {} } }, authMethods: [] } })
    case 'session/new':
      if (process.env.FAKE_AUTH === '1') return out({ jsonrpc: '2.0', id: msg.id, error: { code: -32000, message: 'Authentication required' } })
      mcp = startMcp(msg.params.mcpServers[0])
      return out({ jsonrpc: '2.0', id: msg.id, result: { sessionId: 's-1', modes: MODES() } })
    case 'session/load': {
      // Replays one turn; comes back in its default mode (the daemon restores what it had).
      mcp = startMcp(msg.params.mcpServers[0])
      const sid = msg.params.sessionId
      update(sid, { sessionUpdate: 'user_message_chunk', content: { type: 'text', text: 'earlier ' } })
      update(sid, { sessionUpdate: 'user_message_chunk', content: { type: 'text', text: 'question' } })
      say(sid, 'replayed history')
      return out({ jsonrpc: '2.0', id: msg.id, result: { modes: MODES() } })
    }
    case 'session/list': {
      const cwd = msg.params.cwd
      return out({
        jsonrpc: '2.0',
        id: msg.id,
        result: {
          sessions: [
            { sessionId: 't-1', cwd, title: 'From the terminal', updatedAt: '2026-01-02T00:00:00Z' },
            // FAKE_S1_UPDATED: s-1 went on elsewhere (a terminal) at that time.
            { sessionId: 's-1', cwd, title: 'Made by the daemon', updatedAt: process.env.FAKE_S1_UPDATED || '2026-01-01T00:00:00Z' },
            { sessionId: 'x-1', cwd: '/elsewhere', title: 'Another folder', updatedAt: '2026-01-03T00:00:00Z' }
          ]
        }
      })
    }
    case 'session/prompt':
      return prompt(msg.id, msg.params)
    case 'session/cancel':
      if (cancelled) cancelled()
      return
    case 'session/set_mode':
      update(msg.params.sessionId, { sessionUpdate: 'current_mode_update', currentModeId: msg.params.modeId })
      return out({ jsonrpc: '2.0', id: msg.id, result: {} })
    default:
      if (msg.id !== undefined) out({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'Method not found' } })
  }
})
