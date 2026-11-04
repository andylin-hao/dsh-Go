// The phone as the cockpit: ACP sessions run by the daemon, driven over the link's RPC frames,
// against a scripted agent (fixtures/fake-acp-agent.mjs).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { link, tmpDir, lineClient, connect, quietLog, waitFor } from './support.mjs'

const FAKE = path.resolve(path.dirname(new URL(import.meta.url).pathname), 'fixtures/fake-acp-agent.mjs')

async function setup (t, { env = {} } = {}) {
  const dir = tmpDir()
  fs.writeFileSync(path.join(dir, 'agents.json'), JSON.stringify({
    fake: { name: 'Fake Agent', command: [process.execPath, FAKE], bypass: { mode: 'yolo' } },
    'fake-args': { name: 'Fake Args', command: [process.execPath, FAKE], bypass: { args: ['--skip'] } }
  }))
  // The agent's MCP shim (`dsh-go-link mcp --bind`) finds this daemon through the environment.
  const before = { ...process.env }
  // The shim must not start a daemon of its own once this one is closed (it would outlive the test).
  Object.assign(process.env, { DSH_GO_LINK_HOME: dir, DSH_GO_LINK_NO_AUTOSTART: '1', ...env })
  const d = new link.Daemon({ dir, log: quietLog, hostName: 'dev-box' })
  assert.equal(await d.start(), true)
  const phone = await attach(d)
  t.after(async () => {
    phone.sock.destroy()
    await d.close()
    for (const k of Object.keys(process.env)) if (!(k in before)) delete process.env[k]
    Object.assign(process.env, before)
  })
  return { d, dir, phone }
}

async function attach (d) {
  const c = lineClient(await connect({ port: d.port }))
  c.send({ dshGoLink: 1, token: d.token, phone: { id: 'p', name: 'Pixel' }, mcp: { tools: [{ name: 'screen' }], instructions: 'x' } })
  c.hello = await c.next()
  let id = 0
  c.call = async (method, params = {}) => {
    const mine = ++id
    c.send({ t: 'call', id: mine, method, params })
    const r = await c.until((f) => f.t === 'result' && f.id === mine)
    if (r.error) throw Object.assign(new Error(r.error.message), { code: r.error.code })
    return r.result
  }
  c.event = (pred, ms) => c.until((f) => f.t === 'event' && pred(f), ms)
  c.sessionEvent = (id, pred, ms) => c.event((f) => f.name === 'session' && f.data.id === id && pred(f.data.event), ms).then((f) => f.data.event)
  return c
}

test('agents are listed with whether they can run here', async (t) => {
  const { phone } = await setup(t)
  const { agents } = await phone.call('agents.list')
  assert.deepEqual(agents.find((a) => a.id === 'fake'), { id: 'fake', name: 'Fake Agent', available: true, bypass: 'mode' })
  assert.equal(agents.find((a) => a.id === 'fake-args').bypass, 'restart')
  assert.deepEqual(agents.map((a) => a.id).slice(0, 5), ['claude-code', 'codex', 'antigravity', 'opencode', 'gemini'])
  assert.deepEqual(agents.slice(0, 5).map((a) => a.bypass), ['mode', 'mode', 'restart', null, null])
  assert.ok(phone.hello.caps.includes('agents.acp.v2'))
  const setup2 = await phone.call('setup.agents')
  assert.equal(setup2.agents[0].id, 'claude-code')
})

test('a session: new, prompt, streamed updates, turn end; the summary follows', async (t) => {
  const { phone, dir } = await setup(t)
  const { session } = await phone.call('sessions.new', { agent: 'fake', cwd: dir })
  assert.equal(session.agentName, 'Fake Agent')
  assert.equal(session.cwd, dir)
  await phone.event((f) => f.name === 'sessions' && f.data.id === session.id && f.data.status === 'idle')
  await phone.call('sessions.prompt', { id: session.id, text: 'hello' })
  const user = await phone.sessionEvent(session.id, (e) => e.kind === 'user')
  assert.equal(user.text, 'hello')
  const chunks = []
  const end = await phone.sessionEvent(session.id, (e) => {
    if (e.kind === 'update') chunks.push(e.update.content.text)
    return e.kind === 'turn_end'
  })
  assert.deepEqual(chunks, ['Hi', '!'])
  assert.equal(end.stopReason, 'end_turn')
  await phone.event((f) => f.name === 'turn_end' && f.data.id === session.id)
  const { sessions } = await phone.call('sessions.list')
  assert.equal(sessions.length, 1)
  assert.equal(sessions[0].title, 'hello')
  assert.equal(sessions[0].modes.currentModeId, 'default')
  // Busy while running; a second prompt is refused.
  await phone.call('sessions.prompt', { id: session.id, text: 'wait' })
  await assert.rejects(phone.call('sessions.prompt', { id: session.id, text: 'again' }), (e) => e.code === 'busy')
  await phone.call('sessions.cancel', { id: session.id })
  assert.equal((await phone.sessionEvent(session.id, (e) => e.kind === 'turn_end')).stopReason, 'cancelled')
})

test('permission requests reach the phone and its answer goes back to the agent', async (t) => {
  const { phone, dir } = await setup(t)
  const { session } = await phone.call('sessions.new', { agent: 'fake', cwd: dir })
  await phone.call('sessions.prompt', { id: session.id, text: 'tool' })
  const ask = await phone.sessionEvent(session.id, (e) => e.kind === 'permission')
  assert.equal(ask.toolCall.title, 'Edit notes.md')
  assert.deepEqual(ask.options.map((o) => o.optionId), ['allow', 'reject'])
  const summary = await phone.event((f) => f.name === 'sessions' && f.data.pending.length === 1)
  assert.deepEqual(summary.data.pending, [ask.requestId])
  await phone.call('sessions.permission', { id: session.id, requestId: ask.requestId, optionId: 'allow' })
  const done = await phone.sessionEvent(session.id, (e) => e.kind === 'update' && e.update.sessionUpdate === 'tool_call_update')
  assert.equal(done.update.status, 'completed')
  await phone.sessionEvent(session.id, (e) => e.kind === 'turn_end')
  await assert.rejects(phone.call('sessions.permission', { id: session.id, requestId: ask.requestId, optionId: 'allow' }), (e) => e.code === 'stale')
})

test('the session\'s agent uses this phone\'s tools, and the phone knows which session asks', async (t) => {
  const { d, phone, dir } = await setup(t)
  const { session } = await phone.call('sessions.new', { agent: 'fake', cwd: dir })
  // The agent starts its MCP server with the session; wait until that shim reached the daemon.
  await waitFor(() => [...d.channels.values()].some((c) => c.session && c.session.id === session.id && c.initialized))
  await phone.call('sessions.prompt', { id: session.id, text: 'phone' })
  const open = await phone.until((f) => f.t === 'open')
  assert.equal(open.origin.name, 'fake-agent')
  assert.equal(open.origin.session, session.id)
  assert.equal(open.origin.agent, 'fake')
  const call = await phone.until((f) => f.t === 'data' && f.ch === open.ch)
  const req = JSON.parse(call.line)
  assert.equal(req.params.name, 'screen')
  phone.send({ t: 'data', ch: open.ch, line: JSON.stringify({ jsonrpc: '2.0', id: req.id, result: { content: [{ type: 'text', text: 'home screen' }] } }) })
  const said = await phone.sessionEvent(session.id, (e) => e.kind === 'update' && /phone said/.test(e.update.content.text))
  assert.equal(said.update.content.text, 'phone said: home screen')
})

test('sessions outlive the daemon: history is kept and the agent resumes with session/load', async (t) => {
  const { d, dir, phone } = await setup(t)
  const { session } = await phone.call('sessions.new', { agent: 'fake', cwd: dir })
  await phone.call('sessions.prompt', { id: session.id, text: 'hello' })
  await phone.sessionEvent(session.id, (e) => e.kind === 'turn_end')
  phone.sock.destroy()
  await d.close()

  const d2 = new link.Daemon({ dir, log: quietLog, hostName: 'dev-box' })
  assert.equal(await d2.start(), true)
  t.after(() => d2.close())
  const p2 = await attach(d2)
  t.after(() => p2.sock.destroy())
  const { sessions } = await p2.call('sessions.list')
  assert.equal(sessions[0].status, 'stopped')
  const watched = await p2.call('sessions.watch', { id: session.id, afterSeq: 0 })
  assert.deepEqual(watched.events.map((e) => e.kind).filter((k) => k !== 'update'), ['user', 'turn_end'])
  const last = watched.events[watched.events.length - 1].seq
  const tail = await p2.call('sessions.watch', { id: session.id, afterSeq: last - 1 })
  assert.equal(tail.events.length, 1)

  await p2.call('sessions.prompt', { id: session.id, text: 'next' })
  const echo = await p2.sessionEvent(session.id, (e) => e.kind === 'update')
  // The replayed history was not appended again: the first new update is the answer.
  assert.equal(echo.update.content.text, 'echo: next')
  await p2.sessionEvent(session.id, (e) => e.kind === 'turn_end')
  const again = await p2.call('sessions.watch', { id: session.id, afterSeq: 0 })
  assert.equal(again.events.filter((e) => e.kind === 'notice').length, 0)
})

test('an agent that crashes mid-turn, or wants a sign-in, says so in the log', async (t) => {
  const { phone, dir } = await setup(t)
  const { session } = await phone.call('sessions.new', { agent: 'fake', cwd: dir })
  await phone.call('sessions.prompt', { id: session.id, text: 'crash' })
  const err = await phone.sessionEvent(session.id, (e) => e.kind === 'error')
  assert.ok(['agent_exited', 'agent_gone'].includes(err.code), err.code)
  await phone.event((f) => f.name === 'sessions' && f.data.id === session.id && f.data.status === 'stopped')

  process.env.FAKE_AUTH = '1'
  const { session: s2 } = await phone.call('sessions.new', { agent: 'fake', cwd: dir })
  const auth = await phone.sessionEvent(s2.id, (e) => e.kind === 'error')
  assert.equal(auth.code, 'auth_required')
  delete process.env.FAKE_AUTH
})

test('modes, closing, folders, and refusals', async (t) => {
  const { phone, dir } = await setup(t)
  fs.mkdirSync(path.join(dir, 'proj'))
  fs.mkdirSync(path.join(dir, '.hidden'))
  const listing = await phone.call('fs.list', { path: dir })
  assert.deepEqual(listing.dirs, ['proj', 'sessions'])
  assert.equal(listing.parent, path.dirname(dir))
  await assert.rejects(phone.call('sessions.new', { agent: 'nope', cwd: dir }), (e) => e.code === 'agent_unavailable')
  await assert.rejects(phone.call('sessions.new', { agent: 'fake', cwd: path.join(dir, 'missing') }), (e) => e.code === 'no_folder')
  await assert.rejects(phone.call('nope.nope'), (e) => e.code === 'unknown_method')

  const { session } = await phone.call('sessions.new', { agent: 'fake', cwd: path.join(dir, 'proj') })
  await phone.call('sessions.mode', { id: session.id, modeId: 'plan' })
  await phone.event((f) => f.name === 'sessions' && f.data.id === session.id && f.data.modes && f.data.modes.currentModeId === 'plan')
  await phone.call('sessions.close', { id: session.id })
  await waitFor(async () => (await phone.call('sessions.list')).sessions.length === 0)
  await assert.rejects(phone.call('sessions.prompt', { id: session.id, text: 'x' }), (e) => e.code === 'closed')
})

/** The text of the agent's next message in [id]. */
const said = (phone, id) => phone.sessionEvent(id, (e) => e.kind === 'update' && e.update.sessionUpdate === 'agent_message_chunk').then((e) => e.update.content.text)

test('the environment the phone sets reaches the agent, and is never written to disk', async (t) => {
  const { d, phone, dir } = await setup(t)
  const secret = 'sk-test-' + 'x'.repeat(24)
  const { session } = await phone.call('sessions.new', { agent: 'fake', cwd: dir, env: { FAKE_VAR: secret } })
  await phone.call('sessions.prompt', { id: session.id, text: 'env' })
  // The agent answers with it reversed: the daemon logs what agents say, never what it was given.
  assert.equal(await said(phone, session.id), 'env: ' + [...secret].reverse().join(''))
  await phone.sessionEvent(session.id, (e) => e.kind === 'turn_end')
  for (const bad of [{ 'NOT-A-NAME': 'x' }, { A: 1 }, ['A=1'], 'A=1']) {
    await assert.rejects(phone.call('sessions.new', { agent: 'fake', cwd: dir, env: bad }), (e) => e.code === 'bad_env')
  }
  // A later request's environment applies when the agent next starts (here: after a restart).
  await d.session(session.id).stopProcess()
  await phone.call('sessions.prompt', { id: session.id, text: 'env', env: { FAKE_VAR: 'second' } })
  assert.equal(await said(phone, session.id), 'env: dnoces')
  await phone.sessionEvent(session.id, (e) => e.kind === 'turn_end')
  const onDisk = fs.readdirSync(path.join(dir, 'sessions')).map((f) => fs.readFileSync(path.join(dir, 'sessions', f), 'utf8')).join('\n') +
    fs.readFileSync(path.join(dir, 'agents.json'), 'utf8')
  assert.ok(!onDisk.includes(secret))
  assert.ok(!onDisk.includes('second'))
})

test('bypass with a mode: asked at creation, switched off and on, kept across a daemon restart', async (t) => {
  const { d, phone, dir } = await setup(t)
  const { session } = await phone.call('sessions.new', { agent: 'fake', cwd: dir, bypass: true })
  assert.equal(session.bypass, true)
  const ready = await phone.event((f) => f.name === 'sessions' && f.data.id === session.id && f.data.status === 'idle')
  assert.equal(ready.data.modes.currentModeId, 'yolo')
  assert.equal(ready.data.bypass, true)
  const off = await phone.call('sessions.bypass', { id: session.id, on: false })
  assert.equal(off.session.bypass, false)
  assert.equal(off.session.modes.currentModeId, 'default')
  await phone.call('sessions.mode', { id: session.id, modeId: 'plan' })
  const on = await phone.call('sessions.bypass', { id: session.id, on: true })
  assert.equal(on.session.modes.currentModeId, 'yolo')
  // Off again goes back to the mode it had before (plan), not the agent's first.
  assert.equal((await phone.call('sessions.bypass', { id: session.id, on: false })).session.modes.currentModeId, 'plan')
  await phone.call('sessions.bypass', { id: session.id, on: true })
  phone.sock.destroy()
  await d.close()

  const d2 = new link.Daemon({ dir, log: quietLog, hostName: 'dev-box' })
  assert.equal(await d2.start(), true)
  t.after(() => d2.close())
  const p2 = await attach(d2)
  t.after(() => p2.sock.destroy())
  // The agent comes back in its default mode; the daemon sets bypass again before the turn.
  await p2.call('sessions.watch', { id: session.id, afterSeq: 0 })
  await p2.call('sessions.prompt', { id: session.id, text: 'hello' })
  await p2.sessionEvent(session.id, (e) => e.kind === 'turn_end')
  const { sessions } = await p2.call('sessions.list')
  assert.equal(sessions[0].modes.currentModeId, 'yolo')
  assert.equal(sessions[0].bypass, true)
  await assert.rejects(p2.call('sessions.bypass', { id: 'nope', on: true }), (e) => e.code === 'no_session')
})

test('bypass with arguments: the agent restarts with them between turns, never during one', async (t) => {
  const { phone, dir } = await setup(t)
  const { session } = await phone.call('sessions.new', { agent: 'fake-args', cwd: dir })
  await phone.call('sessions.prompt', { id: session.id, text: 'args' })
  assert.equal(await said(phone, session.id), 'args: ')
  await phone.sessionEvent(session.id, (e) => e.kind === 'turn_end')
  await phone.call('sessions.prompt', { id: session.id, text: 'wait' })
  await assert.rejects(phone.call('sessions.bypass', { id: session.id, on: true }), (e) => e.code === 'busy')
  await phone.call('sessions.cancel', { id: session.id })
  await phone.sessionEvent(session.id, (e) => e.kind === 'turn_end')
  await waitFor(async () => (await phone.call('sessions.list')).sessions[0].status === 'idle')
  const on = await phone.call('sessions.bypass', { id: session.id, on: true })
  assert.equal(on.session.bypass, true)
  assert.equal(on.session.status, 'stopped')
  await phone.call('sessions.prompt', { id: session.id, text: 'args' })
  assert.equal(await said(phone, session.id), 'args: --skip')
  await phone.sessionEvent(session.id, (e) => e.kind === 'turn_end')
  // No error from the restart: it happened while idle.
  const { events } = await phone.call('sessions.watch', { id: session.id, afterSeq: 0 })
  assert.equal(events.filter((e) => e.kind === 'error').length, 0)
})

test('an agent without a way to skip permissions refuses bypass', async (t) => {
  const { phone, dir } = await setup(t)
  fs.writeFileSync(path.join(dir, 'agents.json'), JSON.stringify({ plain: { name: 'Plain', command: [process.execPath, FAKE] } }))
  await new Promise((resolve) => setTimeout(resolve, 3100)) // the registry is re-read every few seconds
  const { session } = await phone.call('sessions.new', { agent: 'plain', cwd: dir, bypass: true })
  assert.equal(session.bypass, false)
  await assert.rejects(phone.call('sessions.bypass', { id: session.id, on: true }), (e) => e.code === 'bypass_unsupported')
})

test('a folder\'s earlier sessions: ours open as they are (a running turn goes on), others resume with their history', async (t) => {
  const { phone, dir } = await setup(t)
  const { session } = await phone.call('sessions.new', { agent: 'fake', cwd: dir })
  await phone.event((f) => f.name === 'sessions' && f.data.id === session.id && f.data.status === 'idle')
  await phone.call('sessions.prompt', { id: session.id, text: 'wait' })

  const history = await phone.call('sessions.history', { agent: 'fake', cwd: dir })
  assert.equal(history.listed, true)
  assert.equal(history.canLoad, true)
  // The terminal's session, and ours once (not again as the agent's s-1); the other folder's is left out.
  assert.deepEqual(history.sessions.map((x) => x.agentSessionId), ['s-1', 't-1'])
  assert.equal(history.sessions[0].session.id, session.id)
  assert.equal(history.sessions[0].session.status, 'running')
  assert.equal(history.sessions[1].session, null)
  assert.equal(history.sessions[1].title, 'From the terminal')

  // Resuming ours: the same session, still running; nothing restarted.
  const again = await phone.call('sessions.resume', { agent: 'fake', agentSessionId: 's-1', cwd: dir })
  assert.equal(again.attached, true)
  assert.equal(again.session.id, session.id)
  assert.equal(again.session.status, 'running')

  // Resuming the terminal's: a new session here, its history taken from the agent's replay.
  const resumed = await phone.call('sessions.resume', { agent: 'fake', agentSessionId: 't-1', cwd: dir, title: 'From the terminal' })
  assert.equal(resumed.attached, false)
  assert.equal(resumed.session.title, 'From the terminal')
  await phone.sessionEvent(resumed.session.id, (e) => e.kind === 'notice' && e.code === 'resumed')
  const { events } = await phone.call('sessions.watch', { id: resumed.session.id, afterSeq: 0 })
  assert.deepEqual(events.map((e) => e.kind), ['user', 'update', 'notice'])
  assert.equal(events[0].text, 'earlier question')
  assert.equal(events[1].update.content.text, 'replayed history')
  // It goes on from there; a later restart does not replay it again.
  await phone.call('sessions.prompt', { id: resumed.session.id, text: 'hello' })
  await phone.sessionEvent(resumed.session.id, (e) => e.kind === 'turn_end')

  // The first session's turn was never cut: cancelling it now ends it as cancelled.
  await phone.call('sessions.cancel', { id: session.id })
  assert.equal((await phone.sessionEvent(session.id, (e) => e.kind === 'turn_end')).stopReason, 'cancelled')
  await assert.rejects(phone.call('sessions.resume', { agent: 'fake', cwd: dir }), (e) => e.code === 'no_session')
  await assert.rejects(phone.call('sessions.history', { agent: 'fake', cwd: path.join(dir, 'missing') }), (e) => e.code === 'no_folder')
})

test('resuming on an agent that cannot load says so instead of starting over', async (t) => {
  const { phone, dir } = await setup(t, { env: { FAKE_NO_LOAD: '1' } })
  const history = await phone.call('sessions.history', { agent: 'fake', cwd: dir })
  assert.equal(history.canLoad, false)
  const { session } = await phone.call('sessions.resume', { agent: 'fake', agentSessionId: 't-1', cwd: dir })
  const err = await phone.sessionEvent(session.id, (e) => e.kind === 'error')
  assert.equal(err.code, 'resume_unsupported')
})

test('retire: a daemon asked to make way keeps running while an agent works, then stops', async (t) => {
  const { d, phone, dir } = await setup(t)
  let stopped = false
  d.onShutdown = () => { stopped = true }
  const { session } = await phone.call('sessions.new', { agent: 'fake', cwd: dir })
  await phone.event((f) => f.name === 'sessions' && f.data.id === session.id && f.data.status === 'idle')
  await phone.call('sessions.prompt', { id: session.id, text: 'wait' })
  assert.equal(d.status().busy, 1)
  assert.deepEqual(await d.onOp('retire', {}), { busy: 1 })
  await new Promise((resolve) => setTimeout(resolve, 200))
  assert.equal(d.closed, false)
  await phone.call('sessions.cancel', { id: session.id })
  await waitFor(() => stopped)
  assert.equal(d.closed, true)
})

test('start of another version leaves a busy daemon running, asked to retire', async (t) => {
  const { d, phone, dir } = await setup(t)
  const { session } = await phone.call('sessions.new', { agent: 'fake', cwd: dir })
  await phone.event((f) => f.name === 'sessions' && f.data.id === session.id && f.data.status === 'idle')
  await phone.call('sessions.prompt', { id: session.id, text: 'wait' })
  // This daemon pretends to be an older copy than the one `start` belongs to.
  const status = d.status.bind(d)
  d.status = () => ({ ...status(), version: '0.0.1-older' })
  const info = await link.ensureDaemon(dir, { replace: true })
  assert.equal(info.pid, process.pid) // the same daemon, not a new one
  assert.equal(d.retiring, true)
  assert.equal(d.closed, false)
  // Its agent's turn was never cut: it ends when cancelled, and the daemon then makes way.
  await phone.call('sessions.cancel', { id: session.id })
  assert.equal((await phone.sessionEvent(session.id, (e) => e.kind === 'turn_end')).stopReason, 'cancelled')
  await waitFor(() => d.closed)
})
