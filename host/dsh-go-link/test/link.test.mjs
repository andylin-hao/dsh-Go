// dsh-go-link: daemon, shim and CLI against a fake phone and fake agents (node --test).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { PassThrough } from 'node:stream'
import { createRequire } from 'node:module'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import fs from 'node:fs'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'

const require = createRequire(import.meta.url)
const SCRIPT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../bin/dsh-go-link.cjs')
const link = require(SCRIPT)
const run = promisify(execFile)

const TOOLS = [{ name: 'screen', description: '读屏', inputSchema: { type: 'object', properties: {} } }]
const CATALOG = { tools: TOOLS, instructions: 'Call screen first.', serverInfo: { name: 'dsh-app-phone', version: '1' } }

function tmpDir () {
  // Short: a unix socket path must fit in ~100 bytes.
  return fs.mkdtempSync(path.join(os.tmpdir(), 'dgl-'))
}

const quietLog = () => {}

async function daemon (opts = {}) {
  const dir = opts.dir || tmpDir()
  const d = new link.Daemon({ dir, log: quietLog, hostName: 'dev-box', ...opts })
  assert.equal(await d.start(), true)
  return d
}

/** A line-oriented socket client with a queue of parsed incoming lines. */
function lineClient (sock) {
  const queue = []
  const waiters = []
  link.readLines(sock, link.MAX_LINE, (line) => {
    const v = JSON.parse(line)
    const w = waiters.shift()
    if (w) w(v); else queue.push(v)
  }, () => sock.destroy())
  return {
    sock,
    send (v) { sock.write((typeof v === 'string' ? v : JSON.stringify(v)) + '\n') },
    next (ms = 3000) {
      if (queue.length) return Promise.resolve(queue.shift())
      return new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new Error('timed out waiting for a line')), ms)
        waiters.push((v) => { clearTimeout(t); resolve(v) })
      })
    },
    pending: () => queue.length,
    closed: () => new Promise((resolve) => sock.destroyed ? resolve() : sock.once('close', resolve))
  }
}

function connect (where) {
  return new Promise((resolve, reject) => {
    const s = where.port ? net.connect(where.port, '127.0.0.1') : net.connect(where)
    s.once('connect', () => resolve(s))
    s.once('error', reject)
  })
}

async function phone (d, { token = d.token, mcp = CATALOG, name = 'Pixel' } = {}) {
  const c = lineClient(await connect({ port: d.port }))
  c.send({ dshGoLink: 1, token, phone: { id: 'p1', name, app: '1.0.10' }, mcp })
  c.hello = await c.next()
  return c
}

async function agent (d, clientName = 'claude-code') {
  const c = lineClient(await connect(d.info().shim.path))
  c.send({ dshGoLinkShim: 1, token: d.shimToken })
  assert.deepEqual(await c.next(), { ok: true })
  c.send({ jsonrpc: '2.0', id: 0, method: 'initialize', params: { protocolVersion: '2025-06-18', clientInfo: { name: clientName, version: '2.0' } } })
  c.init = await c.next()
  return c
}

const call = (id, name = 'screen') => ({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: {} } })

test('without a phone: initialize and tools/list answer locally, tool calls say the phone is missing', async (t) => {
  const d = await daemon()
  t.after(() => d.close())
  const a = await agent(d)
  assert.equal(a.init.result.protocolVersion, '2025-06-18')
  assert.equal(a.init.result.capabilities.tools.listChanged, true)
  assert.equal(a.init.result.serverInfo.name, 'dsh-go-phone')
  a.send({ jsonrpc: '2.0', id: 1, method: 'tools/list' })
  assert.deepEqual((await a.next()).result, { tools: [] })
  a.send(call(2))
  const r = await a.next()
  assert.equal(r.id, 2)
  assert.equal(r.result.isError, true)
  assert.match(r.result.content[0].text, /^\[PHONE_NOT_ATTACHED\]/)
  a.send({ jsonrpc: '2.0', id: 3, method: 'resources/list' })
  assert.equal((await a.next()).error.code, -32601)
  a.send('not json')
  assert.equal((await a.next()).error.code, -32700)
})

test('state files are owner-only, and daemon.json describes both listeners', async (t) => {
  const d = await daemon()
  t.after(() => d.close())
  const info = JSON.parse(fs.readFileSync(path.join(d.dir, 'daemon.json'), 'utf8'))
  assert.equal(info.port, d.port)
  assert.equal(info.pid, process.pid)
  assert.equal(info.version, link.VERSION)
  assert.equal(fs.statSync(d.dir).mode & 0o777, 0o700)
  assert.equal(fs.statSync(path.join(d.dir, 'daemon.json')).mode & 0o777, 0o600)
  const p = await phone(d)
  t.after(() => p.sock.destroy())
  assert.equal(fs.statSync(path.join(d.dir, 'catalog.json')).mode & 0o777, 0o600)
})

test('a phone attaching brings its catalog: list_changed, tools/list, then calls go to the phone with the origin', async (t) => {
  const d = await daemon()
  t.after(() => d.close())
  const a = await agent(d, 'codex-mcp-client')
  const p = await phone(d)
  assert.deepEqual(p.hello, { ok: true, link: { version: link.VERSION, protocol: 1 }, host: { name: 'dev-box', os: process.platform }, caps: link.CAPS })
  assert.equal((await a.next()).method, 'notifications/tools/list_changed')
  a.send({ jsonrpc: '2.0', id: 1, method: 'tools/list' })
  assert.deepEqual((await a.next()).result.tools, TOOLS)
  a.send({ jsonrpc: '2.0', id: 9, method: 'initialize', params: {} })
  assert.equal((await a.next()).result.instructions, 'Call screen first.')

  a.send(call('c1'))
  const open = await p.next()
  assert.equal(open.t, 'open')
  assert.equal(open.kind, 'mcp')
  assert.equal(open.origin.name, 'codex-mcp-client')
  const data = await p.next()
  assert.equal(data.t, 'data')
  assert.equal(data.ch, open.ch)
  assert.equal(JSON.parse(data.line).id, 'c1')
  p.send({ t: 'data', ch: open.ch, line: JSON.stringify({ jsonrpc: '2.0', id: 'c1', result: { content: [{ type: 'text', text: 'ok' }], isError: false } }) })
  const r = await a.next()
  assert.equal(r.id, 'c1')
  assert.equal(r.result.content[0].text, 'ok')

  // The second call reuses the open channel.
  a.send(call(2))
  assert.equal((await p.next()).t, 'data')

  // Same catalog on the next attach: no list_changed.
  p.sock.destroy()
  assert.match((await a.next()).result.content[0].text, /dropped during this call/)
  const p2 = await phone(d)
  t.after(() => p2.sock.destroy())
  a.send({ jsonrpc: '2.0', id: 3, method: 'ping' })
  assert.deepEqual((await a.next()), { jsonrpc: '2.0', id: 3, result: {} })
})

test('a dropped phone fails every pending call, and a phone close frame fails that channel only', async (t) => {
  const d = await daemon()
  t.after(() => d.close())
  const p = await phone(d)
  const a = await agent(d)
  const b = await agent(d, 'opencode')
  a.send(call(1))
  b.send(call(1))
  const openA = await p.next()
  await p.next()
  const openB = await p.next()
  await p.next()
  assert.notEqual(openA.ch, openB.ch)
  assert.equal(openB.origin.name, 'opencode')
  p.send({ t: 'close', ch: openA.ch, message: '[ACCESS_OFF] closed' })
  assert.equal((await a.next()).result.content[0].text, '[ACCESS_OFF] closed')
  assert.equal(b.pending(), 0)
  p.sock.destroy()
  const r = await b.next()
  assert.equal(r.result.isError, true)
  assert.match(r.result.content[0].text, /^\[PHONE_NOT_ATTACHED\]/)
  b.send(call(2))
  assert.match((await b.next()).result.content[0].text, /not connected/)
})

test('a phone with the wrong token or protocol is refused', async (t) => {
  const d = await daemon()
  t.after(() => d.close())
  const bad = await phone(d, { token: 'nope' })
  assert.deepEqual(bad.hello, { ok: false, code: 'bad_token' })
  await bad.closed()
  const c = lineClient(await connect({ port: d.port }))
  c.send({ dshGoLink: 2, token: d.token })
  assert.deepEqual(await c.next(), { ok: false, code: 'protocol', protocol: 1 })
  assert.equal(d.phone, null)
  const shim = lineClient(await connect(d.info().shim.path))
  shim.send({ dshGoLinkShim: 1, token: 'nope' })
  assert.deepEqual(await shim.next(), { ok: false, code: 'bad_token' })
})

test('a second phone replaces the first, and a silent phone is dropped', async (t) => {
  const d = await daemon({ idleMs: 300 })
  t.after(() => d.close())
  const first = await phone(d, { name: 'old' })
  const second = await phone(d, { name: 'new' })
  assert.deepEqual(await first.next(), { t: 'bye', code: 'replaced' })
  assert.equal(d.status().phone.name, 'new')
  second.send({ t: 'ping' })
  assert.deepEqual(await second.next(), { t: 'pong' })
  assert.deepEqual(await second.next(1500), { t: 'bye', code: 'idle' })
  assert.equal(d.phone, null)
})

test('the shim answers offline from catalog.json, then connects, replays initialize and reports list_changed', async (t) => {
  const dir = tmpDir()
  fs.writeFileSync(path.join(dir, 'catalog.json'), JSON.stringify(CATALOG))
  let d = null
  let allowStart = false
  const start = async () => {
    if (!allowStart) throw new Error('no daemon yet')
    return d.info()
  }
  const input = new PassThrough()
  const output = new PassThrough()
  const out = lineClient(output)
  const shim = link.runShim({ dir, input, output, start, retryMs: 50 })
  t.after(() => { shim.close(); input.end(); return d && d.close() })

  input.write(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { clientInfo: { name: 'antigravity' } } }) + '\n')
  assert.equal((await out.next()).result.instructions, 'Call screen first.')
  input.write(JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list' }) + '\n')
  assert.deepEqual((await out.next()).result.tools, TOOLS)
  input.write(JSON.stringify(call(3)) + '\n')
  assert.match((await out.next()).result.content[0].text, /PHONE_NOT_ATTACHED/)

  d = await daemon({ dir })
  allowStart = true
  assert.equal((await out.next(3000)).method, 'notifications/tools/list_changed')
  await waitFor(() => [...d.channels.values()].some((c) => c.client && c.client.name === 'antigravity'))

  const p = await phone(d)
  input.write(JSON.stringify(call(4)) + '\n')
  const open = await p.next()
  assert.equal(open.origin.name, 'antigravity')
  const data = await p.next()
  assert.equal(JSON.parse(data.line).id, 4)

  // The daemon goes away mid-call: the shim answers the lost call and reconnects to the next one.
  await d.close()
  assert.match((await out.next()).result.content[0].text, /dropped during this call/)
  d = await daemon({ dir })
  await waitFor(() => [...d.channels.values()].some((c) => c.client && c.client.name === 'antigravity'), 5000)
  p.sock.destroy()
})

test('CLI: start spawns one daemon, status reports it, start again reuses it, stop ends it', async (t) => {
  const dir = tmpDir()
  const env = { ...process.env, DSH_GO_LINK_HOME: dir }
  const cli = (...args) => run(process.execPath, [SCRIPT, ...args], { env })
  t.after(() => cli('stop').catch(() => {}))
  const tagged = (out) => JSON.parse(out.stdout.split('\n').find((l) => l.startsWith('DSHGOLINK ')).slice(10))
  const first = tagged(await cli('start', '--json'))
  assert.equal(first.version, link.VERSION)
  assert.ok(first.port > 0)
  assert.match(first.token, /^[0-9a-f]{64}$/)
  const again = tagged(await cli('start', '--json'))
  assert.equal(again.pid, first.pid)
  const status = tagged(await cli('status', '--json'))
  assert.equal(status.pid, first.pid)
  assert.equal(status.phone, null)
  assert.equal(JSON.stringify(status).includes(first.token), false)
  assert.equal((await cli('stop')).stdout, 'stopped\n')
  await waitFor(async () => (await cli('status')).stdout === 'not running\n', 5000)
})

test('CLI: config prints a snippet per agent with this machine\'s node and script', async () => {
  const { stdout } = await run(process.execPath, [SCRIPT, 'config', '--json'])
  const cfg = JSON.parse(stdout.slice('DSHGOLINK '.length))
  assert.deepEqual(cfg.agents.map((a) => a.id), ['claude-code', 'codex', 'opencode', 'antigravity', 'antigravity-ide', 'other'])
  const byId = Object.fromEntries(cfg.agents.map((a) => [a.id, a]))
  assert.equal(byId['claude-code'].text, `claude mcp add --scope user phone -- ${process.execPath} ${SCRIPT} mcp`)
  assert.match(byId.codex.text, /^\[mcp_servers\.phone\]\ncommand = ".+"\nargs = \[".+", "mcp"\]\ntool_timeout_sec = 660\n$/)
  assert.deepEqual(JSON.parse(byId.opencode.text).mcp.phone.command, [process.execPath, SCRIPT, 'mcp'])
  assert.equal(byId.antigravity.text, `agy mcp add phone -- ${process.execPath} ${SCRIPT} mcp`)
  assert.deepEqual(JSON.parse(byId['antigravity-ide'].text).mcpServers.phone, { command: process.execPath, args: [SCRIPT, 'mcp'] })
  const one = await run(process.execPath, [SCRIPT, 'config', 'codex'])
  assert.match(one.stdout, /^# Codex — add to ~\/\.codex\/config\.toml\n\[mcp_servers\.phone\]/)
  await assert.rejects(run(process.execPath, [SCRIPT, 'config', 'nope']), (e) => e.code === 2)
})

test('the agent snippets quote paths with spaces', () => {
  const [claude] = link.agentConfigs('/opt/my node/node', "/home/o'neil/x.cjs")
  assert.equal(claude.text, "claude mcp add --scope user phone -- '/opt/my node/node' '/home/o'\\''neil/x.cjs' mcp")
})

test('readLines splits, strips CR and refuses an over-long line', async () => {
  const s = new PassThrough()
  const lines = []
  let tooLong = false
  link.readLines(s, 8, (l) => lines.push(l), () => { tooLong = true })
  s.write('ab\r\ncd')
  s.write('e\n')
  s.write('0123456789\n')
  s.write('after\n')
  await new Promise((resolve) => setImmediate(resolve))
  assert.deepEqual(lines, ['ab', 'cde'])
  assert.equal(tooLong, true)
})

async function waitFor (fn, ms = 2000) {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) {
    if (await fn()) return
    await new Promise((resolve) => setTimeout(resolve, 25))
  }
  throw new Error('condition not met in ' + ms + ' ms')
}

test('an idle daemon exits; a phone, an agent or a network listener keeps it', async (t) => {
  let exited = 0
  const d = await daemon({ idleExitMs: 200, onIdle: () => exited++ })
  t.after(() => d.close())
  const p = await phone(d)
  d.idleSince = 0
  d.checkIdle()
  assert.equal(exited, 0)
  p.sock.destroy()
  await new Promise((resolve) => setTimeout(resolve, 50))
  d.idleSince = Date.now() - 1000
  d.checkIdle()
  await new Promise((resolve) => setTimeout(resolve, 50))
  assert.equal(exited, 1)
  assert.equal(d.closed, true)
})
