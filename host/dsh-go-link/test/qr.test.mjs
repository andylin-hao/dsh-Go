// The pairing QR code: structure, and (when a decoder is around) that real scanners read it back.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { link } from './support.mjs'

// zxing-cpp in a Python with Pillow: DSH_QR_PYTHON, else ~/dev/qrvenv (see host/dsh-go-link/README.md).
const PY = process.env.DSH_QR_PYTHON || path.join(os.homedir(), 'dev/qrvenv/bin/python')
const hasDecoder = (() => {
  try { execFileSync(PY, ['-c', 'import zxingcpp, PIL'], { stdio: 'ignore' }); return true } catch (e) { return false }
})()

function decode (matrix) {
  const script = `
import json, sys, zxingcpp
from PIL import Image
m = json.load(sys.stdin)
n = len(m); s = 8; q = 4
img = Image.new('L', ((n + 2 * q) * s, (n + 2 * q) * s), 255)
for y, row in enumerate(m):
    for x, d in enumerate(row):
        if d:
            img.paste(0, ((x + q) * s, (y + q) * s, (x + q + 1) * s, (y + q + 1) * s))
r = zxingcpp.read_barcodes(img)
print(json.dumps([b.text for b in r]))
`
  return JSON.parse(execFileSync(PY, ['-c', script], { input: JSON.stringify(matrix.map((row) => row.map((d) => (d ? 1 : 0)))) }).toString())
}

const finderAt = (m, x, y) => {
  for (let dy = 0; dy < 7; dy++) {
    for (let dx = 0; dx < 7; dx++) {
      const ring = Math.max(Math.abs(dx - 3), Math.abs(dy - 3))
      if (m[y + dy][x + dx] !== (ring !== 2)) return false
    }
  }
  return true
}

test('sizes grow with the text; finders sit in three corners; too long is refused', () => {
  const sizes = [1, 14, 30, 50, 80, 120, 150, 180, 213].map((n) => link.qrMatrix('x'.repeat(n)).length)
  assert.deepEqual(sizes, [21, 21, 29, 33, 37, 45, 49, 53, 57])
  const m = link.qrMatrix('dshgo://link?v=1')
  const n = m.length
  assert.ok(finderAt(m, 0, 0) && finderAt(m, n - 7, 0) && finderAt(m, 0, n - 7))
  assert.equal(m[n - 8][8], true) // the dark module
  assert.throws(() => link.qrMatrix('x'.repeat(214)), /too long/)
})

test('the terminal rendering is two rows per line with a quiet zone', () => {
  const m = link.qrMatrix('hi')
  const lines = link.qrText(m).split('\n')
  assert.equal(lines.length, Math.ceil((m.length + 4) / 2))
  assert.ok(lines.every((l) => l.endsWith('\x1b[0m')))
})

test('a decoder reads every version back, including a real pairing link', { skip: hasDecoder ? false : 'zxing-cpp not installed' }, () => {
  const key = Buffer.alloc(32, 7).toString('base64url')
  const pairing = link.pairingLink({ name: 'yoda-workstation', key, secret: Buffer.alloc(16, 9).toString('base64url'), addresses: ['192.168.1.23:43211', '10.0.0.5:43211'] })
  for (const text of ['A', 'hello world', 'x'.repeat(60), 'Ünïcødé 你好 ✓', 'y'.repeat(150), 'z'.repeat(213), pairing]) {
    assert.deepEqual(decode(link.qrMatrix(text)), [text], text.slice(0, 30))
  }
})
