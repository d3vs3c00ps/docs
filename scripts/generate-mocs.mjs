#!/usr/bin/env node
/**
 * generate-mocs.mjs
 *
 * Two passes, both driven by frontmatter so neither can drift as notes are added,
 * renamed or moved between folders:
 *
 *   1. The map-of-content `index.md` for each folder — links down to the notes and
 *      subfolders it contains, and up to its parent MOC.
 *   2. An `<!-- uplink -->` footer on every other note, linking up to the MOC of the
 *      folder it sits in.
 *
 * Pass 2 exists because links used to run only downhill: every MOC listed its notes
 * and no note pointed back, so all 53 of them sat at in-degree 1 and the folder
 * structure was invisible in the graph view. Only the *immediate* parent is linked —
 * a full breadcrumb chain would give `kubernetes/index` an in-degree of 158 and just
 * move the lump somewhere else.
 *
 * The framing prose for each section is held here in INTROS — the part a generated
 * listing cannot supply. Existing index.md files that were hand-written are left
 * alone unless they carry the generated marker, so a MOC can always be taken over by
 * hand; their notes still get uplinks.
 *
 * Usage: node scripts/generate-mocs.mjs [--check]
 */

import { readFileSync, writeFileSync, readdirSync, statSync, existsSync } from "node:fs"
import { join, relative } from "node:path"

const ROOT = "content"
const MARKER = "<!-- generated-moc -->"
const UPLINK = "<!-- uplink -->"

/**
 * Per-folder framing. `title` and `blurb` are required for a folder to get a MOC;
 * anything not listed here is left without one.
 */
const INTROS = {
  linux: {
    title: "Linux",
    blurb:
      "System administration notes: the shell, the CLI tools worth knowing well, boot and init, storage, logging and the distribution-specific parts.",
  },
  "linux/cli": {
    title: "Command line tools",
    blurb:
      "Individual tools, each documented to the depth I actually needed rather than to the depth of its man page.",
  },
  "linux/shell": {
    title: "Shells",
    blurb: "Bash and Zsh syntax, and terminal multiplexing.",
  },
  "linux/boot": {
    title: "Boot and init",
    blurb: "What happens between power-on and a login prompt, and how to inspect it.",
  },
  "linux/storage": {
    title: "Storage",
    blurb: "Volumes, partition layouts, swap and filesystem benchmarking.",
  },
  "linux/logging": {
    title: "Logging",
    blurb:
      "The syslog protocol and the two implementations, including building a reliable forwarding chain.",
  },
  "linux/networking": {
    title: "Linux networking",
    blurb:
      "Network namespaces and the virtual interface types that container runtimes are built on.",
  },
  "linux/distributions": {
    title: "Distributions",
    blurb: "Package management and hardening, per distribution family.",
  },
  "linux/distributions/nixos": {
    title: "NixOS",
    blurb:
      "A distribution built from a declarative configuration by a purely functional package manager — atomic upgrades, real rollback, and an honest account of what you give up for them.",
  },
  "linux/desktop": {
    title: "Desktop",
    blurb:
      "The graphical side of a Linux workstation: compositors, window managers and the tools around them.",
  },
  "linux/desktop/sway": {
    title: "Sway",
    blurb:
      "A tiling Wayland compositor that reads an i3 configuration — the model, making changes, the tools a bare compositor lacks, theming, and running it on NixOS.",
  },
  labs: {
    title: "Labs",
    blurb: "Infrastructure built end to end on a laptop, step by step, including what went wrong.",
  },
  "labs/nixos-homelab": {
    title: "NixOS home lab",
    blurb:
      "NixOS VMs on a Mac with vfkit, all declared in one flake: Gitea, Woodpecker CI and Kubernetes, installed with nixos-anywhere.",
  },
  servers: {
    title: "Servers",
    blurb:
      "Configuring and operating the daemons: web servers, databases, directory and time services. The TLS they all terminate is in [[security/cryptography/index|Cryptography]].",
  },
  observability: {
    title: "Observability",
    blurb:
      "Metrics and dashboards for servers and services: Prometheus to collect and alert, Grafana to look. For metrics inside a cluster, see [[kubernetes/observability/metrology/index|Kubernetes metrology]].",
  },
  "observability/prometheus": {
    title: "Prometheus",
    blurb: "Install, configure, query, alert, back up and debug a standalone Prometheus.",
  },
  "observability/grafana": {
    title: "Grafana",
    blurb:
      "Install Grafana, provision data sources and dashboards as code, back it up, and debug it.",
  },
  networking: {
    title: "Networking",
    blurb: "Packet filtering with Netfilter, through both its front-ends.",
  },
  containers: {
    title: "Containers",
    blurb:
      "What a container actually is, the engines that run them, and how to do it without giving away the host.",
  },
  "containers/containerd": {
    title: "containerd",
    blurb:
      "The runtime underneath both Docker and Kubernetes — configuring it, driving it, and debugging a node when it misbehaves.",
  },
  automation: {
    title: "Automation",
    blurb: "Configuration management: Ansible in depth, and running it centrally.",
  },
  dev: {
    title: "Development",
    blurb:
      "Version control, markup formats, specification-by-example, and the languages I actually write tooling in.",
  },
  "dev/go": {
    title: "Go for sysadmins",
    blurb:
      'A course from "I run servers" to shipping idiomatic Go, with every concept anchored to something you already do on a machine.',
  },
  "dev/taskfile": {
    title: "Task (Taskfile)",
    blurb:
      "Task, a single-binary task runner configured in YAML, as a replacement for Make: from the first Taskfile to includes, caching and backup tasks.",
  },
  "dev/go/foundations": {
    title: "Foundations",
    blurb: "Installing Go, a first program, how projects are laid out, and the toolchain.",
  },
  "dev/go/core-language": {
    title: "Core language",
    blurb:
      "Variables, control flow, functions, and the four data structures everything else is built from.",
  },
  "dev/go/go-isms": {
    title: "Go-isms",
    blurb:
      "The parts that are unlike other languages: errors as values, defer, and the concurrency model.",
  },
  "dev/go/packages-and-modules": {
    title: "Packages and modules",
    blurb:
      "Dependency management, visibility, package boundaries, and what the standard library already gives you.",
  },
  "dev/go/sysadmin": {
    title: "Sysadmin use cases",
    blurb:
      "Where Go starts replacing shell scripts: files, processes, configuration, logging, HTTP, SSH and sockets.",
  },
  "dev/go/web-and-apis": {
    title: "Web and APIs",
    blurb: "HTTP servers, routing, a layered REST API, and command-line tools.",
  },
  "dev/go/projects": {
    title: "Mini projects",
    blurb:
      "Real tools built end to end. The fleet health checker is the capstone that ties every layer together.",
  },
  "dev/go/testing": {
    title: "Testing",
    blurb: "Unit tests, benchmarks, and the table-driven pattern that is the Go idiom.",
  },
  "dev/go/appendix": {
    title: "Appendix",
    blurb: "Gotchas, conventions, vocabulary and further reading.",
  },
  storage: {
    title: "Storage",
    blurb: "SAN and array concepts, below the operating system.",
  },
  virtualization: {
    title: "Virtualisation",
    blurb:
      "KVM and the stack around it, running VMs on Kubernetes with KubeVirt, and VMware from PowerCLI.",
  },
  "virtualization/kvm": {
    title: "KVM and QEMU",
    blurb:
      "Turning Linux into a hypervisor: the kernel module, the emulation layer, libvirt, and the tuning that separates adequate from fast.",
  },
  "virtualization/kubevirt": {
    title: "KubeVirt",
    blurb:
      "Virtual machines as Kubernetes resources — one control plane for VMs and containers, and the storage and networking choices that decide whether they can migrate.",
  },
  windows: {
    title: "Windows",
    blurb: "Licensing, links and the component store.",
  },
  security: {
    title: "Security",
    blurb:
      "Hardening, supply chain and vulnerability management — the controls that make a class of problem impossible, and the ones that only tell you it happened.",
  },
  "security/boot-integrity": {
    title: "Boot integrity",
    blurb:
      "The chain from firmware to an unlocked disk: Secure Boot measures it, the TPM records it, and LUKS releases a key only when it still matches.",
  },
  "security/supply-chain": {
    title: "Supply chain",
    blurb:
      "Knowing what is in an artifact, who built it, and whether that still matters — SBOMs, signatures, provenance and VEX.",
  },
  "security/offensive": {
    title: "Offensive tooling",
    blurb:
      "Scanners and proxies, framed for defensive use: finding what you exposed by accident, and validating that your own controls work. Only ever against systems you are authorised to test.",
  },
  "security/cryptography": {
    title: "Cryptography, PKI and TLS",
    blurb:
      "The primitives, the identity layer built on them, and the protocol that consumes both. Start at [[security/cryptography/foundations|Cryptography foundations]] and work outwards.",
  },
  "security/cryptography/openssl": {
    title: "OpenSSL",
    blurb:
      "The tool rather than the concepts — how the CLI is put together, the invocations worth keeping, signing data, and decoding the error messages.",
  },
  kubernetes: {
    title: "Kubernetes",
    blurb:
      "The largest section here. Most of it is derived from jpetazzo's container.training course under CC BY 4.0 — see [[attribution]] — restructured from slide decks into pages and grouped by subject rather than by the running order of any particular workshop. `my-notes/` is my own material.",
  },
  "kubernetes/concepts": {
    title: "Concepts",
    blurb:
      "What Kubernetes is, how its pieces fit together, and the declarative model everything rests on. Start here.",
  },
  "kubernetes/cluster-setup": {
    title: "Cluster setup",
    blurb:
      "Building clusters: from first principles, with installers, as a managed service, and locally. Plus upgrades and backups.",
  },
  "kubernetes/workloads": {
    title: "Workloads",
    blurb:
      "Running things: the kubectl verbs, deployments and rollouts, jobs, and how scheduling decisions are influenced.",
  },
  "kubernetes/networking": {
    title: "Networking",
    blurb: "The pod network, Services, Ingress, and restricting traffic with network policies.",
  },
  "kubernetes/networking/cilium": {
    title: "Cilium",
    blurb:
      "The eBPF CNI in depth — how the datapath and identity model work, installing it on Helm or RKE2, Hubble, WireGuard encryption, policy, and what to run when it will not come up.",
  },
  "kubernetes/storage": {
    title: "Storage",
    blurb: "Volumes, persistent claims, storage classes and stateful workloads.",
  },
  "kubernetes/configuration": {
    title: "Configuration and secrets",
    blurb: "Getting configuration and secrets into pods, and the tools for templating manifests.",
  },
  "kubernetes/packaging": {
    title: "Packaging with Helm",
    blurb: "Charts: using them, writing them, and managing their values and dependencies.",
  },
  "kubernetes/security": {
    title: "Security",
    blurb:
      "Authentication, authorisation, securing the control plane, restricting what pods may do, and policy enforcement.",
  },
  "kubernetes/observability": {
    title: "Observability and scaling",
    blurb: "Logs, metrics, resource limits and the autoscalers that act on them.",
  },
  "kubernetes/observability/metrology": {
    title: "Kubernetes metrology",
    blurb:
      "Measuring a cluster: metrics-server, kube-state-metrics and kube-prometheus-stack, the PromQL that matters, alerts, backups and troubleshooting.",
  },
  "kubernetes/extending": {
    title: "Extending Kubernetes",
    blurb: "Custom resources, operators, and the API machinery underneath them.",
  },
  "kubernetes/cicd-gitops": {
    title: "CI/CD and GitOps",
    blurb: "Building images, and getting them deployed from a Git repository.",
  },
  "kubernetes/tooling": {
    title: "Tooling",
    blurb: "Interfaces for working with a cluster day to day.",
  },
  "kubernetes/mlops": {
    title: "MLOps",
    blurb: "Serving models on Kubernetes, and the scaling problems that come with them.",
  },
  "kubernetes/my-notes": {
    title: "My own Kubernetes notes",
    blurb:
      "Original material rather than derived from the course: a hard-way cluster build, and notes on the parts I wanted to understand more deeply than the slides went.",
  },
}

const TYPE_LABEL = {
  concept: "concept",
  howto: "how-to",
  reference: "reference",
  lab: "lab",
  moc: "map",
}

function parseFrontmatter(text) {
  const m = /^---\n([\s\S]*?)\n---/.exec(text)
  if (!m) return null
  const fm = {}
  for (const line of m[1].split("\n")) {
    const kv = /^([a-z_]+):\s*(.*)$/.exec(line)
    if (kv) fm[kv[1]] = kv[2].replace(/^["']|["']$/g, "")
  }
  return fm
}

function walk(dir) {
  const folders = []
  for (const entry of readdirSync(dir)) {
    if (entry.startsWith(".") || entry.startsWith("_")) continue
    const abs = join(dir, entry)
    if (statSync(abs).isDirectory()) folders.push(abs, ...walk(abs))
  }
  return folders
}

/**
 * The display title of a folder's MOC. Prefers INTROS so that renaming a section
 * here propagates in one run rather than two; falls back to the index.md on disk,
 * which is how the four hand-written MOCs (the root, ai, dev/go, automation/ansible)
 * are picked up.
 */
function mocTitle(rel) {
  if (INTROS[rel]) return INTROS[rel].title
  const abs = rel ? join(ROOT, rel, "index.md") : join(ROOT, "index.md")
  if (!existsSync(abs)) return null
  return parseFrontmatter(readFileSync(abs, "utf8"))?.title ?? null
}

/**
 * "Part of [[…]]." pointing at the MOC one level up, or null at the vault root.
 * Returns null rather than guessing if the parent has no index.md, so a folder that
 * has not been given a MOC yet does not produce a dangling wikilink.
 */
function parentLink(rel) {
  if (!rel) return null
  const parent = rel.includes("/") ? rel.slice(0, rel.lastIndexOf("/")) : ""
  const title = mocTitle(parent)
  if (!title) return null
  const target = parent ? `${parent}/index` : "index"
  return `Part of [[${target}|${title}]].`
}

/**
 * Every note in a folder that should carry an uplink footer: markdown, not the MOC
 * itself, and not hidden or an attachment — the same skips `walk()` applies.
 */
function notesNeedingUplink(folder) {
  return readdirSync(folder)
    .filter((e) => !e.startsWith(".") && !e.startsWith("_"))
    .filter((e) => e.endsWith(".md") && e !== "index.md")
    .filter((e) => !statSync(join(folder, e)).isDirectory())
    .sort()
}

/**
 * Replace everything from the UPLINK marker to end of file, so the pass is
 * idempotent and a moved note is corrected rather than accumulating footers.
 */
function withUplink(text, link) {
  const i = text.indexOf(UPLINK)
  const body = (i === -1 ? text : text.slice(0, i)).replace(/\s+$/, "")
  return `${body}\n\n${UPLINK}\n${link}\n`
}

function build(folder) {
  const rel = relative(ROOT, folder).split("\\").join("/")
  const intro = INTROS[rel]
  if (!intro) return null

  const notes = []
  const subfolders = []

  for (const entry of readdirSync(folder).sort()) {
    if (entry.startsWith(".") || entry.startsWith("_")) continue
    const abs = join(folder, entry)
    if (statSync(abs).isDirectory()) {
      const sub = `${rel}/${entry}`
      if (INTROS[sub]) subfolders.push({ path: sub, title: INTROS[sub].title })
      continue
    }
    if (!entry.endsWith(".md") || entry === "index.md") continue
    const fm = parseFrontmatter(readFileSync(abs, "utf8"))
    if (!fm) continue
    if (fm.draft === "true") continue
    notes.push({
      path: `${rel}/${entry.replace(/\.md$/, "")}`,
      title: fm.title ?? entry,
      description: fm.description ?? "",
      type: fm.type ?? "",
      derived: Boolean(fm.source),
    })
  }

  const out = []
  out.push("---")
  out.push(`title: ${JSON.stringify(intro.title)}`)
  out.push(
    `description: ${JSON.stringify(intro.blurb.replace(/\[\[[^|\]]*\|?([^\]]*)\]\]/g, "$1").replace(/`/g, ""))}`,
  )
  out.push(`tags: [${rel.split("/").reverse()[0]}]`)
  out.push("type: moc")
  out.push("status: complete")
  out.push("---")
  out.push("")
  out.push(MARKER)
  out.push("")
  out.push(`# ${intro.title}`)
  out.push("")
  out.push(intro.blurb)
  out.push("")

  if (subfolders.length) {
    out.push("## Sections")
    out.push("")
    for (const s of subfolders) out.push(`- [[${s.path}/index|${s.title}]]`)
    out.push("")
  }

  if (notes.length) {
    if (subfolders.length) out.push("## Notes in this section")
    out.push("")
    out.push("| Note | | What it covers |")
    out.push("| --- | --- | --- |")
    for (const n of notes) {
      const label = TYPE_LABEL[n.type] ?? n.type
      out.push(`| [[${n.path}\\|${n.title}]] | ${label} | ${n.description} |`)
    }
    out.push("")
  }

  if (notes.some((n) => n.derived)) {
    out.push("> [!info] Derived from container.training")
    out.push("> Pages in this section marked with a `source` in their frontmatter are")
    out.push("> derived from [container.training](https://github.com/jpetazzo/container.training)")
    out.push("> under CC BY 4.0, with changes. See [[attribution]].")
    out.push("")
  }

  const parent = parentLink(rel)
  if (parent) {
    out.push(parent)
    out.push("")
  }

  return { path: join(folder, "index.md"), text: out.join("\n") }
}

const check = process.argv.includes("--check")
const folders = [ROOT, ...walk(ROOT)]
let written = 0
let skipped = 0
let linked = 0

// Pass 1 — the MOC index pages.
for (const folder of folders) {
  const built = build(folder)
  if (!built) continue

  if (existsSync(built.path)) {
    const existing = readFileSync(built.path, "utf8")
    if (!existing.includes(MARKER)) {
      skipped++
      continue // hand-written, leave it alone
    }
    if (existing === built.text) continue
  }
  if (check) {
    console.error(`out of date: ${built.path}`)
    process.exitCode = 1
    continue
  }
  writeFileSync(built.path, built.text)
  written++
}

// Pass 2 — the uplink footer on every other note. Runs over all folders, including
// those whose MOC is hand-written, and including any folder INTROS does not cover:
// what matters is that the note's own folder has an index.md to point at.
for (const folder of folders) {
  const rel = relative(ROOT, folder).split("\\").join("/")
  const title = mocTitle(rel)
  if (!title) continue // no MOC for this folder — nothing to point at
  const link = `Part of [[${rel ? `${rel}/index` : "index"}|${title}]].`

  for (const entry of notesNeedingUplink(folder)) {
    const abs = join(folder, entry)
    const existing = readFileSync(abs, "utf8")
    const updated = withUplink(existing, link)
    if (existing === updated) continue
    if (check) {
      console.error(`uplink out of date: ${abs}`)
      process.exitCode = 1
      continue
    }
    writeFileSync(abs, updated)
    linked++
  }
}

console.log(check ? "checked MOCs and uplinks" : `wrote ${written} MOC index pages`)
if (!check && linked) console.log(`  updated ${linked} uplink footer(s)`)
if (skipped) console.log(`  left ${skipped} hand-written index page(s) alone`)
