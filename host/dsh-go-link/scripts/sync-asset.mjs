// Copies bin/dsh-go-link.cjs to the app asset the DSH Go app installs over SSH
// (app/assets/link/dsh-go-link.cjs). `--check` fails when the copy differs.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const source = path.resolve(here, '../bin/dsh-go-link.cjs')
const target = path.resolve(here, '../../../app/assets/link/dsh-go-link.cjs')
const want = fs.readFileSync(source)
let have = null
try { have = fs.readFileSync(target) } catch (e) {}

if (process.argv.includes('--check')) {
  if (!have || !have.equals(want)) {
    console.error(`${path.relative(process.cwd(), target)} is out of date: run node host/dsh-go-link/scripts/sync-asset.mjs`)
    process.exit(1)
  }
} else if (!have || !have.equals(want)) {
  fs.mkdirSync(path.dirname(target), { recursive: true })
  fs.writeFileSync(target, want)
  console.log(`wrote ${path.relative(process.cwd(), target)}`)
}
