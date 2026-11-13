#!/usr/bin/env node
/**
 * lint-content.mjs
 *
 * The regression net for the migration. Checks that:
 *
 *  - no legacy MkDocs or remark markup survives anywhere
 *  - no internal identifier from the original corporate source has leaked, in any
 *    file type — a hostname was once found baked into an SVG's caption
 *  - every note has the frontmatter this vault standardises on
 *  - code fences balance
 *  - image and wikilink targets resolve
 *
 * Code fences and inline code spans are excluded from the markup and link checks,
 * because documenting the legacy syntax is legitimate — dev/markdown.md contains a
 * table of it on purpose.
 *
 * Usage: node scripts/lint-content.mjs
 */

import { existsSync, readFileSync, readdirSync, statSync } from "node:fs"
import { join, relative, dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const ROOT = "content"
const REQUIRED = ["title", "description", "tags", "type", "status"]
const TYPES = new Set(["concept", "howto", "reference", "lab", "moc"])
const STATUSES = new Set(["stub", "draft", "complete"])

/**
 * Markup that only rendered under MkDocs Material or remark.js. Anything matching
 * here would reach a reader as literal garbage.
 */
const LEGACY = [
  [/^class:\s/, "remark slide property"],
  [/\.(lab|warning|footnote|small|red|checklist)\[/, "remark macro"],
  [/^!!!\s/, "MkDocs Material admonition"],
  [/^\?\?\?/, "MkDocs Material collapsible"],
  [/^===\s+"/, "MkDocs Material content tab"],
  [/--8<--/, "MkDocs snippet include"],
  [/@@(INCLUDE|LINK)\[/, "markmaker directive"],
  [/@@(GITREPO|SLIDES|CHAT|ZIP|HTML|TITLE|TOC)@@/, "markmaker manifest variable"],
  [
    /:(tools|warn|white_check_mark|construction|arrow_right|arrow_heading_down):/,
    "emoji shortcode",
  ],
  [/^\+\+.*\+\+$/, "MkDocs Material keyboard key"],
  [/\.drawio\)/, "unrendered drawio embed"],
  [/^\s*--\s*$/, "remark incremental reveal"],
  [/^\s*```(key|keys|wait|longwait|tmux|hide)\b.*```/, "container.training autopilot directive"],
]

/**
 * Identifiers from the original corporate source. These must never be published.
 * Checked against every file, not just markdown. The list is a local, gitignored
 * file (one per line: regex TAB flags TAB reason) so the public repo does not name
 * them. LEAK_PATTERNS=path overrides the location.
 */
const PATTERN_FILE =
  process.env.LEAK_PATTERNS ?? fileURLToPath(new URL("./leak-patterns.local.txt", import.meta.url))
const SECRETS = existsSync(PATTERN_FILE)
  ? readFileSync(PATTERN_FILE, "utf8")
      .split("\n")
      .filter(Boolean)
      .map((l) => {
        const [src, flags, what] = l.split("\t")
        return [new RegExp(src, flags), what]
      })
  : []

const errors = []
const warnings = []
if (!SECRETS.length) warnings.push(`no leak patterns file (${PATTERN_FILE}): secret scan skipped`)

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    if (entry === ".obsidian") continue
    const abs = join(dir, entry)
    if (statSync(abs).isDirectory()) walk(abs, out)
    else out.push(abs)
  }
  return out
}

/** Line-by-line view with fenced blocks flagged, and inline code removed. */
function analyse(text) {
  const lines = text.split("\n")
  const out = []
  let inFence = false
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i]
    const fenceMarkers = (raw.match(/```/g) ?? []).length
    const isToggle = /^\s*```/.test(raw) && fenceMarkers % 2 === 1
    if (isToggle) {
      out.push({ n: i + 1, raw, prose: "", inFence: true })
      inFence = !inFence
      continue
    }
    out.push({
      n: i + 1,
      raw,
      prose: inFence ? "" : raw.replace(/`[^`]*`/g, ""),
      inFence,
    })
  }
  return { lines: out, unbalanced: inFence }
}

function parseFrontmatter(text) {
  if (!text.startsWith("---\n")) return null
  const end = text.indexOf("\n---", 4)
  if (end === -1) return null
  const fm = {}
  for (const line of text.slice(4, end).split("\n")) {
    const kv = /^([a-z_]+):\s*(.*)$/.exec(line)
    if (kv) fm[kv[1]] = kv[2].trim()
  }
  return fm
}

const files = walk(ROOT)
const markdown = files.filter((f) => f.endsWith(".md"))
const notePaths = new Set(
  markdown.map((f) => relative(ROOT, f).replace(/\.md$/, "").split("\\").join("/")),
)
const noteBasenames = new Set([...notePaths].map((p) => p.split("/").pop()))

// --- secrets, across every file including binaries and SVGs -----------------
for (const file of files) {
  let text
  try {
    text = readFileSync(file, "utf8")
  } catch {
    continue
  }
  for (const [re, what] of SECRETS) {
    if (re.test(text)) errors.push(`${file}: leaked ${what} (${re})`)
  }
}

// --- per-note checks --------------------------------------------------------
for (const file of markdown) {
  const text = readFileSync(file, "utf8")
  const { lines, unbalanced } = analyse(text)

  if (unbalanced) errors.push(`${file}: unbalanced code fences`)

  const fm = parseFrontmatter(text)
  if (!fm) {
    errors.push(`${file}: missing or malformed frontmatter (--- must be line 1)`)
  } else {
    for (const key of REQUIRED) {
      if (!(key in fm)) errors.push(`${file}: frontmatter missing '${key}'`)
    }
    if (fm.type && !TYPES.has(fm.type)) {
      errors.push(`${file}: type '${fm.type}' not one of ${[...TYPES].join(", ")}`)
    }
    if (fm.status && !STATUSES.has(fm.status)) {
      errors.push(`${file}: status '${fm.status}' not one of ${[...STATUSES].join(", ")}`)
    }
    if (fm.source && !fm.license) {
      errors.push(`${file}: has 'source' but no 'license' — derived work needs both`)
    }
  }

  for (const { n, prose } of lines) {
    if (!prose.trim()) continue
    for (const [re, what] of LEGACY) {
      if (re.test(prose)) errors.push(`${file}:${n}: ${what} — ${prose.trim().slice(0, 70)}`)
    }
  }

  // --- images ---
  for (const { n, prose } of lines) {
    for (const m of prose.matchAll(/!\[[^\]]*\]\(([^)\s]+)\)/g)) {
      const target = m[1]
      if (/^https?:/.test(target)) continue
      const abs = resolve(dirname(file), target.split("#")[0])
      try {
        statSync(abs)
      } catch {
        errors.push(`${file}:${n}: image not found — ${target}`)
      }
    }
  }

  // --- wikilinks ---
  for (const { n, prose } of lines) {
    for (const m of prose.matchAll(/\[\[([^\]|#^]+)/g)) {
      const target = m[1].trim().replace(/\\$/, "")
      if (!target || target.startsWith("#")) continue
      if (notePaths.has(target)) continue
      if (noteBasenames.has(target.split("/").pop())) continue
      errors.push(`${file}:${n}: wikilink does not resolve — [[${target}]]`)
    }
  }
}

// --- vault-wide -------------------------------------------------------------
const tagCounts = new Map()
for (const file of markdown) {
  const fm = parseFrontmatter(readFileSync(file, "utf8"))
  if (!fm?.tags) continue
  for (const tag of fm.tags.replace(/^\[|\]$/g, "").split(",")) {
    const t = tag.trim()
    if (t) tagCounts.set(t, (tagCounts.get(t) ?? 0) + 1)
  }
}
for (const t of tagCounts.keys()) {
  if (TYPES.has(t)) warnings.push(`tag '${t}' duplicates a 'type' value — remove it from tags`)
}

// --- report -----------------------------------------------------------------
console.log(`linted ${markdown.length} notes, ${files.length} files, ${tagCounts.size} tags`)
for (const w of warnings) console.log(`  warning: ${w}`)
if (errors.length) {
  console.error(`\n${errors.length} error(s):`)
  for (const e of errors) console.error(`  ${e}`)
  process.exit(1)
}
console.log("content lint passed")
