// Helpers shared by the dsh-go-link tests.
import fs from 'node:fs'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
export const SCRIPT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../bin/dsh-go-link.cjs')
export const link = require(SCRIPT)

/** Short: a unix socket path must fit in ~100 bytes. */
export function tmpDir () {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'dgl-'))
}

/** A line-oriented client over anything with on('data') / write, with a queue of parsed lines. */
export function lineClient (sock) {
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
    next (ms = 5000) {
      if (queue.length) return Promise.resolve(queue.shift())
      return new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new Error('timed out waiting for a line')), ms)
        waiters.push((v) => { clearTimeout(t); resolve(v) })
      })
    },
    /** The first line [match] accepts, queued or still to come; the others stay queued. */
    async until (match, ms = 8000) {
      const deadline = Date.now() + ms
      const skipped = []
      try {
        for (;;) {
          const v = await this.next(Math.max(1, deadline - Date.now()))
          if (match(v)) return v
          skipped.push(v)
        }
      } finally {
        queue.unshift(...skipped)
      }
    },
    pending: () => queue.length,
    closed: () => new Promise((resolve) => sock.destroyed ? resolve() : sock.once('close', resolve))
  }
}

export function connect (where) {
  return new Promise((resolve, reject) => {
    const s = where.port ? net.connect(where.port, where.host || '127.0.0.1') : net.connect(where)
    s.once('connect', () => resolve(s))
    s.once('error', reject)
  })
}

export async function waitFor (fn, ms = 4000) {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) {
    if (await fn()) return
    await new Promise((resolve) => setTimeout(resolve, 25))
  }
  throw new Error('condition not met in ' + ms + ' ms')
}

export const quietLog = () => {}
