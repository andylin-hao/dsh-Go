// Network pairing: Noise IK against the shared vectors, the daemon's listener, one-time pairing.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import fs from 'node:fs'
import path from 'node:path'
import { SCRIPT, link, tmpDir, lineClient, connect, quietLog } from './support.mjs'

const run = promisify(execFile)
const VECTORS = path.resolve(path.dirname(SCRIPT), '../../../packages/dsh_remote/test/fixtures/noise-ik.json')
const b = (s) => Buffer.from(s, 'base64url')

test('Noise IK matches the shared vectors byte for byte, both ways', () => {
  const { vectors } = JSON.parse(fs.readFileSync(VECTORS, 'utf8'))
  for (const v of vectors) {
    const keys = (who) => link.x25519KeyPair(b(v.staticKeys[who].privateKey))
    const i = new link.NoiseIK({ initiator: true, s: keys('initiator'), rs: b(v.staticKeys.responder.publicKey), prologue: b(v.prologue.bytes), e: b(v.ephemeralPrivateKeys.initiator) })
    const r = new link.NoiseIK({ initiator: false, s: keys('responder'), prologue: b(v.prologue.bytes), e: b(v.ephemeralPrivateKeys.responder) })
    assert.equal(link.x25519KeyPair(b(v.staticKeys.initiator.privateKey)).pub.toString('base64url'), v.staticKeys.initiator.publicKey)
    const m1 = i.writeMessage1(b(v.handshake.message1.payload))
    assert.equal(m1.toString('base64url'), v.handshake.message1.message)
    assert.equal(r.readMessage1(m1).toString('base64url'), v.handshake.message1.payload)
    assert.equal(r.rs.toString('base64url'), v.staticKeys.initiator.publicKey)
    const m2 = r.writeMessage2(b(v.handshake.message2.payload))
    assert.equal(m2.toString('base64url'), v.handshake.message2.message)
    assert.equal(i.readMessage2(m2).toString('base64url'), v.handshake.message2.payload)
    for (const t of v.transport) {
      const [from, to] = t.sender === 'initiator' ? [i, r] : [r, i]
      const ct = from.send.encrypt(Buffer.alloc(0), b(t.plaintext))
      assert.equal(ct.toString('base64url'), t.ciphertext)
      assert.equal(to.recv.decrypt(Buffer.alloc(0), ct).toString('base64url'), t.plaintext)
    }
    // A flipped bit fails authentication.
    const ct = i.send.encrypt(Buffer.alloc(0), Buffer.from('x'))
    ct[0] ^= 1
    assert.throws(() => r.recv.decrypt(Buffer.alloc(0), ct))
  }
})

/** A phone over the network: TCP, Noise IK as initiator, then the link protocol inside. */
async function lanPhone (d, { keys = link.x25519KeyPair(), pair = null, name = 'Pixel' } = {}) {
  const sock = await connect({ port: d.lanPort })
  const noise = new link.NoiseIK({ initiator: true, s: keys, rs: d.identity.pub })
  sock.write(link.frame(noise.writeMessage1()))
  const msg2 = await new Promise((resolve, reject) => {
    const reader = new link.FrameReader((m) => { resolve(m); return false })
    sock.once('data', (data) => reader.feed(data))
    sock.once('close', () => reject(new Error('closed during the handshake')))
  })
  noise.readMessage2(msg2)
  const stream = new link.SecureStream(sock, noise)
  const c = lineClient(stream)
  c.send({ dshGoLink: 1, token: '', phone: { id: 'p', name }, pair, mcp: { tools: [{ name: 'screen' }] } })
  c.hello = await c.next()
  c.keys = keys
  c.raw = sock
  return c
}

async function daemon (dir = tmpDir()) {
  const d = new link.Daemon({ dir, log: quietLog, hostName: 'dev-box' })
  assert.equal(await d.start(), true)
  return d
}

test('pairing: one-time secret, then the paired key alone; others and late secrets are refused', async (t) => {
  const d = await daemon()
  t.after(() => d.close())
  const p = await d.onOp('pair', {})
  assert.equal(p.key, d.identity.pub.toString('base64url'))
  assert.match(p.secret, /^[A-Za-z0-9_-]{22}$/)
  assert.ok(p.port > 0)

  const phone = await lanPhone(d, { pair: p.secret })
  assert.equal(phone.hello.ok, true)
  assert.deepEqual(phone.hello.caps, link.CAPS)
  assert.equal(d.peers.length, 1)
  assert.equal(d.peers[0].name, 'Pixel')
  assert.equal(fs.statSync(path.join(d.dir, 'peers.json')).mode & 0o777, 0o600)
  assert.equal((await d.onOp('pair-status', {})).pending, false)

  // A call from an agent goes to the phone through the encrypted link.
  const agent = lineClient(await connect(d.info().shim.path))
  agent.send({ dshGoLinkShim: 1, token: d.shimToken })
  await agent.next()
  agent.send({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'screen' } })
  const open = await phone.next()
  assert.equal(open.t, 'open')
  const data = await phone.next()
  phone.send({ t: 'data', ch: data.ch, line: JSON.stringify({ jsonrpc: '2.0', id: 1, result: { content: [{ type: 'text', text: 'ok' }] } }) })
  assert.equal((await agent.next()).result.content[0].text, 'ok')
  agent.sock.destroy()

  // The same key later: no secret needed (it replaces the first connection).
  const again = await lanPhone(d, { keys: phone.keys })
  assert.equal(again.hello.ok, true)
  // Another key, without a secret or with the used one: refused.
  assert.deepEqual((await lanPhone(d)).hello, { ok: false, code: 'not_paired' })
  assert.deepEqual((await lanPhone(d, { pair: p.secret })).hello, { ok: false, code: 'not_paired' })
  // An expired secret: refused.
  const p2 = await d.onOp('pair', {})
  d.pairing.expiresAt = Date.now() - 1
  assert.deepEqual((await lanPhone(d, { pair: p2.secret })).hello, { ok: false, code: 'not_paired' })
  assert.equal(d.peers.length, 1)
  again.raw.destroy()
})

test('a tampered frame ends the connection; peers can be removed; the listener stops', async (t) => {
  const d = await daemon()
  t.after(() => d.close())
  const p = await d.onOp('pair', {})
  const phone = await lanPhone(d, { pair: p.secret })
  const bad = Buffer.from([0, 20, ...Buffer.alloc(20)])
  phone.raw.write(bad)
  await phone.closed()
  assert.equal(d.phone, null)

  const listed = await d.onOp('peers', {})
  assert.equal(listed.peers.length, 1)
  assert.equal((await d.onOp('peers-remove', { id: listed.peers[0].id })).removed, 1)
  assert.deepEqual((await lanPhone(d, { keys: phone.keys })).hello, { ok: false, code: 'not_paired' })
  await d.onOp('lan-off', {})
  await assert.rejects(connect({ port: p.port }))
})

test('the listener comes back on its port after a restart, with the same key and peers', async (t) => {
  const dir = tmpDir()
  const first = await daemon(dir)
  const p = await first.onOp('pair', {})
  const phone = await lanPhone(first, { pair: p.secret })
  assert.equal(phone.hello.ok, true)
  const key = first.identity.pub.toString('base64url')
  await first.close()
  const second = await daemon(dir)
  t.after(() => second.close())
  assert.equal(second.lanPort, p.port)
  assert.equal(second.identity.pub.toString('base64url'), key)
  assert.equal((await lanPhone(second, { keys: phone.keys })).hello.ok, true)
})

test('CLI: pair --json prints a dshgo link with the key, the secret and an address', async (t) => {
  const dir = tmpDir()
  const env = { ...process.env, DSH_GO_LINK_HOME: dir }
  t.after(() => run(process.execPath, [SCRIPT, 'stop'], { env }).catch(() => {}))
  const { stdout } = await run(process.execPath, [SCRIPT, 'pair', '--address', '127.0.0.1:1234', '--json'], { env })
  const out = JSON.parse(stdout.trim().slice('DSHGOLINK '.length))
  const url = new URL(out.link)
  assert.equal(url.protocol, 'dshgo:')
  assert.equal(url.host, 'link')
  assert.equal(url.searchParams.get('v'), '1')
  assert.equal(url.searchParams.get('k'), out.key)
  assert.match(url.searchParams.get('s'), /^[A-Za-z0-9_-]{22}$/)
  assert.equal(url.searchParams.get('a'), '127.0.0.1:1234')
  assert.ok(out.link.length < 200)
  // The fingerprint the phone shows (dsh_remote: first 6 bytes of SHA-256, hex, in fours).
  assert.match(out.fingerprint, /^[0-9A-F]{4} [0-9A-F]{4} [0-9A-F]{4}$/)
  assert.equal(out.fingerprint, link.fingerprint(Buffer.from(out.key, 'base64url')))
  const status = JSON.parse((await run(process.execPath, [SCRIPT, 'status', '--json'], { env })).stdout.trim().slice(10))
  assert.equal(status.lan.enabled, true)
  assert.equal(status.pairing, true)
  assert.equal((await run(process.execPath, [SCRIPT, 'peers'], { env })).stdout, 'no paired phones\n')
})
