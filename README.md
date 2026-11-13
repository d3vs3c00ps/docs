# Ops Notes

Sysadmin and platform engineering notes — Linux, servers, networking, containers,
Kubernetes, Ansible and the tooling around them.

Published at **<https://d3vs3c00ps.github.io/docs/>**.

An [Obsidian](https://obsidian.md) vault in `content/`, published with
[Quartz v5](https://quartz.jzhao.xyz).

## Layout

```
.
├── content/          the Obsidian vault — open Obsidian on this folder
├── quartz/           the Quartz v5 engine (vendored)
├── quartz.config.yaml
├── Taskfile.yml      `task` lists the tasks; namespaced tasks in taskfiles/
├── scripts/
│   ├── convert-slides.mjs   container.training decks -> Obsidian notes
│   ├── generate-mocs.mjs    per-folder index.md, from frontmatter
│   ├── lint-content.mjs     the regression net; runs in CI
│   └── test-notes.sh        runs tests/, one test per note
├── tests/            note tests, test environments, the runner image
├── CLAUDE.md         conventions, hard rules, sanitisation policy
├── MIGRATION.md      inventory and per-file mapping from the old MkDocs site
├── OBSIDIAN.md       vault setup: theme, plugins, graph, what git tracks
└── RUNBOOK.md        how to build, check and deploy
```

## Working on it

Tasks use [Task](https://taskfile.dev) (`brew install go-task`, or see its site).
Checks and note tests run in a container, so they need only Task and Docker, on
macOS arm64 or Linux amd64:

```bash
task                     # list the tasks
task check               # lint, MOCs, test coverage, shellcheck, prettier
task test                # run the notes' commands and check what they claim
task test NOTE=linux/cli/tar
```

The site needs Node 22+ on your machine, or the devcontainer:

```bash
task serve               # http://localhost:8080
```

How the note tests work: [tests/README.md](tests/README.md).

Full details in [RUNBOOK.md](RUNBOOK.md).

## Conventions

Every note carries typed frontmatter:

```yaml
---
title: rsyslog
description: Collecting, filtering and forwarding syslog messages
tags: [linux, logging, syslog]
type: reference        # concept | howto | reference | lab | moc
status: complete       # stub | draft | complete
---
```

`lint-content.mjs` enforces that, plus fence balance, link resolution, and the
absence of both legacy MkDocs/remark markup and any internal identifier from the
original corporate source — across every file type, not just markdown.

## Licence and attribution

- My own notes: [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- Most of `content/kubernetes/` is derived from
  [container.training](https://github.com/jpetazzo/container.training) by Jérôme
  Petazzoni and contributors, under CC BY 4.0, **with changes**. Each derived page
  records its `source`, `license` and `upstream_commit`.
- The vendored `quartz/` engine is MIT — see `LICENSE.txt`.

Full detail, including the diagrams contributed by third parties, is in
[content/attribution.md](content/attribution.md).

If something here is misattributed, or you are the author of material you would like
credited differently or removed, please open an issue.
