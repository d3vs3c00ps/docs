#!/usr/bin/env node
/**
 * test-coverage.mjs
 *
 * Every note must be either tested or honestly marked as untested:
 *
 *  - a note has a test at tests/<note-path>.sh, or a line in tests/untested.txt
 *    giving the reason — never both, never neither
 *  - tests/<note-path>.<variant>.sh (e.g. hardening.vm.sh, a test that needs KVM) is
 *    an extra test for the same note, allowed only next to the main test
 *  - an untested note shows a `> [!note] Not tested locally` callout, so readers
 *    know; a tested note does not
 *  - each test's `# note:` header names the note that its path mirrors
 *  - untested.txt lists no note that has gone
 *
 * MOC pages and `draft: true` notes are exempt. Needs only the Node standard library,
 * like lint-content.mjs, so it runs before `npm ci`.
 *
 * Usage: node scripts/test-coverage.mjs [--summary]
 *   --summary prints the counts and exits 0 even when notes are not covered yet.
 */

import { readFileSync, readdirSync, statSync, existsSync } from "node:fs"
import { join, relative } from "node:path"

const CONTENT = "content"
const TESTS = "tests"
const UNTESTED = join(TESTS, "untested.txt")
const HARNESS = new Set(["lib", "envs", "k8s", "nixos"])
const CALLOUT = /^>\s*\[!note\][-+]?\s*Not tested locally/m

function walk(dir, keep, out = []) {
  for (const entry of readdirSync(dir)) {
    if (entry.startsWith(".")) continue
    const abs = join(dir, entry)
    if (statSync(abs).isDirectory()) {
      if (dir === TESTS && HARNESS.has(entry)) continue
      walk(abs, keep, out)
    } else if (keep(entry)) out.push(abs)
  }
  return out
}

function frontmatter(text) {
  const m = /^---\n([\s\S]*?)\n---/.exec(text)
  const fm = {}
  if (m) {
    for (const line of m[1].split("\n")) {
      const kv = /^([a-z_]+):\s*(.*)$/.exec(line)
      if (kv) fm[kv[1]] = kv[2].trim()
    }
  }
  return fm
}

const errors = []
const summary = process.argv.includes("--summary")

const notes = new Map()
for (const file of walk(CONTENT, (f) => f.endsWith(".md"))) {
  const path = relative(CONTENT, file).replace(/\.md$/, "")
  const text = readFileSync(file, "utf8")
  const fm = frontmatter(text)
  if (fm.type === "moc" || fm.draft === "true") continue
  notes.set(path, text)
}

const tests = new Map()
const variants = []
for (const file of walk(TESTS, (f) => f.endsWith(".sh"))) {
  let path = relative(TESTS, file).replace(/\.sh$/, "")
  const variant = /^(.+)\.[a-z0-9-]+$/.exec(path)
  if (variant && !notes.has(path) && notes.has(variant[1])) {
    path = variant[1]
    variants.push([file, path])
  } else tests.set(path, file)
  const header = /^# note:\s*(\S+)/m.exec(readFileSync(file, "utf8"))
  if (!header) errors.push(`${file}: no '# note:' header`)
  else if (header[1].replace(/\.md$/, "") !== path)
    errors.push(`${file}: '# note: ${header[1]}' does not match its path (${path}.md)`)
  if (!notes.has(path)) errors.push(`${file}: no note at content/${path}.md`)
}
for (const [file, path] of variants)
  if (!tests.has(path))
    errors.push(`${file}: an extra test for ${path}, but tests/${path}.sh is missing`)

const untested = new Map()
if (existsSync(UNTESTED)) {
  readFileSync(UNTESTED, "utf8")
    .split("\n")
    .forEach((line, i) => {
      if (/^\s*(#|$)/.test(line)) return
      const m = /^(\S+)\s+(.+)$/.exec(line.trim())
      if (!m) return errors.push(`${UNTESTED}:${i + 1}: expected '<note> <reason>'`)
      const path = m[1].replace(/\.md$/, "")
      if (untested.has(path)) errors.push(`${UNTESTED}:${i + 1}: ${path} listed twice`)
      untested.set(path, m[2])
      if (!notes.has(path)) errors.push(`${UNTESTED}:${i + 1}: no note at content/${path}.md`)
    })
}

const missing = []
for (const [path, text] of notes) {
  const tested = tests.has(path)
  const listed = untested.has(path)
  if (tested && listed) errors.push(`${path}: has a test and is listed in ${UNTESTED}`)
  if (!tested && !listed) missing.push(path)
  if (listed && !CALLOUT.test(text))
    errors.push(`${path}: listed as untested but has no '> [!note] Not tested locally' callout`)
  if (tested && CALLOUT.test(text))
    errors.push(`${path}: has a test but still says 'Not tested locally'`)
}

const covered = [...notes.keys()].filter((p) => tests.has(p)).length
console.log(
  `notes: ${notes.size}  tested: ${covered}  untested (with reason): ${untested.size}  not covered: ${missing.length}`,
)

if (summary) process.exit(0)
for (const path of missing) errors.push(`${path}: no test and not in ${UNTESTED}`)
if (errors.length) {
  console.error(errors.map((e) => `  ${e}`).join("\n"))
  console.error(`\n${errors.length} coverage problem(s)`)
  process.exit(1)
}
