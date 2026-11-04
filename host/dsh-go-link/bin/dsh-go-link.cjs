#!/usr/bin/env node
// dsh-go-link: lets agents on this computer (Claude Code, Codex, OpenCode, Antigravity, ...) use the
// tools of a phone running DSH Go, and lets DSH Go start and steer agents here over ACP. The phone
// dials in: through SSH, or over the local network after a one-time QR pairing (Noise IK). Agents
// register `dsh-go-link mcp` as an MCP server. Design: docs/design/remote-agents.md. One file, no
// dependencies: the DSH Go app copies it to ~/.dsh-go/link/bin/ over SSH; without SSH, download it.
//
//   dsh-go-link mcp [--bind T]   stdio MCP server for an agent (starts the daemon when needed)
//   dsh-go-link start [--json]   make sure the daemon runs (replaces one of another version)
//   dsh-go-link daemon           run the daemon in the foreground
//   dsh-go-link status | stop    ask the running daemon
//   dsh-go-link config [agent] [--json]   how to register the phone tools with each agent
//   dsh-go-link pair [--address HOST:PORT]... [--port N] [--json]   pair a phone on this network
//   dsh-go-link lan off          stop listening on the network (paired phones stay paired)
//   dsh-go-link peers [remove ID]   phones paired over the network
//
// Nothing here logs tool payloads (screen text, typed text, screenshots), prompts, or secrets.
'use strict'

const fs = require('fs')
const net = require('net')
const os = require('os')
const path = require('path')
const crypto = require('crypto')
const { spawn } = require('child_process')

const { EventEmitter } = require('events')

const VERSION = '0.3.0'
const PROTOCOL = 1
/**
 * What this daemon offers in protocol 1; the phone uses a feature only when it is listed.
 * `agents.acp.v2`: per-agent environment, bypass, and the folder's earlier sessions to resume.
 */
const CAPS = ['phone.mcp.v1', 'rpc.v1', 'agents.acp.v1', 'agents.acp.v2', 'lan.v1']
const PAIR_TTL_MS = 10 * 60 * 1000
/** A daemon with nothing to do (no phone, agents, running session or network listener) exits after this. */
const IDLE_EXIT_MS = 30 * 60 * 1000
const SCRIPT = __filename
// A screenshot result nested in a frame is a few MB; one line stays bounded.
const MAX_LINE = 16 * 1024 * 1024
const MAX_HELLO = 256 * 1024
const HELLO_TIMEOUT_MS = 10000
const PHONE_IDLE_MS = 90000
const MCP_VERSIONS = ['2024-11-05', '2025-03-26', '2025-06-18', '2025-11-25']
const MCP_LATEST = '2025-11-25'
const TAG = 'DSHGOLINK'

const NOT_ATTACHED = '[PHONE_NOT_ATTACHED] DSH Go is not connected to this computer. Ask the user to open DSH Go → ' +
  'Settings → Phone control → Computers and turn this computer on, then try again.'
const LOST = '[PHONE_NOT_ATTACHED] The connection to the phone dropped during this call: the action may or may not ' +
  'have happened. Once the phone is back, call `screen` before retrying.'
const DEFAULT_INSTRUCTIONS = 'Tools for the user\'s Android phone through DSH Go. They work while DSH Go is ' +
  'connected to this computer; until then every call says so.'

// ── Files ───────────────────────────────────────────────────────────────────────────────────────

function stateDir (env = process.env) {
  return env.DSH_GO_LINK_HOME || path.join(os.homedir(), '.dsh-go', 'link')
}

function ensureDir (dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 })
  try { fs.chmodSync(dir, 0o700) } catch (e) {}
}

function writeAtomic (file, text) {
  const tmp = path.join(path.dirname(file), '.' + path.basename(file) + '.' + process.pid + '.tmp')
  fs.writeFileSync(tmp, text, { mode: 0o600 })
  fs.renameSync(tmp, file)
}

function readJson (file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')) } catch (e) { return null }
}

function shimPath (dir) {
  if (process.platform === 'win32') {
    return '\\\\.\\pipe\\dsh-go-link-' + crypto.createHash('sha256').update(dir).digest('hex').slice(0, 16)
  }
  return path.join(dir, 'link.sock')
}

const files = (dir) => ({
  info: path.join(dir, 'daemon.json'),
  catalog: path.join(dir, 'catalog.json'),
  log: path.join(dir, 'daemon.log'),
  // The daemon's own X25519 key (network pairing), the phones paired with it, and the listener.
  identity: path.join(dir, 'identity.json'),
  peers: path.join(dir, 'peers.json'),
  lan: path.join(dir, 'lan.json'),
  // Optional per-agent command overrides, and the ACP sessions (index + one event log each).
  agents: path.join(dir, 'agents.json'),
  sessions: path.join(dir, 'sessions')
})

// ── Wire helpers ────────────────────────────────────────────────────────────────────────────────

/** Calls [onLine] for every `\n`-terminated UTF-8 line; [onTooLong] once a line exceeds [max] bytes. */
function readLines (stream, max, onLine, onTooLong) {
  let parts = []
  let size = 0
  let dead = false
  stream.on('data', function (chunk) {
    if (dead) return
    let start = 0
    for (;;) {
      const nl = chunk.indexOf(10, start)
      if (nl < 0) break
      size += nl - start
      if (size > max) { dead = true; onTooLong(); return }
      parts.push(chunk.subarray(start, nl))
      let line = Buffer.concat(parts).toString('utf8')
      parts = []
      size = 0
      if (line.endsWith('\r')) line = line.slice(0, -1)
      start = nl + 1
      onLine(line)
      if (dead) return
    }
    if (start < chunk.length) {
      size += chunk.length - start
      if (size > max) { dead = true; onTooLong(); return }
      parts.push(chunk.subarray(start))
    }
  })
  return { stop () { dead = true } }
}

function send (sock, value) {
  if (sock.destroyed || !sock.writable) return false
  sock.write((typeof value === 'string' ? value : JSON.stringify(value)) + '\n')
  return true
}

const rpcResult = (id, result) => JSON.stringify({ jsonrpc: '2.0', id, result })
const rpcError = (id, code, message) => JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } })
const toolError = (id, text) => rpcResult(id, { content: [{ type: 'text', text }], isError: true })
const listChanged = () => JSON.stringify({ jsonrpc: '2.0', method: 'notifications/tools/list_changed' })

function parseMessage (line) {
  let msg
  try { msg = JSON.parse(line) } catch (e) { return { bad: rpcError(null, -32700, 'Parse error') } }
  if (!msg || typeof msg !== 'object' || Array.isArray(msg)) return { bad: rpcError(null, -32600, 'Invalid Request') }
  const isRequest = typeof msg.method === 'string' && Object.prototype.hasOwnProperty.call(msg, 'id') && msg.id !== null
  return { msg, isRequest, isNotification: typeof msg.method === 'string' && !isRequest }
}

const idKey = (id) => JSON.stringify(id)

function safeEqual (a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false
  const x = Buffer.from(a)
  const y = Buffer.from(b)
  return x.length === y.length && crypto.timingSafeEqual(x, y)
}

function initializeResult (requested, catalog) {
  return {
    protocolVersion: MCP_VERSIONS.includes(requested) ? requested : MCP_LATEST,
    capabilities: { tools: { listChanged: true } },
    serverInfo: { name: 'dsh-go-phone', version: VERSION },
    instructions: (catalog && typeof catalog.instructions === 'string' && catalog.instructions) || DEFAULT_INSTRUCTIONS
  }
}

/**
 * The answer an MCP front gives without a phone: initialize / ping / tools/list from the cached
 * catalog; tool calls say the phone isn't connected; anything else is unknown. Null for
 * notifications and responses (nothing to send).
 */
function answerLocally (msg, catalog, toolText = NOT_ATTACHED) {
  switch (msg.method) {
    case 'initialize': return rpcResult(msg.id, initializeResult(msg.params && msg.params.protocolVersion, catalog))
    case 'ping': return rpcResult(msg.id, {})
    case 'tools/list': return rpcResult(msg.id, { tools: (catalog && Array.isArray(catalog.tools)) ? catalog.tools : [] })
    case 'tools/call': return toolError(msg.id, toolText)
    default: return rpcError(msg.id, -32601, 'Method not found')
  }
}

// ── Noise IK (network pairing) ──────────────────────────────────────────────────────────────────
//
// Noise_IK_25519_ChaChaPoly_SHA256, the suite packages/dsh_remote already speaks (checked against
// its vectors). The phone is the initiator and knows this daemon's static key from the pairing QR;
// the daemon learns the phone's key in message 1 and lets it in only when it was paired. Messages
// travel with a 2-byte big-endian length; after the handshake the link protocol runs inside.

const NOISE_NAME = Buffer.from('Noise_IK_25519_ChaChaPoly_SHA256')
const LINK_PROLOGUE = Buffer.from('DSH-GO-LINK\0v=1')
const NOISE_MAX = 65535
const NOISE_TAG = 16
const PKCS8_X25519 = Buffer.from('302e020100300506032b656e04220420', 'hex')
const SPKI_X25519 = Buffer.from('302a300506032b656e032100', 'hex')
const EMPTY = Buffer.alloc(0)

const b64u = (b) => Buffer.from(b).toString('base64url')
const unb64u = (s) => Buffer.from(String(s), 'base64url')
const sha256 = (...parts) => crypto.createHash('sha256').update(Buffer.concat(parts)).digest()
const hmac = (key, data) => crypto.createHmac('sha256', key).update(data).digest()

function x25519Private (priv) {
  return crypto.createPrivateKey({ key: Buffer.concat([PKCS8_X25519, priv]), format: 'der', type: 'pkcs8' })
}

function x25519Public (pub) {
  return crypto.createPublicKey({ key: Buffer.concat([SPKI_X25519, pub]), format: 'der', type: 'spki' })
}

/** An X25519 key pair as raw 32-byte buffers; a fresh one without [priv]. */
function x25519KeyPair (priv) {
  const p = priv
    ? Buffer.from(priv)
    : crypto.generateKeyPairSync('x25519').privateKey.export({ format: 'der', type: 'pkcs8' }).subarray(16)
  const pub = crypto.createPublicKey(x25519Private(p)).export({ format: 'der', type: 'spki' }).subarray(12)
  return { priv: Buffer.from(p), pub: Buffer.from(pub) }
}

function dh (priv, pub) {
  if (pub.length !== 32) throw new Error('bad X25519 key')
  const out = crypto.diffieHellman({ privateKey: x25519Private(priv), publicKey: x25519Public(pub) })
  if (out.every((b) => b === 0)) throw new Error('low-order X25519 key')
  return out
}

function hkdf2 (ck, ikm) {
  const temp = hmac(ck, ikm)
  const out1 = hmac(temp, Buffer.from([1]))
  const out2 = hmac(temp, Buffer.concat([out1, Buffer.from([2])]))
  return [out1, out2]
}

class CipherState {
  constructor (key = null) {
    this.key = key
    this.n = 0
  }

  nonce () {
    const b = Buffer.alloc(12)
    b.writeBigUInt64LE(BigInt(this.n), 4)
    return b
  }

  encrypt (ad, plaintext) {
    if (!this.key) return Buffer.from(plaintext)
    const c = crypto.createCipheriv('chacha20-poly1305', this.key, this.nonce(), { authTagLength: NOISE_TAG })
    c.setAAD(ad, { plaintextLength: plaintext.length })
    const out = Buffer.concat([c.update(plaintext), c.final(), c.getAuthTag()])
    this.n++
    return out
  }

  decrypt (ad, ciphertext) {
    if (!this.key) return Buffer.from(ciphertext)
    if (ciphertext.length < NOISE_TAG) throw new Error('noise message too short')
    const body = ciphertext.subarray(0, ciphertext.length - NOISE_TAG)
    const d = crypto.createDecipheriv('chacha20-poly1305', this.key, this.nonce(), { authTagLength: NOISE_TAG })
    d.setAAD(ad, { plaintextLength: body.length })
    d.setAuthTag(ciphertext.subarray(ciphertext.length - NOISE_TAG))
    const out = Buffer.concat([d.update(body), d.final()])
    this.n++
    return out
  }
}

/**
 * One IK handshake and its transport keys. [s] is this side's static pair; the initiator passes
 * the responder's static key as [rs]. [e] fixes the ephemeral key (test vectors only).
 */
class NoiseIK {
  constructor ({ initiator, s, rs = null, prologue = LINK_PROLOGUE, e = null }) {
    this.initiator = initiator
    this.s = s
    this.rs = rs ? Buffer.from(rs) : null
    this.eSeed = e
    this.h = Buffer.from(NOISE_NAME)
    this.ck = Buffer.from(this.h)
    this.cs = new CipherState()
    this.send = null
    this.recv = null
    this.mixHash(prologue)
    this.mixHash(initiator ? this.rs : s.pub)
  }

  mixHash (data) { this.h = sha256(this.h, data) }

  mixKey (ikm) {
    const [ck, k] = hkdf2(this.ck, ikm)
    this.ck = ck
    this.cs = new CipherState(k)
  }

  encryptAndHash (pt) {
    const ct = this.cs.encrypt(this.h, pt)
    this.mixHash(ct)
    return ct
  }

  decryptAndHash (ct) {
    const pt = this.cs.decrypt(this.h, ct)
    this.mixHash(ct)
    return pt
  }

  split () {
    const [a, b] = hkdf2(this.ck, EMPTY)
    this.send = new CipherState(this.initiator ? a : b)
    this.recv = new CipherState(this.initiator ? b : a)
  }

  /** -> e, es, s, ss (initiator). */
  writeMessage1 (payload = EMPTY) {
    this.e = x25519KeyPair(this.eSeed)
    this.mixHash(this.e.pub)
    this.mixKey(dh(this.e.priv, this.rs))
    const s = this.encryptAndHash(this.s.pub)
    this.mixKey(dh(this.s.priv, this.rs))
    return Buffer.concat([this.e.pub, s, this.encryptAndHash(payload)])
  }

  /** Message 1 at the responder: learns the initiator's static key ([rs]); returns its payload. */
  readMessage1 (msg) {
    if (msg.length < 32 + 32 + NOISE_TAG + NOISE_TAG) throw new Error('noise message 1 too short')
    this.re = Buffer.from(msg.subarray(0, 32))
    this.mixHash(this.re)
    this.mixKey(dh(this.s.priv, this.re))
    this.rs = this.decryptAndHash(msg.subarray(32, 32 + 32 + NOISE_TAG))
    this.mixKey(dh(this.s.priv, this.rs))
    return this.decryptAndHash(msg.subarray(32 + 32 + NOISE_TAG))
  }

  /** <- e, ee, se (responder); the handshake is done after it. */
  writeMessage2 (payload = EMPTY) {
    this.e = x25519KeyPair(this.eSeed)
    this.mixHash(this.e.pub)
    this.mixKey(dh(this.e.priv, this.re))
    this.mixKey(dh(this.e.priv, this.rs))
    const out = Buffer.concat([this.e.pub, this.encryptAndHash(payload)])
    this.split()
    return out
  }

  readMessage2 (msg) {
    if (msg.length < 32 + NOISE_TAG) throw new Error('noise message 2 too short')
    this.re = Buffer.from(msg.subarray(0, 32))
    this.mixHash(this.re)
    this.mixKey(dh(this.e.priv, this.re))
    this.mixKey(dh(this.s.priv, this.re))
    const payload = this.decryptAndHash(msg.subarray(32))
    this.split()
    return payload
  }
}

/** Splits a byte stream into 2-byte-length-prefixed messages. */
class FrameReader {
  constructor (onFrame) {
    this.buf = EMPTY
    this.onFrame = onFrame
  }

  feed (chunk) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, chunk]) : chunk
    while (this.buf.length >= 2) {
      const len = this.buf.readUInt16BE(0)
      if (this.buf.length < 2 + len) break
      const frame = this.buf.subarray(2, 2 + len)
      this.buf = this.buf.subarray(2 + len)
      if (this.onFrame(frame) === false) return
    }
  }
}

function frame (msg) {
  const out = Buffer.alloc(2 + msg.length)
  out.writeUInt16BE(msg.length, 0)
  msg.copy(out, 2)
  return out
}

/**
 * The link's byte stream inside Noise transport messages, shaped like the net.Socket parts the
 * daemon uses ('data', 'close', write, end, destroy). A message that fails authentication ends it.
 */
class SecureStream extends EventEmitter {
  constructor (sock, noise, leftover = EMPTY) {
    super()
    this.sock = sock
    this.noise = noise
    this.reader = new FrameReader((msg) => {
      let pt
      try {
        pt = this.noise.recv.decrypt(EMPTY, msg)
      } catch (e) {
        this.sock.destroy()
        return false
      }
      this.emit('data', pt)
    })
    sock.removeAllListeners('data')
    sock.on('data', (d) => this.reader.feed(d))
    sock.on('close', () => this.emit('close'))
    sock.on('error', (e) => this.emit('error', e))
    if (leftover.length) setImmediate(() => this.reader.feed(leftover))
  }

  get destroyed () { return this.sock.destroyed }
  get writable () { return !this.sock.destroyed && this.sock.writable }
  setNoDelay () {}
  end () { this.sock.end() }
  destroy () { this.sock.destroy() }

  write (data) {
    const b = Buffer.isBuffer(data) ? data : Buffer.from(data)
    for (let i = 0; i < b.length; i += NOISE_MAX - NOISE_TAG) {
      this.sock.write(frame(this.noise.send.encrypt(EMPTY, b.subarray(i, i + NOISE_MAX - NOISE_TAG))))
    }
    return true
  }
}

/** `ABCD EF01 2345`: the first 6 bytes of SHA-256 of a key, as the phone shows it (dsh_remote's identityFingerprint). */
function fingerprint (pub) {
  return crypto.createHash('sha256').update(Buffer.from(pub)).digest().subarray(0, 6).toString('hex').toUpperCase().match(/.{1,4}/g).join(' ')
}

/** This daemon's network identity, created once (0600). */
function loadIdentity (file) {
  const stored = readJson(file)
  if (stored && typeof stored.privateKey === 'string') {
    try { return x25519KeyPair(unb64u(stored.privateKey)) } catch (e) {}
  }
  const pair = x25519KeyPair()
  writeAtomic(file, JSON.stringify({ privateKey: b64u(pair.priv), publicKey: b64u(pair.pub) }) + '\n')
  return pair
}

/** IPv4 addresses a phone on the same network could reach. */
function lanAddresses () {
  const out = []
  for (const list of Object.values(os.networkInterfaces())) {
    for (const a of list || []) {
      if (a.family === 'IPv4' && !a.internal) out.push(a.address)
    }
  }
  return out
}

// ── QR code (pairing link in the terminal) ──────────────────────────────────────────────────────
//
// Byte mode, error correction M, versions 1–10 (up to 213 bytes): enough for a pairing link. After
// Nayuki's reference construction (MIT); no dependencies.

const QR_M_BLOCKS = [null,
  [10, [[1, 16]]], [16, [[1, 28]]], [26, [[1, 44]]], [18, [[2, 32]]], [24, [[2, 43]]],
  [16, [[4, 27]]], [18, [[4, 31]]], [22, [[2, 38], [2, 39]]], [22, [[3, 36], [2, 37]]], [26, [[4, 43], [1, 44]]]]

function gfMul (x, y) {
  let z = 0
  for (let i = 7; i >= 0; i--) {
    z = (z << 1) ^ ((z >>> 7) * 0x11d)
    z ^= ((y >>> i) & 1) * x
  }
  return z & 0xff
}

function rsDivisor (degree) {
  const result = new Array(degree).fill(0)
  result[degree - 1] = 1
  let root = 1
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < result.length; j++) {
      result[j] = gfMul(result[j], root)
      if (j + 1 < result.length) result[j] ^= result[j + 1]
    }
    root = gfMul(root, 0x02)
  }
  return result
}

function rsRemainder (data, divisor) {
  const result = divisor.map(() => 0)
  for (const b of data) {
    const factor = b ^ result.shift()
    result.push(0)
    divisor.forEach((coef, i) => { result[i] ^= gfMul(coef, factor) })
  }
  return result
}

/** The QR matrix for [text]: an array of rows of booleans (true = dark). Throws when it doesn't fit. */
function qrMatrix (text) {
  const bytes = Buffer.from(text, 'utf8')
  let version = 0
  let dataCodewords = 0
  for (let v = 1; v <= 10; v++) {
    const [, groups] = QR_M_BLOCKS[v]
    const cap = groups.reduce((n, [count, len]) => n + count * len, 0)
    const bits = 4 + (v < 10 ? 8 : 16) + bytes.length * 8
    if (bits <= cap * 8) { version = v; dataCodewords = cap; break }
  }
  if (!version) throw new Error('too long for a QR code')
  // Data bits: byte mode, count, bytes, terminator, pad.
  const bits = []
  const put = (val, len) => { for (let i = len - 1; i >= 0; i--) bits.push((val >>> i) & 1) }
  put(4, 4)
  put(bytes.length, version < 10 ? 8 : 16)
  for (const b of bytes) put(b, 8)
  put(0, Math.min(4, dataCodewords * 8 - bits.length))
  put(0, (8 - bits.length % 8) % 8)
  for (let pad = 0xec; bits.length < dataCodewords * 8; pad ^= 0xec ^ 0x11) put(pad, 8)
  const data = []
  for (let i = 0; i < bits.length; i += 8) data.push(parseInt(bits.slice(i, i + 8).join(''), 2))
  // Blocks with their error correction, interleaved.
  const [ecLen, groups] = QR_M_BLOCKS[version]
  const divisor = rsDivisor(ecLen)
  const blocks = []
  let k = 0
  for (const [count, len] of groups) {
    for (let i = 0; i < count; i++) {
      const d = data.slice(k, k + len)
      k += len
      blocks.push({ d, e: rsRemainder(d, divisor) })
    }
  }
  const codewords = []
  const longest = Math.max(...blocks.map((b) => b.d.length))
  for (let i = 0; i < longest; i++) for (const b of blocks) if (i < b.d.length) codewords.push(b.d[i])
  for (let i = 0; i < ecLen; i++) for (const b of blocks) codewords.push(b.e[i])

  const size = version * 4 + 17
  const dark = Array.from({ length: size }, () => new Array(size).fill(false))
  const fixed = Array.from({ length: size }, () => new Array(size).fill(false))
  const set = (x, y, on) => { dark[y][x] = on; fixed[y][x] = true }
  for (let i = 0; i < size; i++) { set(6, i, i % 2 === 0); set(i, 6, i % 2 === 0) }
  const finder = (cx, cy) => {
    for (let dy = -4; dy <= 4; dy++) {
      for (let dx = -4; dx <= 4; dx++) {
        const x = cx + dx
        const y = cy + dy
        if (x >= 0 && x < size && y >= 0 && y < size) {
          const dist = Math.max(Math.abs(dx), Math.abs(dy))
          set(x, y, dist !== 2 && dist !== 4)
        }
      }
    }
  }
  finder(3, 3)
  finder(size - 4, 3)
  finder(3, size - 4)
  if (version > 1) {
    const n = Math.floor(version / 7) + 2
    const step = Math.ceil((version * 4 + 4) / (n * 2 - 2)) * 2
    const pos = [6]
    for (let i = 0, p = size - 7; i < n - 1; i++, p -= step) pos.splice(1, 0, p)
    for (let i = 0; i < n; i++) {
      for (let j = 0; j < n; j++) {
        if ((i === 0 && j === 0) || (i === 0 && j === n - 1) || (i === n - 1 && j === 0)) continue
        for (let dy = -2; dy <= 2; dy++) {
          for (let dx = -2; dx <= 2; dx++) set(pos[i] + dx, pos[j] + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1)
        }
      }
    }
  }
  const formatBits = (mask) => {
    const d = (0 << 3) | mask // level M = 0
    let rem = d
    for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537)
    return ((d << 10) | rem) ^ 0x5412
  }
  const drawFormat = (mask) => {
    const f = formatBits(mask)
    const bit = (i) => ((f >>> i) & 1) !== 0
    for (let i = 0; i <= 5; i++) set(8, i, bit(i))
    set(8, 7, bit(6))
    set(8, 8, bit(7))
    set(7, 8, bit(8))
    for (let i = 9; i < 15; i++) set(14 - i, 8, bit(i))
    for (let i = 0; i < 8; i++) set(size - 1 - i, 8, bit(i))
    for (let i = 8; i < 15; i++) set(8, size - 15 + i, bit(i))
    set(8, size - 8, true)
  }
  drawFormat(0)
  if (version >= 7) {
    let rem = version
    for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25)
    const v = (version << 12) | rem
    for (let i = 0; i < 18; i++) {
      const on = ((v >>> i) & 1) !== 0
      const a = size - 11 + (i % 3)
      const b = Math.floor(i / 3)
      set(a, b, on)
      set(b, a, on)
    }
  }
  // Data, in the zigzag.
  let bitIndex = 0
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5
    for (let vert = 0; vert < size; vert++) {
      for (let j = 0; j < 2; j++) {
        const x = right - j
        const upward = ((right + 1) & 2) === 0
        const y = upward ? size - 1 - vert : vert
        if (!fixed[y][x] && bitIndex < codewords.length * 8) {
          dark[y][x] = ((codewords[bitIndex >>> 3] >>> (7 - (bitIndex & 7))) & 1) !== 0
          bitIndex++
        }
      }
    }
  }
  const masks = [
    (x, y) => (x + y) % 2 === 0, (x, y) => y % 2 === 0, (x) => x % 3 === 0, (x, y) => (x + y) % 3 === 0,
    (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0, (x, y) => (x * y) % 2 + (x * y) % 3 === 0,
    (x, y) => ((x * y) % 2 + (x * y) % 3) % 2 === 0, (x, y) => ((x + y) % 2 + (x * y) % 3) % 2 === 0
  ]
  const applyMask = (m) => {
    for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (!fixed[y][x] && masks[m](x, y)) dark[y][x] = !dark[y][x]
  }
  const penalty = () => {
    let score = 0
    const lines = []
    for (let y = 0; y < size; y++) lines.push(dark[y])
    for (let x = 0; x < size; x++) lines.push(dark.map((row) => row[x]))
    for (const line of lines) {
      let run = 1
      for (let i = 1; i <= size; i++) {
        if (i < size && line[i] === line[i - 1]) { run++; continue }
        if (run >= 5) score += run - 2
        run = 1
      }
      const s = line.map((d) => (d ? '1' : '0')).join('')
      for (const pat of ['10111010000', '00001011101']) {
        for (let i = s.indexOf(pat); i >= 0; i = s.indexOf(pat, i + 1)) score += 40
      }
    }
    for (let y = 0; y < size - 1; y++) {
      for (let x = 0; x < size - 1; x++) {
        const c = dark[y][x]
        if (c === dark[y][x + 1] && c === dark[y + 1][x] && c === dark[y + 1][x + 1]) score += 3
      }
    }
    const total = dark.reduce((n, row) => n + row.filter(Boolean).length, 0)
    score += Math.floor(Math.abs(total * 20 - size * size * 10) / (size * size)) * 10
    return score
  }
  let best = 0
  let bestScore = Infinity
  for (let m = 0; m < 8; m++) {
    applyMask(m)
    drawFormat(m)
    const score = penalty()
    if (score < bestScore) { best = m; bestScore = score }
    applyMask(m)
  }
  applyMask(best)
  drawFormat(best)
  return dark
}

/** [matrix] for a terminal: two rows per line with half blocks, black on white, quiet zone 2. */
function qrText (matrix, quiet = 2) {
  const size = matrix.length
  const at = (x, y) => x >= 0 && y >= 0 && x < size && y < size && matrix[y][x]
  const lines = []
  for (let y = -quiet; y < size + quiet; y += 2) {
    let line = ''
    for (let x = -quiet; x < size + quiet; x++) {
      const top = at(x, y)
      const bottom = at(x, y + 1)
      line += '\x1b[' + (top ? '30' : '97') + ';' + (bottom ? '40' : '107') + 'm▀'
    }
    lines.push(line + '\x1b[0m')
  }
  return lines.join('\n')
}

// ── ACP agents (the phone as the cockpit) ───────────────────────────────────────────────────────
//
// The daemon is an Agent Client Protocol client: it runs each agent's ACP command, one process per
// session, keeps the session going while the phone is away, and logs every update so the phone can
// catch up. It offers no file system or terminal to agents (they use their own tools), and gives
// each session this phone's tools through `dsh-go-link mcp --bind <ticket>`.

const ACP_PROTOCOL = 1
const MAX_EVENTS_KEPT = 4000
const MAX_EVENT_BYTES = 512 * 1024
const MAX_WATCH_EVENTS = 1500

// The ACP adapters (agentclientprotocol.com; formerly @zed-industries/*), pinned. They use the
// agent's own sign-in on this computer (`claude` / `codex login`). `bypass` is how the agent runs
// without asking for permission: an ACP mode it offers (switchable at any time), or arguments it
// needs from the start (the process restarts to switch).
const AGENT_DEFAULTS = [
  { id: 'claude-code', name: 'Claude Code', needs: 'claude', command: ['npx', '-y', '@agentclientprotocol/claude-agent-acp@0.99.1'], bypass: { mode: 'bypassPermissions' } },
  { id: 'codex', name: 'Codex', needs: 'codex', command: ['npx', '-y', '@agentclientprotocol/codex-acp@2.5.0'], bypass: { mode: 'agent-full-access' } },
  { id: 'antigravity', name: 'Antigravity', needs: 'agy', command: ['agy', 'acp'], bypass: { args: ['--dangerously-skip-permissions'] } },
  { id: 'opencode', name: 'OpenCode', needs: 'opencode', command: ['opencode', 'acp'] },
  { id: 'gemini', name: 'Gemini CLI', needs: 'gemini', command: ['gemini', '--experimental-acp'] }
]

/** [cmd] on PATH (or as a path), as an absolute path; null when absent. npx also next to this Node. */
function which (cmd, env = process.env) {
  if (!cmd) return null
  const exts = process.platform === 'win32' ? ['', '.cmd', '.exe', '.bat'] : ['']
  const candidates = cmd.includes('/') || cmd.includes('\\')
    ? [cmd]
    : [...(env.PATH || '').split(path.delimiter).filter(Boolean).map((d) => path.join(d, cmd)), path.join(path.dirname(process.execPath), cmd)]
  for (const base of candidates) {
    for (const ext of exts) {
      try {
        fs.accessSync(base + ext, fs.constants.X_OK)
        if (fs.statSync(base + ext).isFile()) return base + ext
      } catch (e) {}
    }
  }
  return null
}

/** The agents this daemon knows: the defaults, overridden or extended by agents.json. */
function agentRegistry (file, env = process.env) {
  const overrides = readJson(file) || {}
  const list = AGENT_DEFAULTS.map((a) => ({ ...a, ...(overrides[a.id] || {}) }))
  for (const [id, def] of Object.entries(overrides)) {
    if (!list.some((a) => a.id === id) && def && Array.isArray(def.command)) list.push({ id, name: def.name || id, ...def })
  }
  return list.map((a) => {
    const command = Array.isArray(a.command) ? a.command.map(String) : []
    const available = command.length > 0 && !!which(command[0], env) && (!a.needs || !!which(a.needs, env))
    return { id: a.id, name: a.name || a.id, command, available, bypass: bypassOf(a.bypass) }
  })
}

/** `{ mode }` or `{ args }` from an agent definition; null when it has no way to skip permissions. */
function bypassOf (b) {
  if (!b || typeof b !== 'object') return null
  if (typeof b.mode === 'string' && b.mode) return { mode: b.mode }
  if (Array.isArray(b.args) && b.args.length) return { args: b.args.map(String) }
  return null
}

const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/
const MAX_ENV_VARS = 100
const MAX_ENV_BYTES = 64 * 1024

/**
 * The environment the phone sets for an agent: names and string values, bounded. null when the
 * request has none. It is kept in memory only (it often holds keys): never written to disk or logs.
 */
function cleanEnv (env) {
  if (env === undefined || env === null) return null
  const bad = () => Object.assign(new Error('Invalid environment variables.'), { code: 'bad_env' })
  if (typeof env !== 'object' || Array.isArray(env)) throw bad()
  const entries = Object.entries(env)
  if (entries.length > MAX_ENV_VARS) throw bad()
  let size = 0
  const out = {}
  for (const [k, v] of entries) {
    if (!ENV_NAME.test(k) || typeof v !== 'string') throw bad()
    size += k.length + v.length
    out[k] = v
  }
  if (size > MAX_ENV_BYTES) throw bad()
  return out
}

/** [promise], or a `timeout` error after [ms]. */
function withTimeout (promise, ms) {
  let timer
  return Promise.race([
    promise,
    new Promise((resolve, reject) => { timer = setTimeout(() => reject(Object.assign(new Error('The agent did not answer in time.'), { code: 'timeout' })), ms) })
  ]).finally(() => clearTimeout(timer))
}

/** JSON-RPC 2.0 over a child's stdio, both directions (requests, notifications, responses). */
class JsonRpcPeer {
  constructor (input, output, { onRequest, onNotification }) {
    this.output = output
    this.onRequest = onRequest
    this.onNotification = onNotification
    this.pending = new Map()
    this.nextId = 1
    this.closed = false
    readLines(input, MAX_LINE, (line) => this.onLine(line), () => this.close(new Error('message too long')))
    output.on('error', () => this.close(new Error('agent stdin closed')))
  }

  write (msg) {
    if (this.closed || this.output.destroyed) return
    this.output.write(JSON.stringify(msg) + '\n')
  }

  request (method, params) {
    if (this.closed) return Promise.reject(Object.assign(new Error('agent is gone'), { code: 'agent_gone' }))
    const id = this.nextId++
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject })
      this.write({ jsonrpc: '2.0', id, method, params })
    })
  }

  notify (method, params) { this.write({ jsonrpc: '2.0', method, params }) }

  onLine (line) {
    if (!line.trim()) return
    let msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (!msg || typeof msg !== 'object') return
    if (typeof msg.method === 'string' && msg.id !== undefined && msg.id !== null) {
      Promise.resolve()
        .then(() => this.onRequest(msg.method, msg.params || {}))
        .then((result) => this.write({ jsonrpc: '2.0', id: msg.id, result: result === undefined ? null : result }),
          (e) => this.write({ jsonrpc: '2.0', id: msg.id, error: { code: typeof e.code === 'number' ? e.code : -32603, message: String(e.message || e) } }))
      return
    }
    if (typeof msg.method === 'string') { this.onNotification(msg.method, msg.params || {}); return }
    const p = this.pending.get(msg.id)
    if (!p) return
    this.pending.delete(msg.id)
    if (msg.error) p.reject(Object.assign(new Error(msg.error.message || 'agent error'), { code: msg.error.code, data: msg.error.data }))
    else p.resolve(msg.result)
  }

  close (why = new Error('agent is gone')) {
    if (this.closed) return
    this.closed = true
    for (const p of this.pending.values()) p.reject(Object.assign(why, { code: why.code || 'agent_gone' }))
    this.pending.clear()
  }
}

/** Whether an ACP error means "sign in first" (agents use -32000 with an auth message). */
function isAuthError (e) {
  return e && (e.code === -32000 || /auth/i.test(String(e.message || ''))) && /auth|log ?in|sign ?in/i.test(String(e.message || ''))
}

/**
 * One agent session: its process (when running), its log, and what the phone may do with it.
 * Survives the phone going away; after a daemon restart it comes back stopped, with its history,
 * and resumes through `session/load` when the agent offers it. A session resumed from the agent's
 * own list (`imported`, e.g. one started in a terminal) takes its history from that first load.
 */
class AgentSession {
  constructor (daemon, meta) {
    this.daemon = daemon
    this.meta = meta
    this.events = []
    this.seq = meta.seq || 0
    this.loaded = false
    this.status = meta.closed ? 'closed' : 'stopped'
    this.child = null
    this.peer = null
    this.starting = null
    this.permissions = new Map()
    this.nextPermission = 1
    this.ticket = null
    this.stderr = []
    this.replaying = null
    this.replayUser = null
  }

  get id () { return this.meta.id }

  def () { return this.daemon.agents().find((a) => a.id === this.meta.agent) || null }

  /**
   * Whether the agent runs without asking: its bypass mode is the current one (as the agent last
   * reported it), or it was started with its bypass arguments. A mode asked for at creation counts
   * until the agent has a session to apply it to.
   */
  bypassOn (def = this.def()) {
    const b = def && def.bypass
    if (!b) return false
    if (b.mode) return this.meta.modes ? this.meta.modes.currentModeId === b.mode : !!this.meta.bypass
    return !!this.meta.bypass
  }
  get logFile () { return path.join(this.daemon.files.sessions, this.id + '.jsonl') }

  summary () {
    const m = this.meta
    return {
      id: m.id, agent: m.agent, agentName: m.agentName, cwd: m.cwd, title: m.title || null,
      createdAt: m.createdAt, updatedAt: m.updatedAt, status: this.status, seq: this.seq,
      modes: m.modes || null, pending: [...this.permissions.keys()], bypass: this.bypassOn(),
      agentSessionId: m.agentSessionId || null
    }
  }

  /** The log from disk, once (only the tail stays in memory). */
  load () {
    if (this.loaded) return
    this.loaded = true
    let text = ''
    try { text = fs.readFileSync(this.logFile, 'utf8') } catch (e) { return }
    const events = []
    for (const line of text.split('\n')) {
      if (!line) continue
      try { events.push(JSON.parse(line)) } catch (e) {}
    }
    this.events = events.slice(-MAX_EVENTS_KEPT)
    if (events.length) this.seq = Math.max(this.seq, events[events.length - 1].seq)
  }

  append (event) {
    this.load()
    let e = { seq: ++this.seq, at: new Date().toISOString(), ...event }
    if (JSON.stringify(e).length > MAX_EVENT_BYTES) e = { seq: e.seq, at: e.at, kind: event.kind, truncated: true }
    this.events.push(e)
    if (this.events.length > MAX_EVENTS_KEPT) this.events.splice(0, this.events.length - MAX_EVENTS_KEPT)
    try { fs.appendFileSync(this.logFile, JSON.stringify(e) + '\n', { mode: 0o600 }) } catch (err) {}
    this.meta.updatedAt = e.at
    this.meta.seq = this.seq
    this.daemon.sessionEvent(this, e)
    return e
  }

  setStatus (status) {
    if (this.status === status) return
    this.status = status
    this.daemon.saveSessions()
    this.daemon.sessionChanged(this)
  }

  /** The events after [afterSeq] (at most [limit], the latest), and whether older ones were cut. */
  since (afterSeq, limit = MAX_WATCH_EVENTS) {
    this.load()
    const after = this.events.filter((e) => e.seq > afterSeq)
    return { events: after.slice(-limit), truncated: after.length > limit || (this.events.length > 0 && this.events[0].seq > afterSeq + 1) }
  }

  /** The agent running with its ACP session open (a start in progress is waited for, not repeated). */
  ensureProcess () {
    if (this.starting) return this.starting
    if (this.peer && !this.peer.closed) return Promise.resolve()
    this.starting = this.start().finally(() => { this.starting = null })
    return this.starting
  }

  async start () {
    const def = this.def()
    if (!def || !def.available) throw Object.assign(new Error('This agent is not installed on the computer.'), { code: 'agent_unavailable' })
    this.setStatus('starting')
    this.ticket = crypto.randomBytes(16).toString('hex')
    this.daemon.tickets.set(this.ticket, this)
    const exe = which(def.command[0]) || def.command[0]
    const args = def.command.slice(1)
    if (this.meta.bypass && def.bypass && def.bypass.args) args.push(...def.bypass.args)
    const child = this.child = spawn(exe, args, {
      cwd: this.meta.cwd, env: this.daemon.agentEnv(this.meta.agent), stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true
    })
    child.stderr.on('data', (d) => {
      this.stderr.push(...String(d).split('\n').filter(Boolean))
      if (this.stderr.length > 20) this.stderr.splice(0, this.stderr.length - 20)
    })
    const peer = this.peer = new JsonRpcPeer(child.stdout, child.stdin, {
      onRequest: (method, params) => this.onAgentRequest(method, params),
      onNotification: (method, params) => this.onAgentNotification(method, params)
    })
    const exited = new Promise((resolve) => child.once('exit', resolve))
    child.once('error', (e) => peer.close(Object.assign(new Error(e.message), { code: 'spawn_failed' })))
    exited.then((code) => {
      peer.close()
      if (this.peer === peer) this.peer = null
      if (this.child === child) this.child = null
      this.daemon.tickets.delete(this.ticket)
      this.cancelPermissions()
      if (this.status !== 'closed') {
        if (this.status === 'running') this.append({ kind: 'error', code: 'agent_exited', message: this.stderrTail() })
        this.setStatus('stopped')
      }
      this.daemon.log('agent session ' + this.id + ' exited (' + code + ')')
    })
    try {
      const init = await peer.request('initialize', {
        protocolVersion: ACP_PROTOCOL,
        clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
        clientInfo: { name: 'dsh-go-link', title: 'DSH Go', version: VERSION }
      })
      this.capabilities = (init && init.agentCapabilities) || {}
      this.authMethods = (init && init.authMethods) || []
      const mcpServers = [{ name: 'phone', command: process.execPath, args: [SCRIPT, 'mcp', '--bind', this.ticket], env: [] }]
      if (this.meta.agentSessionId && this.capabilities.loadSession) {
        // Our own sessions already have their history; an imported one takes it from this replay.
        this.replaying = this.meta.imported ? 'record' : 'drop'
        const wanted = this.meta.modes && this.meta.modes.currentModeId
        let loaded
        try {
          loaded = await peer.request('session/load', { sessionId: this.meta.agentSessionId, cwd: this.meta.cwd, mcpServers })
        } finally {
          this.flushReplayUser()
          this.replaying = null
        }
        if (this.meta.imported) {
          delete this.meta.imported
          this.append({ kind: 'notice', code: 'resumed' })
        }
        if (loaded && loaded.modes) this.meta.modes = loaded.modes
        if (!this.meta.initialMode && this.meta.modes) this.meta.initialMode = this.meta.modes.currentModeId
        // The mode the session had before this restart (bypass included), as the agent confirms it.
        if (wanted && this.meta.modes && this.meta.modes.currentModeId !== wanted) await this.applyMode(wanted)
      } else {
        if (this.meta.imported) throw Object.assign(new Error('This agent cannot reopen earlier sessions.'), { code: 'resume_unsupported' })
        if (this.meta.agentSessionId) this.append({ kind: 'notice', code: 'context_lost' })
        const created = await peer.request('session/new', { cwd: this.meta.cwd, mcpServers })
        this.meta.agentSessionId = created && created.sessionId
        if (created && created.modes) {
          this.meta.modes = created.modes
          this.meta.initialMode = created.modes.currentModeId
        }
      }
      // Bypass asked for at creation, for an agent that does it with a mode.
      if (this.meta.bypass && def.bypass && def.bypass.mode) {
        delete this.meta.bypass
        await this.applyMode(def.bypass.mode)
      }
      this.daemon.saveSessions()
      this.setStatus('idle')
    } catch (e) {
      const auth = isAuthError(e)
      const code = auth ? 'auth_required' : (typeof e.code === 'string' ? e.code : 'start_failed')
      this.append({
        kind: 'error',
        code,
        message: auth ? String(e.message) : (e.message || '') + (this.stderrTail() ? '\n' + this.stderrTail() : '')
      })
      try { child.kill() } catch (err) {}
      this.setStatus('stopped')
      throw Object.assign(new Error(e.message), { code: auth || code === 'resume_unsupported' ? code : 'start_failed' })
    }
  }

  stderrTail () { return this.stderr.slice(-6).join('\n') }

  onAgentNotification (method, params) {
    if (method !== 'session/update' || !params || typeof params.update !== 'object') return
    if (this.replaying === 'drop') return // session/load replays the history we already have
    const update = params.update
    if (this.replaying === 'record' && update.sessionUpdate === 'user_message_chunk') {
      // What the person said, replayed in chunks: one `user` event, like a prompt sent from here.
      const c = update.content
      if (c && c.type === 'text' && typeof c.text === 'string') this.replayUser = (this.replayUser || '') + c.text
      return
    }
    this.flushReplayUser()
    if (update.sessionUpdate === 'current_mode_update' && this.meta.modes) {
      this.meta.modes.currentModeId = update.currentModeId
      this.daemon.saveSessions()
      this.daemon.sessionChanged(this)
    }
    this.append({ kind: 'update', update })
  }

  flushReplayUser () {
    const text = this.replayUser
    this.replayUser = null
    if (text && text.trim()) this.append({ kind: 'user', text, images: 0 })
  }

  onAgentRequest (method, params) {
    if (method === 'session/request_permission') {
      const requestId = 'p' + this.nextPermission++
      return new Promise((resolve) => {
        this.permissions.set(requestId, resolve)
        this.append({ kind: 'permission', requestId, toolCall: params.toolCall || null, options: Array.isArray(params.options) ? params.options : [] })
        this.daemon.sessionChanged(this)
      })
    }
    // No file system or terminal is offered (clientCapabilities say so).
    return Promise.reject(Object.assign(new Error('Method not found'), { code: -32601 }))
  }

  answerPermission (requestId, optionId) {
    const resolve = this.permissions.get(requestId)
    if (!resolve) throw Object.assign(new Error('This request is no longer waiting.'), { code: 'stale' })
    this.permissions.delete(requestId)
    resolve({ outcome: optionId ? { outcome: 'selected', optionId: String(optionId) } : { outcome: 'cancelled' } })
    this.append({ kind: 'permission_done', requestId, optionId: optionId || null })
    this.daemon.sessionChanged(this)
  }

  cancelPermissions () {
    for (const [requestId, resolve] of this.permissions) {
      resolve({ outcome: { outcome: 'cancelled' } })
      this.append({ kind: 'permission_done', requestId, optionId: null })
    }
    this.permissions.clear()
  }

  async prompt (text, images = []) {
    if (this.status === 'closed') throw Object.assign(new Error('This session is closed.'), { code: 'closed' })
    if (this.status === 'running') throw Object.assign(new Error('The agent is still working.'), { code: 'busy' })
    await this.ensureProcess()
    if (!this.meta.title) this.meta.title = text.replace(/\s+/g, ' ').trim().slice(0, 80)
    this.append({ kind: 'user', text, images: images.length })
    this.setStatus('running')
    const prompt = [{ type: 'text', text }]
    for (const img of images) if (img && img.data && img.mimeType) prompt.push({ type: 'image', data: img.data, mimeType: img.mimeType })
    this.peer.request('session/prompt', { sessionId: this.meta.agentSessionId, prompt }).then(
      (r) => this.append({ kind: 'turn_end', stopReason: (r && r.stopReason) || 'end_turn' }),
      (e) => {
        this.append({ kind: 'error', code: isAuthError(e) ? 'auth_required' : (typeof e.code === 'string' ? e.code : 'prompt_failed'), message: String(e.message || '') })
        this.append({ kind: 'turn_end', stopReason: 'error' })
      }
    ).finally(() => {
      this.daemon.turnEnded(this)
      if (this.status === 'running') this.setStatus(this.peer ? 'idle' : 'stopped')
    })
  }

  cancel () {
    if (this.peer && this.meta.agentSessionId) this.peer.notify('session/cancel', { sessionId: this.meta.agentSessionId })
    this.cancelPermissions()
  }

  async setMode (modeId) {
    await this.ensureProcess()
    await this.peer.request('session/set_mode', { sessionId: this.meta.agentSessionId, modeId: String(modeId) })
    if (this.meta.modes) this.meta.modes.currentModeId = String(modeId)
    this.daemon.saveSessions()
    this.daemon.sessionChanged(this)
  }

  /** set_mode on the running agent while it starts; a refusal is logged, the session goes on. */
  async applyMode (modeId) {
    const offered = this.meta.modes && Array.isArray(this.meta.modes.availableModes) &&
      this.meta.modes.availableModes.some((m) => m && m.id === modeId)
    if (!offered) {
      this.append({ kind: 'error', code: 'mode_failed', message: modeId })
      return
    }
    try {
      await this.peer.request('session/set_mode', { sessionId: this.meta.agentSessionId, modeId })
      this.meta.modes.currentModeId = modeId
    } catch (e) {
      this.append({ kind: 'error', code: 'mode_failed', message: String(e.message || modeId) })
    }
  }

  /**
   * Bypass on or off. A mode-based agent switches at once (back to the mode it had before, or the
   * one it started in); one that needs arguments is stopped when idle and starts with or without
   * them on the next prompt. Either way the summary shows what the agent last confirmed.
   */
  async setBypass (on) {
    const def = this.def()
    const b = def && def.bypass
    if (!b) throw Object.assign(new Error('This agent has no way to skip permission requests.'), { code: 'bypass_unsupported' })
    if (this.status === 'closed') throw Object.assign(new Error('This session is closed.'), { code: 'closed' })
    if (b.mode) {
      await this.ensureProcess()
      const current = this.meta.modes && this.meta.modes.currentModeId
      if (on) {
        if (current === b.mode) return
        if (current) this.meta.modeBeforeBypass = current
        await this.setMode(b.mode)
        return
      }
      if (current !== b.mode) return
      const modes = (this.meta.modes && Array.isArray(this.meta.modes.availableModes) ? this.meta.modes.availableModes : []).map((m) => m && m.id)
      const back = [this.meta.modeBeforeBypass, this.meta.initialMode, ...modes].find((m) => m && m !== b.mode && modes.includes(m))
      if (!back) throw Object.assign(new Error('The agent offers no other mode.'), { code: 'bypass_unsupported' })
      await this.setMode(back)
      return
    }
    if (!!this.meta.bypass === !!on) return
    if (this.status === 'running' || this.status === 'starting' || this.permissions.size) {
      throw Object.assign(new Error('The agent is still working.'), { code: 'busy' })
    }
    if (on) this.meta.bypass = true
    else delete this.meta.bypass
    this.daemon.saveSessions()
    await this.stopProcess()
    this.daemon.sessionChanged(this)
  }

  /** Stops the process and waits for it to go (the session stays; the next prompt starts it). */
  stopProcess () {
    const child = this.child
    if (!child) return Promise.resolve()
    return new Promise((resolve) => {
      child.once('exit', () => setImmediate(resolve))
      try { child.kill() } catch (e) { resolve() }
    })
  }

  stop () {
    this.cancelPermissions()
    if (this.child) { try { this.child.kill() } catch (e) {} }
  }

  close () {
    this.stop()
    this.meta.closed = true
    this.setStatus('closed')
  }
}

function expandHome (p) {
  if (!p || p === '~') return os.homedir()
  if (p.startsWith('~/')) return path.join(os.homedir(), p.slice(2))
  return p
}

// ── Daemon ──────────────────────────────────────────────────────────────────────────────────────

class Daemon {
  constructor ({ dir = stateDir(), log = defaultLog, idleMs = PHONE_IDLE_MS, hostName = os.hostname(), onIdle = null, idleExitMs = IDLE_EXIT_MS } = {}) {
    this.dir = dir
    this.files = files(dir)
    this.log = log
    this.idleMs = idleMs
    this.hostName = hostName
    this.token = crypto.randomBytes(32).toString('hex')
    this.shimToken = crypto.randomBytes(32).toString('hex')
    this.catalog = readJson(this.files.catalog)
    this.channels = new Map()
    this.nextChannel = 1
    this.phone = null
    this.port = null
    this.shimServer = null
    this.phoneServer = null
    this.lanServer = null
    this.lanPort = null
    this.pairing = null
    this.lastPaired = null
    this.identity = null
    this.peers = []
    this.sessions = new Map()
    this.tickets = new Map()
    /** Per agent, the environment the phone last set (memory only; see cleanEnv). */
    this.envs = new Map()
    this.listing = new Map()
    this.agentCache = null
    /** A newer copy wants to take over: exit once no agent is working (see `retire`). */
    this.retiring = false
    this.closed = false
    this.onIdle = onIdle
    this.idleExitMs = idleExitMs
    this.idleSince = Date.now()
    this.idleTimer = null
  }

  /** Nothing would be lost by exiting: no phone, no agent connected, nothing running, not listening. */
  isIdle () {
    return !this.phone && this.channels.size === 0 && !this.lanServer &&
      ![...this.sessions.values()].some((s) => s.child)
  }

  checkIdle () {
    if (!this.isIdle()) { this.idleSince = Date.now(); return }
    if (Date.now() - this.idleSince >= this.idleExitMs && this.onIdle) {
      this.log('idle for ' + Math.round(this.idleExitMs / 60000) + ' min, exiting')
      this.close('idle').then(() => this.onIdle())
    }
  }

  /** Binds both listeners and writes daemon.json. Resolves false when another daemon already owns the socket. */
  async start () {
    ensureDir(this.dir)
    const where = shimPath(this.dir)
    this.shimServer = net.createServer((sock) => this.onShim(sock))
    const bound = await listenExclusive(this.shimServer, where)
    if (!bound) return false
    if (process.platform !== 'win32') { try { fs.chmodSync(where, 0o600) } catch (e) {} }
    this.phoneServer = net.createServer((sock) => this.onPhone(sock))
    await new Promise((resolve, reject) => {
      this.phoneServer.once('error', reject)
      this.phoneServer.listen(0, '127.0.0.1', resolve)
    })
    this.port = this.phoneServer.address().port
    this.identity = loadIdentity(this.files.identity)
    this.peers = (readJson(this.files.peers) || []).filter((p) => p && typeof p.key === 'string')
    this.loadSessions()
    const lan = readJson(this.files.lan)
    if (lan && lan.enabled) {
      try { await this.startLan(lan.port) } catch (e) { this.log('network listener not started: ' + e.code) }
    }
    writeAtomic(this.files.info, JSON.stringify(this.info(), null, 2) + '\n')
    this.log('daemon ' + VERSION + ' listening (phone port ' + this.port + ')')
    if (this.onIdle) {
      this.idleTimer = setInterval(() => this.checkIdle(), Math.min(60000, this.idleExitMs))
      this.idleTimer.unref()
    }
    return true
  }

  info () {
    return {
      v: 1,
      version: VERSION,
      pid: process.pid,
      port: this.port,
      token: this.token,
      shim: { path: shimPath(this.dir), token: this.shimToken },
      startedAt: new Date().toISOString()
    }
  }

  status () {
    return {
      version: VERSION,
      pid: process.pid,
      phone: this.phone ? { name: this.phone.name, app: this.phone.app, since: this.phone.since } : null,
      agents: [...this.channels.values()].filter((c) => c.client).map((c) => c.client.name || 'unknown'),
      tools: this.catalog && Array.isArray(this.catalog.tools) ? this.catalog.tools.length : 0,
      caps: CAPS,
      lan: {
        enabled: !!this.lanServer,
        port: this.lanPort,
        key: this.identity ? b64u(this.identity.pub) : null,
        fingerprint: this.identity ? fingerprint(this.identity.pub) : null
      },
      peers: this.peers.length,
      pairing: !!(this.pairing && Date.now() < this.pairing.expiresAt),
      lastPaired: this.lastPaired,
      sessions: [...this.sessions.values()].filter((x) => x.status !== 'closed').length,
      busy: this.busySessions()
    }
  }

  /** Sessions whose agent is working or waiting for an answer: replacing the daemon would cut them off. */
  busySessions () {
    return [...this.sessions.values()].filter((x) => x.status === 'running' || x.status === 'starting' || x.permissions.size > 0).length
  }

  /** Retiring and nothing works any more: stop, so the next start runs the newer copy. */
  checkRetire () {
    if (!this.retiring || this.closed || this.busySessions() > 0) return
    this.log('retiring: no agent is working')
    this.close('replaced').then(() => this.onShutdown && this.onShutdown())
  }

  async close (code = 'shutdown') {
    if (this.closed) return
    this.closed = true
    clearInterval(this.idleTimer)
    if (this.phone) this.dropPhone(this.phone, code)
    for (const ch of this.channels.values()) ch.sock.destroy()
    this.channels.clear()
    for (const session of this.sessions.values()) session.stop()
    await Promise.all([this.shimServer, this.phoneServer, this.lanServer].filter(Boolean).map((s) => new Promise((resolve) => s.close(resolve))))
    const info = readJson(this.files.info)
    if (info && info.pid === process.pid && info.token === this.token) {
      try { fs.unlinkSync(this.files.info) } catch (e) {}
    }
    this.log('daemon stopped (' + code + ')')
  }

  // ── Agents (shim connections) ─────────────────────────────────────────────────────────────────

  onShim (sock) {
    let ch = null
    const timer = setTimeout(() => sock.destroy(), HELLO_TIMEOUT_MS)
    sock.on('error', () => {})
    const reader = readLines(sock, MAX_LINE, (line) => {
      if (ch) return this.fromAgent(ch, line)
      clearTimeout(timer)
      const hello = parseHello(line)
      if (!hello || hello.dshGoLinkShim !== 1 || !safeEqual(hello.token, this.shimToken)) {
        send(sock, { ok: false, code: 'bad_token' })
        sock.end()
        reader.stop()
        return
      }
      if (hello.op === 'status') { send(sock, { ok: true, status: this.status() }); sock.end(); reader.stop(); return }
      if (typeof hello.op === 'string' && hello.op !== 'shutdown') {
        reader.stop()
        Promise.resolve().then(() => this.onOp(hello.op, hello))
          .then((result) => send(sock, { ok: true, ...result }), (e) => send(sock, { ok: false, code: e.code || 'failed', message: e.message }))
          .finally(() => sock.end())
        return
      }
      if (hello.op === 'shutdown') {
        send(sock, { ok: true })
        sock.end()
        reader.stop()
        this.close('shutdown').then(() => this.onShutdown && this.onShutdown())
        return
      }
      // `mcp --bind <ticket>`: the phone tools of one agent session this daemon started.
      const bound = typeof hello.bind === 'string' ? this.tickets.get(hello.bind) || null : null
      ch = { id: 'm' + this.nextChannel++, sock, client: null, initialized: false, opened: false, pending: new Map(), session: bound }
      this.channels.set(ch.id, ch)
      send(sock, { ok: true })
    }, () => sock.destroy())
    sock.on('close', () => {
      clearTimeout(timer)
      if (!ch) return
      this.channels.delete(ch.id)
      if (ch.opened && this.phone) send(this.phone.sock, { t: 'close', ch: ch.id })
    })
  }

  fromAgent (ch, line) {
    const parsed = parseMessage(line)
    if (parsed.bad) return send(ch.sock, parsed.bad)
    const { msg, isRequest } = parsed
    if (!isRequest) return // notifications (initialized, cancelled) and responses: nothing for the phone
    switch (msg.method) {
      case 'initialize': {
        const info = msg.params && msg.params.clientInfo
        // Reported by the agent, not verified: the phone shows it as a label only.
        if ((info && typeof info === 'object') || !ch.client) {
          ch.client = {
            name: info && typeof info.name === 'string' ? info.name.slice(0, 100) : null,
            title: info && typeof info.title === 'string' ? info.title.slice(0, 100) : null,
            version: info && typeof info.version === 'string' ? info.version.slice(0, 50) : null
          }
        }
        ch.initialized = true
        this.log('agent ' + ch.id + ' connected: ' + (ch.client.name || 'unknown'))
        return send(ch.sock, answerLocally(msg, this.catalog))
      }
      case 'ping':
      case 'tools/list':
        return send(ch.sock, answerLocally(msg, this.catalog))
    }
    const phone = this.phone
    if (!phone) return send(ch.sock, answerLocally(msg, this.catalog))
    if (!ch.opened) {
      const origin = { ...(ch.client || { name: null }) }
      if (ch.session) { origin.session = ch.session.id; origin.agent = ch.session.meta.agent; origin.title = ch.session.meta.agentName }
      send(phone.sock, { t: 'open', ch: ch.id, kind: 'mcp', origin })
      ch.opened = true
    }
    ch.pending.set(idKey(msg.id), msg.method)
    send(phone.sock, { t: 'data', ch: ch.id, line })
  }

  /** Answers every request still waiting on the phone ([why] for tool calls). */
  failPending (ch, why = LOST) {
    for (const [key, method] of ch.pending) {
      const id = JSON.parse(key)
      send(ch.sock, method === 'tools/call' ? toolError(id, why) : rpcError(id, -32603, 'The phone disconnected'))
    }
    ch.pending.clear()
  }

  // ── The phone ─────────────────────────────────────────────────────────────────────────────────

  /** A phone: on the loopback port (token, through SSH), or over the network ([lan]: its Noise key). */
  onPhone (sock, { lan = null } = {}) {
    let phone = null
    sock.setNoDelay(true)
    sock.on('error', () => {})
    const timer = setTimeout(() => sock.destroy(), HELLO_TIMEOUT_MS)
    let max = MAX_HELLO
    readLines(sock, MAX_LINE, (line) => {
      if (phone) return this.fromPhone(phone, line)
      clearTimeout(timer)
      if (line.length > max) { sock.destroy(); return }
      const hello = parseHello(line)
      if (!hello || hello.dshGoLink !== PROTOCOL) {
        send(sock, { ok: false, code: 'protocol', protocol: PROTOCOL })
        sock.end()
        return
      }
      const info = hello.phone && typeof hello.phone === 'object' ? hello.phone : {}
      if (lan) {
        if (!this.peers.some((p) => p.key === lan.key)) {
          const pairing = this.pairing
          if (!pairing || Date.now() > pairing.expiresAt || !safeEqual(hello.pair, pairing.secret)) {
            send(sock, { ok: false, code: 'not_paired' })
            sock.end()
            this.log('phone refused: not paired')
            return
          }
          this.pairing = null
          const name = typeof info.name === 'string' ? info.name.slice(0, 100) : 'phone'
          this.peers.push({ key: lan.key, name, pairedAt: new Date().toISOString() })
          this.savePeers()
          this.lastPaired = { name, at: new Date().toISOString() }
          this.log('phone paired: ' + name)
        }
      } else if (!safeEqual(hello.token, this.token)) {
        send(sock, { ok: false, code: 'bad_token' })
        sock.end()
        this.log('phone refused: bad token')
        return
      }
      max = MAX_LINE
      phone = {
        sock,
        name: typeof info.name === 'string' ? info.name.slice(0, 100) : 'phone',
        app: typeof info.app === 'string' ? info.app.slice(0, 50) : null,
        since: new Date().toISOString(),
        idle: null
      }
      if (this.phone) this.dropPhone(this.phone, 'replaced')
      this.phone = phone
      const changed = this.takeCatalog(hello.mcp)
      phone.watching = new Set()
      send(sock, { ok: true, link: { version: VERSION, protocol: PROTOCOL }, host: { name: this.hostName, os: process.platform }, caps: CAPS })
      this.log('phone attached: ' + phone.name + (phone.app ? ' (' + phone.app + ')' : ''))
      this.touch(phone)
      if (changed) for (const ch of this.channels.values()) if (ch.initialized) send(ch.sock, listChanged())
    }, () => sock.destroy())
    sock.on('close', () => {
      clearTimeout(timer)
      if (phone && this.phone === phone) this.phoneGone(phone, 'closed')
    })
  }

  /** Keeps the phone's tool list (and instructions) for agents; true when it changed. */
  takeCatalog (mcp) {
    if (!mcp || typeof mcp !== 'object' || !Array.isArray(mcp.tools)) return false
    const next = {
      tools: mcp.tools,
      instructions: typeof mcp.instructions === 'string' ? mcp.instructions : null,
      server: mcp.serverInfo && typeof mcp.serverInfo === 'object' ? mcp.serverInfo : null
    }
    const before = this.catalog ? JSON.stringify({ tools: this.catalog.tools, instructions: this.catalog.instructions }) : null
    const after = JSON.stringify({ tools: next.tools, instructions: next.instructions })
    this.catalog = next
    if (before === after) return false
    try { writeAtomic(this.files.catalog, JSON.stringify(next) + '\n') } catch (e) { this.log('catalog not saved: ' + e.code) }
    return true
  }

  touch (phone) {
    clearTimeout(phone.idle)
    phone.idle = setTimeout(() => {
      if (this.phone !== phone) return
      this.log('phone silent for ' + Math.round(this.idleMs / 1000) + ' s')
      this.dropPhone(phone, 'idle')
    }, this.idleMs)
    if (phone.idle.unref) phone.idle.unref()
  }

  fromPhone (phone, line) {
    if (this.phone !== phone) return
    this.touch(phone)
    let frame
    try { frame = JSON.parse(line) } catch (e) { return }
    if (!frame || typeof frame !== 'object') return
    switch (frame.t) {
      case 'ping': send(phone.sock, { t: 'pong' }); return
      case 'data': {
        const ch = this.channels.get(frame.ch)
        if (!ch || typeof frame.line !== 'string') return
        const parsed = parseMessage(frame.line)
        if (parsed.msg && Object.prototype.hasOwnProperty.call(parsed.msg, 'id')) ch.pending.delete(idKey(parsed.msg.id))
        send(ch.sock, frame.line)
        return
      }
      case 'close': {
        const ch = this.channels.get(frame.ch)
        if (!ch) return
        this.failPending(ch, typeof frame.message === 'string' ? frame.message : LOST)
        ch.opened = false
        return
      }
      case 'bye': this.dropPhone(phone, 'bye'); return
      case 'call': {
        const id = frame.id
        Promise.resolve()
          .then(() => this.onCall(phone, String(frame.method || ''), frame.params && typeof frame.params === 'object' ? frame.params : {}))
          .then((result) => { if (this.phone === phone) send(phone.sock, { t: 'result', id, result: result === undefined ? null : result }) },
            (e) => { if (this.phone === phone) send(phone.sock, { t: 'result', id, error: { code: typeof e.code === 'string' ? e.code : 'failed', message: String(e.message || e) } }) })
      }
    }
  }

  dropPhone (phone, code) {
    if (code !== 'bye' && code !== 'closed') send(phone.sock, { t: 'bye', code })
    phone.sock.end()
    setTimeout(() => phone.sock.destroy(), 1000).unref()
    if (this.phone === phone) this.phoneGone(phone, code)
  }

  phoneGone (phone, code) {
    clearTimeout(phone.idle)
    this.phone = null
    for (const ch of this.channels.values()) {
      this.failPending(ch)
      ch.opened = false
    }
    this.log('phone detached (' + code + ')')
  }

  // ── Network pairing ───────────────────────────────────────────────────────────────────────────

  /** Shim-socket operations from this computer's own CLI (`pair`, `lan off`, `peers`). */
  async onOp (op, params) {
    switch (op) {
      case 'pair': {
        await this.startLan(Number.isInteger(params.port) ? params.port : (readJson(this.files.lan) || {}).port)
        this.pairing = { secret: b64u(crypto.randomBytes(16)), expiresAt: Date.now() + PAIR_TTL_MS }
        return { port: this.lanPort, key: b64u(this.identity.pub), secret: this.pairing.secret, expiresAt: this.pairing.expiresAt, name: this.hostName, addresses: lanAddresses() }
      }
      case 'pair-status':
        return { pending: !!(this.pairing && Date.now() < this.pairing.expiresAt), lastPaired: this.lastPaired }
      case 'lan-off':
        await this.stopLan()
        return {}
      case 'peers':
        return { peers: this.peers.map((p) => ({ id: p.key.slice(0, 12), name: p.name, pairedAt: p.pairedAt })) }
      case 'retire':
        // `start` of another version while agents work here: they finish first (checkRetire).
        this.retiring = true
        setImmediate(() => this.checkRetire())
        return { busy: this.busySessions() }
      case 'peers-remove': {
        const id = String(params.id || '')
        const before = this.peers.length
        this.peers = this.peers.filter((p) => !(id && (p.key.startsWith(id) || p.name === id)))
        this.savePeers()
        return { removed: before - this.peers.length }
      }
      default:
        throw Object.assign(new Error('unknown operation'), { code: 'unknown_op' })
    }
  }

  savePeers () {
    try { writeAtomic(this.files.peers, JSON.stringify(this.peers, null, 2) + '\n') } catch (e) { this.log('peers not saved: ' + e.code) }
  }

  /** Listens on the network (Noise only; nothing is readable before the handshake). */
  async startLan (port) {
    if (this.lanServer) return
    const server = net.createServer((sock) => this.onLan(sock))
    const listen = (p) => new Promise((resolve, reject) => {
      server.once('error', reject)
      server.listen(p || 0, '0.0.0.0', () => { server.removeListener('error', reject); resolve() })
    })
    try {
      await listen(port)
    } catch (e) {
      if (!port || e.code !== 'EADDRINUSE') throw e
      await listen(0)
    }
    this.lanServer = server
    this.lanPort = server.address().port
    writeAtomic(this.files.lan, JSON.stringify({ enabled: true, port: this.lanPort }) + '\n')
    this.log('network listener on port ' + this.lanPort)
  }

  async stopLan () {
    this.pairing = null
    const server = this.lanServer
    this.lanServer = null
    writeAtomic(this.files.lan, JSON.stringify({ enabled: false, port: this.lanPort }) + '\n')
    if (server) await new Promise((resolve) => server.close(resolve))
  }

  onLan (sock) {
    sock.setNoDelay(true)
    sock.on('error', () => {})
    const timer = setTimeout(() => sock.destroy(), HELLO_TIMEOUT_MS)
    const noise = new NoiseIK({ initiator: false, s: this.identity })
    let done = false
    const reader = new FrameReader((msg) => {
      if (done) return false
      done = true
      try {
        noise.readMessage1(msg)
        sock.write(frame(noise.writeMessage2()))
      } catch (e) {
        this.log('network handshake failed')
        sock.destroy()
        return false
      }
      clearTimeout(timer)
      const leftover = reader.buf
      reader.buf = EMPTY
      this.onPhone(new SecureStream(sock, noise, leftover), { lan: { key: b64u(noise.rs) } })
      return false
    })
    sock.on('data', (d) => { if (!done) reader.feed(d) })
    sock.on('close', () => clearTimeout(timer))
  }

  // ── Agent sessions ────────────────────────────────────────────────────────────────────────────

  /** The agent registry, re-read at most every few seconds (summaries ask often). */
  agents () {
    const now = Date.now()
    if (!this.agentCache || now - this.agentCache.at > 3000) this.agentCache = { at: now, list: agentRegistry(this.files.agents) }
    return this.agentCache.list
  }

  /** The environment an agent starts with: this computer's, plus what the phone set. */
  agentEnv (agent) { return Object.assign({}, process.env, this.envs.get(agent) || {}) }

  /** Keeps the environment a request carries for [agent] (the phone sends it with every request that may start one). */
  takeEnv (agent, raw) {
    const env = cleanEnv(raw)
    if (env) this.envs.set(agent, env)
  }

  /**
   * The agent's own sessions in [cwd] (ACP `session/list`; includes ones started in a terminal),
   * from a short-lived process of that agent. Concurrent asks for the same folder share it.
   */
  agentHistory (def, cwd) {
    const key = def.id + '\0' + cwd
    if (this.listing.has(key)) return this.listing.get(key)
    const job = (async () => {
      const exe = which(def.command[0]) || def.command[0]
      const child = spawn(exe, def.command.slice(1), { cwd, env: this.agentEnv(def.id), stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true })
      const peer = new JsonRpcPeer(child.stdout, child.stdin, {
        onRequest: () => Promise.reject(Object.assign(new Error('Method not found'), { code: -32601 })),
        onNotification: () => {}
      })
      child.once('error', (e) => peer.close(Object.assign(new Error(e.message), { code: 'spawn_failed' })))
      child.once('exit', () => peer.close())
      try {
        const init = await withTimeout(peer.request('initialize', {
          protocolVersion: ACP_PROTOCOL,
          clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
          clientInfo: { name: 'dsh-go-link', title: 'DSH Go', version: VERSION }
        }), 30000)
        const caps = (init && init.agentCapabilities) || {}
        const canLoad = !!caps.loadSession
        if (!(caps.sessionCapabilities && caps.sessionCapabilities.list)) return { listed: false, canLoad, sessions: [] }
        const r = await withTimeout(peer.request('session/list', { cwd }), 30000)
        const sessions = []
        for (const x of (r && Array.isArray(r.sessions) ? r.sessions : []).slice(0, 100)) {
          if (!x || typeof x.sessionId !== 'string' || !x.sessionId) continue
          if (typeof x.cwd === 'string' && path.resolve(x.cwd) !== cwd) continue
          sessions.push({ agentSessionId: x.sessionId, title: typeof x.title === 'string' ? x.title.slice(0, 200) : null, updatedAt: typeof x.updatedAt === 'string' ? x.updatedAt : null })
        }
        return { listed: true, canLoad, sessions }
      } finally {
        try { child.kill() } catch (e) {}
      }
    })().finally(() => this.listing.delete(key))
    this.listing.set(key, job)
    return job
  }

  /** A folder on this computer, resolved (`~` expanded); a `no_folder` error when it is not one. */
  folder (raw) {
    const cwd = path.resolve(expandHome(typeof raw === 'string' && raw.trim() ? raw.trim() : '~'))
    let isDir = false
    try { isDir = fs.statSync(cwd).isDirectory() } catch (e) {}
    if (!isDir) throw Object.assign(new Error('No such folder on the computer.'), { code: 'no_folder' })
    return cwd
  }

  /** An installed agent by id, or an `agent_unavailable` error. */
  installedAgent (id) {
    const agent = this.agents().find((a) => a.id === id)
    if (!agent || !agent.available) throw Object.assign(new Error('This agent is not installed on the computer.'), { code: 'agent_unavailable' })
    return agent
  }

  /** A new session of [agent] in [cwd] that this daemon keeps, started at once. */
  addSession (phone, agent, cwd, extra) {
    const now = new Date().toISOString()
    const meta = { id: crypto.randomUUID(), agent: agent.id, agentName: agent.name, cwd, title: null, createdAt: now, updatedAt: now, seq: 0, ...extra }
    const session = new AgentSession(this, meta)
    this.sessions.set(meta.id, session)
    this.saveSessions()
    phone.watching.add(meta.id)
    session.ensureProcess().catch(() => {}) // failures are in its log
    return session
  }

  loadSessions () {
    ensureDir(this.files.sessions)
    const index = readJson(path.join(this.files.sessions, 'index.json')) || []
    for (const meta of index) {
      if (meta && typeof meta.id === 'string' && /^[a-z0-9-]+$/.test(meta.id)) this.sessions.set(meta.id, new AgentSession(this, meta))
    }
  }

  saveSessions () {
    const index = [...this.sessions.values()].map((s) => s.meta)
    try { writeAtomic(path.join(this.files.sessions, 'index.json'), JSON.stringify(index) + '\n') } catch (e) { this.log('sessions not saved: ' + e.code) }
  }

  session (id) {
    const s = this.sessions.get(String(id))
    if (!s) throw Object.assign(new Error('No such session.'), { code: 'no_session' })
    return s
  }

  /** A new event of [session]: to the phone when it is watching that session. */
  sessionEvent (session, event) {
    const phone = this.phone
    if (phone && phone.watching && phone.watching.has(session.id)) send(phone.sock, { t: 'event', name: 'session', data: { id: session.id, event } })
  }

  /** The session's summary changed (status, title, pending approvals): always to the phone. */
  sessionChanged (session) {
    if (this.phone) send(this.phone.sock, { t: 'event', name: 'sessions', data: session.summary() })
    if (this.retiring) setImmediate(() => this.checkRetire())
  }

  /** A turn ended: the phone finishes a phone task this session's agent owns. */
  turnEnded (session) {
    if (this.phone) send(this.phone.sock, { t: 'event', name: 'turn_end', data: { id: session.id } })
  }

  /** The phone's requests (`call` frames). */
  async onCall (phone, method, p) {
    switch (method) {
      case 'setup.agents':
        return { agents: agentConfigs() }
      case 'agents.list':
        return {
          agents: this.agents().map((a) => ({
            id: a.id, name: a.name, available: a.available,
            // `mode`: switches at any time; `restart`: the agent restarts (between turns) to switch.
            bypass: a.bypass ? (a.bypass.mode ? 'mode' : 'restart') : null
          }))
        }
      case 'sessions.list':
        return { sessions: [...this.sessions.values()].filter((s) => s.status !== 'closed').map((s) => s.summary()) }
      case 'sessions.new': {
        const agent = this.installedAgent(p.agent)
        const cwd = this.folder(p.cwd)
        this.takeEnv(agent.id, p.env)
        const session = this.addSession(phone, agent, cwd, p.bypass === true && agent.bypass ? { bypass: true } : {})
        return { session: session.summary() }
      }
      case 'sessions.history': {
        // The folder's sessions of one agent: the ones this daemon keeps (open them as they are) and
        // the agent's own (started in a terminal, or here before), newest first.
        const agent = this.installedAgent(p.agent)
        const cwd = this.folder(p.cwd)
        this.takeEnv(agent.id, p.env)
        const ours = [...this.sessions.values()].filter((s) => s.status !== 'closed' && s.meta.agent === agent.id && s.meta.cwd === cwd)
        const listed = await this.agentHistory(agent, cwd).catch((e) => ({ listed: false, canLoad: false, sessions: [], error: e.code || 'failed' }))
        const byAgentId = new Map(ours.filter((s) => s.meta.agentSessionId).map((s) => [s.meta.agentSessionId, s]))
        const entries = ours.map((s) => ({ agentSessionId: s.meta.agentSessionId || null, title: s.meta.title || null, updatedAt: s.meta.updatedAt, session: s.summary() }))
        for (const x of listed.sessions) if (!byAgentId.has(x.agentSessionId)) entries.push({ ...x, session: null })
        entries.sort((a, b) => String(b.updatedAt || '').localeCompare(String(a.updatedAt || '')))
        return { cwd, listed: listed.listed, canLoad: listed.canLoad, error: listed.error || null, sessions: entries.slice(0, 100) }
      }
      case 'sessions.resume': {
        // An earlier session of the agent: one this daemon keeps is only watched (a running turn
        // goes on undisturbed); another becomes a session here, its history replayed by the agent.
        const agent = this.installedAgent(p.agent)
        const agentSessionId = typeof p.agentSessionId === 'string' ? p.agentSessionId : ''
        if (!agentSessionId) throw Object.assign(new Error('Which session?'), { code: 'no_session' })
        this.takeEnv(agent.id, p.env)
        const kept = [...this.sessions.values()].find((s) => s.status !== 'closed' && s.meta.agent === agent.id && s.meta.agentSessionId === agentSessionId)
        if (kept) {
          phone.watching.add(kept.id)
          return { session: kept.summary(), attached: true }
        }
        const cwd = this.folder(p.cwd)
        const title = typeof p.title === 'string' && p.title.trim() ? p.title.trim().slice(0, 200) : null
        const session = this.addSession(phone, agent, cwd, { agentSessionId, imported: true, title, ...(p.bypass === true && agent.bypass ? { bypass: true } : {}) })
        return { session: session.summary(), attached: false }
      }
      case 'sessions.bypass': {
        const s = this.session(p.id)
        this.takeEnv(s.meta.agent, p.env)
        await s.setBypass(p.on === true)
        return { session: s.summary() }
      }
      case 'sessions.watch': {
        const s = this.session(p.id)
        phone.watching.add(s.id)
        const { events, truncated } = s.since(Number.isInteger(p.afterSeq) ? p.afterSeq : 0)
        return { session: s.summary(), events, truncated }
      }
      case 'sessions.unwatch':
        phone.watching.delete(String(p.id))
        return {}
      case 'sessions.prompt': {
        const text = typeof p.text === 'string' ? p.text : ''
        const images = Array.isArray(p.images) ? p.images.slice(0, 8) : []
        if (!text.trim() && !images.length) throw Object.assign(new Error('Nothing to send.'), { code: 'empty' })
        const s = this.session(p.id)
        this.takeEnv(s.meta.agent, p.env)
        await s.prompt(text, images)
        return {}
      }
      case 'sessions.cancel':
        this.session(p.id).cancel()
        return {}
      case 'sessions.permission':
        this.session(p.id).answerPermission(String(p.requestId || ''), typeof p.optionId === 'string' ? p.optionId : null)
        return {}
      case 'sessions.mode': {
        const s = this.session(p.id)
        this.takeEnv(s.meta.agent, p.env)
        await s.setMode(p.modeId)
        return {}
      }
      case 'sessions.close':
        this.session(p.id).close()
        return {}
      case 'fs.list': {
        const dir = path.resolve(expandHome(typeof p.path === 'string' && p.path ? p.path : '~'))
        let entries = []
        try { entries = fs.readdirSync(dir, { withFileTypes: true }) } catch (e) { throw Object.assign(new Error('Cannot read this folder.'), { code: 'no_folder' }) }
        const dirs = entries.filter((e) => e.isDirectory() && !e.name.startsWith('.')).map((e) => e.name).sort((a, b) => a.localeCompare(b)).slice(0, 500)
        return { path: dir, parent: path.dirname(dir) === dir ? null : path.dirname(dir), home: os.homedir(), dirs }
      }
      default:
        throw Object.assign(new Error('Unknown request: ' + method), { code: 'unknown_method' })
    }
  }
}

function parseHello (line) {
  try {
    const v = JSON.parse(line)
    return v && typeof v === 'object' && !Array.isArray(v) ? v : null
  } catch (e) {
    return null
  }
}

/** Listens on a unix socket / named pipe; a stale socket file is replaced, a live one means "taken" (false). */
function listenExclusive (server, where) {
  return new Promise((resolve, reject) => {
    const attempt = (again) => {
      const onError = (e) => {
        if (e.code !== 'EADDRINUSE' || again) return reject(e)
        canConnect(where).then((alive) => {
          if (alive) return resolve(false)
          try { fs.unlinkSync(where) } catch (err) {}
          attempt(true)
        })
      }
      server.once('error', onError)
      server.listen(where, () => {
        server.removeListener('error', onError)
        resolve(true)
      })
    }
    attempt(false)
  })
}

function canConnect (where, timeoutMs = 1000) {
  return new Promise((resolve) => {
    const sock = net.connect(where)
    const done = (v) => { clearTimeout(timer); sock.destroy(); resolve(v) }
    const timer = setTimeout(() => done(false), timeoutMs)
    sock.once('connect', () => done(true))
    sock.once('error', () => done(false))
  })
}

function defaultLog (line) {
  try { process.stderr.write(new Date().toISOString() + ' ' + line + '\n') } catch (e) {}
}

// ── Talking to the running daemon ───────────────────────────────────────────────────────────────

/** One shim-socket request ({op, ...params}) to the daemon described by [info]; resolves its reply or null. */
function ask (info, op, params = {}, timeoutMs = 3000) {
  return new Promise((resolve) => {
    if (!info || !info.shim) return resolve(null)
    const sock = net.connect(info.shim.path)
    let settled = false
    const done = (v) => { if (settled) return; settled = true; clearTimeout(timer); sock.destroy(); resolve(v) }
    const timer = setTimeout(() => done(null), timeoutMs)
    sock.once('error', () => done(null))
    sock.once('connect', () => send(sock, { ...params, dshGoLinkShim: 1, token: info.shim.token, op }))
    readLines(sock, MAX_HELLO, (line) => done(parseHello(line)), () => done(null))
  })
}

async function runningDaemon (dir) {
  const info = readJson(files(dir).info)
  if (!info || !info.shim || typeof info.shim.path !== 'string') return null
  const reply = await ask(info, 'status')
  return reply && reply.ok ? { info, status: reply.status } : null
}

/**
 * Makes sure a daemon runs for [dir] and returns its daemon.json. With [replace], one of another
 * version is asked to stop first (the DSH Go app just installed this copy) — unless its agents are
 * working: then it keeps running and retires once they are done, so no turn is cut off.
 */
async function ensureDaemon (dir, { replace = false, timeoutMs = 10000, script = __filename } = {}) {
  ensureDir(dir)
  const running = await runningDaemon(dir)
  if (running && (!replace || running.status.version === VERSION)) return running.info
  if (running && running.status.busy > 0) {
    const retired = await ask(running.info, 'retire')
    if (retired && retired.ok) return running.info
  }
  if (running) {
    await ask(running.info, 'shutdown')
    const deadline = Date.now() + 3000
    while (Date.now() < deadline && await canConnect(running.info.shim.path, 300)) await delay(100)
  }
  const f = files(dir)
  try { if (fs.statSync(f.log).size > 1024 * 1024) fs.truncateSync(f.log, 0) } catch (e) {}
  const out = fs.openSync(f.log, 'a', 0o600)
  const child = spawn(process.execPath, [script, 'daemon'], {
    detached: true,
    stdio: ['ignore', out, out],
    env: Object.assign({}, process.env, { DSH_GO_LINK_HOME: dir }),
    windowsHide: true
  })
  child.unref()
  fs.closeSync(out)
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    await delay(100)
    const now = await runningDaemon(dir)
    if (now) return now.info
  }
  throw new Error('the daemon did not start; see ' + f.log)
}

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// ── MCP shim (what agents run) ──────────────────────────────────────────────────────────────────

/**
 * stdio ⇄ the daemon. Keeps working without one: answers from catalog.json and reconnects in the
 * background. After a reconnect it replays the agent's `initialize` (swallowing the answer), so
 * the daemon knows who it is; requests lost with a connection are answered here.
 */
function runShim ({ dir = stateDir(), input = process.stdin, output = process.stdout, start = ensureDaemon, retryMs = 1000, bind = null } = {}) {
  const f = files(dir)
  let conn = null
  let connecting = false
  let closed = false
  let initLine = null
  let replay = 0
  let answeredOffline = false
  let backoff = retryMs
  const pending = new Map()

  const write = (line) => { if (!closed) output.write(line + '\n') }

  function offline (msg) {
    if (msg.method === 'tools/list') answeredOffline = true
    write(answerLocally(msg, readJson(f.catalog)))
  }

  async function connect () {
    if (connecting || closed || conn) return
    connecting = true
    try {
      const info = await start(dir, { replace: false })
      const sock = await new Promise((resolve, reject) => {
        const s = net.connect(info.shim.path)
        s.once('connect', () => resolve(s))
        s.once('error', reject)
      })
      sock.on('error', () => {})
      send(sock, { dshGoLinkShim: 1, token: info.shim.token, bind })
      let ready = false
      readLines(sock, MAX_LINE, (line) => {
        if (!ready) {
          const hello = parseHello(line)
          if (!hello || !hello.ok) { sock.destroy(); return }
          ready = true
          conn = sock
          backoff = retryMs
          if (initLine) {
            const m = JSON.parse(initLine)
            m.id = 'dsh-go-link:replay:' + (++replay)
            send(sock, JSON.stringify(m))
          }
          if (answeredOffline) { answeredOffline = false; write(listChanged()) }
          return
        }
        const parsed = parseMessage(line)
        if (parsed.msg && Object.prototype.hasOwnProperty.call(parsed.msg, 'id')) {
          const id = parsed.msg.id
          if (typeof id === 'string' && id.startsWith('dsh-go-link:replay:')) return
          pending.delete(idKey(id))
        }
        write(line)
      }, () => sock.destroy())
      sock.on('close', () => {
        if (conn === sock) {
          conn = null
          for (const [key, method] of pending) {
            const id = JSON.parse(key)
            write(method === 'tools/call' ? toolError(id, LOST) : rpcError(id, -32603, 'dsh-go-link restarted'))
          }
          pending.clear()
        }
        retry()
      })
    } catch (e) {
      retry()
    } finally {
      connecting = false
    }
  }

  function retry () {
    if (closed || conn) return
    const wait = backoff
    backoff = Math.min(backoff * 2, 10000)
    setTimeout(connect, wait).unref()
  }

  readLines(input, MAX_LINE, (line) => {
    if (!line.trim()) return
    const parsed = parseMessage(line)
    if (parsed.bad) return write(parsed.bad)
    const { msg, isRequest } = parsed
    if (isRequest && msg.method === 'initialize') initLine = line
    if (!conn) {
      if (isRequest) offline(msg)
      return
    }
    if (isRequest) pending.set(idKey(msg.id), msg.method)
    send(conn, line)
  }, () => process.exit(1))

  const finish = () => {
    if (closed) return
    closed = true
    if (conn) conn.end()
  }
  input.on('end', finish)
  input.on('close', finish)
  output.on('error', (e) => { closed = true; if (e.code !== 'EPIPE') process.exitCode = 1; if (conn) conn.destroy() })
  connect()
  return { close: finish }
}

// ── Agent setup ─────────────────────────────────────────────────────────────────────────────────

function shQuote (s) {
  return /^[A-Za-z0-9_./:@%+=-]+$/.test(s) ? s : "'" + s.replace(/'/g, "'\\''") + "'"
}

/** How to register the phone tools with each agent, with this machine's paths. */
function agentConfigs (node = process.execPath, script = __filename) {
  const args = [script, 'mcp']
  const servers = { mcpServers: { phone: { command: node, args } } }
  return [
    {
      id: 'claude-code',
      name: 'Claude Code',
      kind: 'command',
      text: 'claude mcp add --scope user phone -- ' + [node, ...args].map(shQuote).join(' ')
    },
    {
      id: 'codex',
      name: 'Codex',
      kind: 'file',
      file: '~/.codex/config.toml',
      // A handoff waits for the person up to 11 minutes; Codex's default tool timeout is shorter.
      text: '[mcp_servers.phone]\ncommand = ' + JSON.stringify(node) + '\nargs = [' + args.map((a) => JSON.stringify(a)).join(', ') +
        ']\ntool_timeout_sec = 660\n'
    },
    {
      id: 'opencode',
      name: 'OpenCode',
      kind: 'file',
      file: '~/.config/opencode/opencode.json',
      text: JSON.stringify({ $schema: 'https://opencode.ai/config.json', mcp: { phone: { type: 'local', command: [node, ...args], enabled: true } } }, null, 2) + '\n'
    },
    {
      id: 'antigravity',
      name: 'Antigravity CLI',
      kind: 'command',
      // Headless runs (`agy -p`) can't ask: allow the tools with e.g. permissions.allow `mcp(phone/screen)`.
      text: 'agy mcp add phone -- ' + [node, ...args].map(shQuote).join(' ')
    },
    {
      id: 'antigravity-ide',
      name: 'Antigravity',
      kind: 'file',
      file: 'mcp_config.json (Agent panel → MCP Servers → Manage → View raw config)',
      text: JSON.stringify(servers, null, 2) + '\n'
    },
    {
      id: 'other',
      name: 'Other MCP clients',
      kind: 'file',
      file: 'the client\'s mcpServers settings',
      text: JSON.stringify(servers, null, 2) + '\n'
    }
  ]
}

/** `dshgo://link?…`: what the phone needs to dial and trust this computer, and the one-time secret. */
function pairingLink ({ name, key, secret, addresses }) {
  const q = new URLSearchParams({ v: '1', n: String(name || '').slice(0, 32), k: key, s: secret, a: addresses.join(',') })
  return 'dshgo://link?' + q.toString()
}

// ── CLI ─────────────────────────────────────────────────────────────────────────────────────────

async function main (argv) {
  const [cmd, ...rest] = argv
  const json = rest.includes('--json')
  const dir = stateDir()
  switch (cmd) {
    case 'mcp': {
      const at = rest.indexOf('--bind')
      // DSH_GO_LINK_NO_AUTOSTART=1: only use a running daemon (tests; setups that start it themselves).
      const start = process.env.DSH_GO_LINK_NO_AUTOSTART === '1'
        ? async (d) => { const r = await runningDaemon(d); if (!r) throw new Error('no daemon'); return r.info }
        : ensureDaemon
      runShim({ dir, bind: at >= 0 ? rest[at + 1] || null : null, start })
      return
    }
    case 'pair': {
      const addresses = []
      let port = null
      for (let i = 0; i < rest.length; i++) {
        if (rest[i] === '--address' && rest[i + 1]) addresses.push(rest[++i])
        if (rest[i] === '--port' && rest[i + 1]) port = parseInt(rest[++i], 10)
      }
      const running = await runningDaemon(dir)
      const info = await ensureDaemon(dir, { replace: !!running && !(running.status.caps || []).includes('lan.v1') })
      const r = await ask(info, 'pair', Number.isInteger(port) ? { port } : {}, 10000)
      if (!r || !r.ok) throw new Error('the daemon did not start pairing' + (r && r.message ? ': ' + r.message : ''))
      const hosts = addresses.length ? addresses : r.addresses.slice(0, 4).map((a) => a + ':' + r.port)
      const link = pairingLink({ name: r.name, key: r.key, secret: r.secret, addresses: hosts })
      const key = fingerprint(unb64u(r.key))
      if (json) { process.stdout.write(TAG + ' ' + JSON.stringify({ link, port: r.port, key: r.key, fingerprint: key, expiresAt: r.expiresAt }) + '\n'); return }
      process.stdout.write('\n' + qrText(qrMatrix(link)) + '\n\n')
      process.stdout.write('This computer\'s key: ' + key + ' (the phone shows the same before you pair).\n')
      process.stdout.write('Scan this with the phone\'s camera, or open the link below on the phone (DSH Go → Settings → Phone control → Computers → Pair).\n')
      process.stdout.write(link + '\n')
      process.stdout.write('Reachable at ' + hosts.join(', ') + '. Valid for 10 minutes, once. Waiting for the phone…\n')
      const deadline = r.expiresAt
      while (Date.now() < deadline) {
        await delay(1000)
        const st = await ask(info, 'pair-status')
        if (st && st.ok && !st.pending) {
          process.stdout.write(st.lastPaired ? 'Paired with ' + st.lastPaired.name + '.\n' : 'Pairing ended.\n')
          return
        }
      }
      process.stdout.write('The pairing code expired. Run `dsh-go-link pair` again.\n')
      process.exitCode = 1
      return
    }
    case 'lan': {
      if (rest[0] !== 'off') { process.stderr.write('usage: dsh-go-link lan off\n'); process.exitCode = 2; return }
      const running = await runningDaemon(dir)
      if (running) await ask(running.info, 'lan-off')
      process.stdout.write('not listening on the network\n')
      return
    }
    case 'peers': {
      const running = await runningDaemon(dir)
      if (!running) { process.stdout.write('not running\n'); return }
      if (rest[0] === 'remove') {
        const r = await ask(running.info, 'peers-remove', { id: rest[1] || '' })
        process.stdout.write('removed ' + ((r && r.removed) || 0) + '\n')
        return
      }
      const r = await ask(running.info, 'peers')
      const peers = (r && r.peers) || []
      if (json) { process.stdout.write(TAG + ' ' + JSON.stringify(peers) + '\n'); return }
      process.stdout.write(peers.length ? peers.map((p) => p.id + '  ' + p.name + '  ' + p.pairedAt).join('\n') + '\n' : 'no paired phones\n')
      return
    }
    case 'daemon': {
      const daemon = new Daemon({ dir, onIdle: () => process.exit(0) })
      if (!(await daemon.start())) { defaultLog('another daemon is running for ' + dir); return }
      const stop = () => daemon.close('shutdown').then(() => process.exit(0))
      daemon.onShutdown = () => process.exit(0)
      process.on('SIGTERM', stop)
      process.on('SIGINT', stop)
      return
    }
    case 'start': {
      const info = await ensureDaemon(dir, { replace: true })
      // The app reads this tagged line (token included) over SSH; never logged.
      if (json) process.stdout.write(TAG + ' ' + JSON.stringify({ v: 1, version: info.version, pid: info.pid, port: info.port, token: info.token }) + '\n')
      else process.stdout.write('dsh-go-link ' + info.version + ' running (pid ' + info.pid + ')\n')
      return
    }
    case 'status': {
      const running = await runningDaemon(dir)
      if (json) { process.stdout.write(TAG + ' ' + JSON.stringify(running ? running.status : null) + '\n'); return }
      if (!running) { process.stdout.write('not running\n'); return }
      const s = running.status
      process.stdout.write('dsh-go-link ' + s.version + ' (pid ' + s.pid + ')\n' +
        'phone: ' + (s.phone ? s.phone.name + ' since ' + s.phone.since : 'not connected') + '\n' +
        (s.lan && s.lan.fingerprint ? 'key: ' + s.lan.fingerprint + (s.lan.enabled ? ' · listening on port ' + s.lan.port : '') + '\n' : '') +
        'agents: ' + (s.agents.length ? s.agents.join(', ') : 'none') + '\n')
      return
    }
    case 'stop': {
      const running = await runningDaemon(dir)
      if (running) await ask(running.info, 'shutdown')
      process.stdout.write(running ? 'stopped\n' : 'not running\n')
      return
    }
    case 'config': {
      const which = rest.find((a) => !a.startsWith('--'))
      const all = agentConfigs()
      const picked = which ? all.filter((c) => c.id === which) : all
      if (which && !picked.length) { process.stderr.write('unknown agent: ' + which + ' (' + all.map((c) => c.id).join(', ') + ')\n'); process.exitCode = 2; return }
      if (json) { process.stdout.write(TAG + ' ' + JSON.stringify({ v: 1, node: process.execPath, script: __filename, agents: picked }) + '\n'); return }
      for (const c of picked) {
        process.stdout.write('# ' + c.name + (c.kind === 'file' ? ' — add to ' + c.file : ' — run') + '\n' + c.text + (c.text.endsWith('\n') ? '' : '\n') + '\n')
      }
      return
    }
    case '--version':
    case 'version':
      process.stdout.write(VERSION + '\n')
      return
    default:
      process.stdout.write('usage: dsh-go-link <mcp|start|daemon|status|stop|config [agent]|pair|lan off|peers [remove ID]> [--json]\n')
      process.exitCode = cmd ? 2 : 0
  }
}

module.exports = {
  VERSION,
  PROTOCOL,
  CAPS,
  MAX_LINE,
  NOT_ATTACHED,
  LOST,
  LINK_PROLOGUE,
  Daemon,
  FrameReader,
  NoiseIK,
  SecureStream,
  agentRegistry,
  fingerprint,
  frame,
  pairingLink,
  qrMatrix,
  qrText,
  x25519KeyPair,
  agentConfigs,
  answerLocally,
  ensureDaemon,
  readLines,
  runShim,
  runningDaemon,
  shimPath,
  stateDir
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((e) => {
    process.stderr.write('dsh-go-link: ' + (e && e.message ? e.message : e) + '\n')
    process.exit(1)
  })
}
