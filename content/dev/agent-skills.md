---
title: Agent skills
description: Portable SKILL.md instruction sets for AI agents — how they load, where they live, writing your own, and why the description field decides everything
tags: [dev, ai, tooling, agents, workflow]
type: howto
status: complete
---

# Agent skills

Agent skills are portable, version-controlled instruction sets that teach AI agents
how to perform domain-specific tasks. They are `SKILL.md` files — markdown with YAML
frontmatter — that any compatible agent can discover and follow.

[skills.sh](https://www.skills.sh) is the central registry for public skills.

## How they work

1. You install a skill into a project or global skills directory.
2. The agent reads the skill's **`description`** and decides whether it applies to
   the current task.
3. If it does, the agent follows the instructions in the markdown body.

Skills are **not code**. They are structured natural language, interpreted the same
way the agent interprets your messages, just with more consistency.

> [!important] Skills load conditionally, so they cannot express defaults
> Because the agent only reads the `description` to judge relevance, a skill
> containing global rules — "be concise", "no sycophancy" — will often not be
> considered relevant and gets silently skipped. Always-on behaviour belongs in
> `AGENTS.md` or the system prompt; see [[ai/prompt-optimization]]. Skills do
> progressive disclosure, not defaults.

## Installing

```bash
npx skills add nidhinjs/prompt-master
npx skills add mattpocock/skills --skill tdd
npx skills add anthropics/skills --skill frontend-design
```

A repository can hold many skills: `--skill` picks one, and `--list` shows them all.
The command asks which agent to install for; in a script, pass `--agent <name> -y`.

### Where skills are installed

The CLI puts a skill where the chosen agent reads skills:

| Agent | Project directory |
| --- | --- |
| Cursor, Codex, and other agents that read the shared directory | `.agents/skills/` |
| Claude Code | `.claude/skills/` |

`-g` installs for your user, in every project, instead of the current one. Prefer
`.agents/skills/`, committed to Git, when the agents you use read it.

> [!warning] A skill is instructions an agent will act on
> Installing one from a registry means an agent may follow its contents against your
> codebase, with your credentials. Read a skill before adding it — particularly any
> `scripts/` it ships, which are executable. The trust model is closer to a shell
> plugin than to a documentation file.

## Structure

A skill is a directory containing `SKILL.md`:

```text
.agents/skills/go-service/
├── SKILL.md
├── scripts/           # optional: executable helpers
├── references/        # optional: docs the agent should read
└── assets/            # optional: templates, configs
```

A minimal one:

```markdown
---
name: go-service
description: "Build and test Go services following our conventions"
---

## Instructions

When creating a new Go service:
1. Use the standard project layout: cmd/, internal/, pkg/
2. Always use table-driven tests
3. Run `make lint` before committing
4. Use context.Context as the first parameter of every exported function
5. Wrap errors with fmt.Errorf("operation: %w", err)
```

### Frontmatter

The [Agent Skills specification](https://agentskills.io/specification) defines:

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | Yes | Lowercase letters, digits and hyphens, at most 64 characters, the same as the skill's directory name. Many agents also let you call a skill as `/name` |
| `description` | Yes | At most 1024 characters. **The only thing the agent reads to decide relevance** |
| `license` | No | A licence name, or a bundled licence file |
| `compatibility` | No | What the skill needs: a product, system packages, network access |
| `metadata` | No | Free key-value pairs |
| `allowed-tools` | No | Tools the skill may use without asking (experimental) |

### Scoping

The specification has no field that limits a skill to some files: the description
does the scoping. Say in it when the skill applies — "Use when writing pytest tests".
Some agents add their own fields for file patterns; check your agent's documentation
before you rely on one, because other agents ignore it.

## Skills worth having

| Skill | Install | What it does |
| --- | --- | --- |
| **prompt-master** | `npx skills add nidhinjs/prompt-master` | Writes optimised prompts — 12 templates, 35 anti-patterns, per-tool profiles. See [[ai/prompt-optimization]] |
| **tdd** | `npx skills add mattpocock/skills --skill tdd` | Drives a red-green-refactor cycle |
| **diagnosing-bugs** | `npx skills add mattpocock/skills --skill diagnosing-bugs` | Systematic debugging — investigate before fixing |
| **improve-codebase-architecture** | `npx skills add mattpocock/skills --skill improve-codebase-architecture` | Reviews and suggests architectural changes |

### superpowers

[superpowers](https://github.com/obra/superpowers) is a larger collection rather than
a single skill — a curated set covering planning, debugging, code review and writing,
installed together.

It is worth looking at for two reasons beyond the skills themselves: it is a good
worked example of how to structure a **collection**, with shared conventions across
many `SKILL.md` files, and reading its descriptions is an efficient way to see what
well-written trigger text looks like.

> [!note] Install a collection deliberately, not wholesale
> Adding dozens of skills at once means dozens of descriptions competing for
> relevance on every request, and a much larger surface to have read and understood.
> Take the two or three that match work you actually do.

## Writing your own

### Go conventions

`.agents/skills/platform-go/SKILL.md`:

```markdown
---
name: platform-go
description: "Write Go code following our platform conventions. Use when creating, modifying, or reviewing Go code."
---

## Project structure

- `cmd/<service>/main.go` — entrypoints
- `internal/` — private packages
- `pkg/` — shared libraries, only if reused across repositories

## Code style

- `context.Context` as the first parameter of every exported function
- Wrap errors: `fmt.Errorf("operation failed: %w", err)`
- No naked returns
- Prefer the standard library; justify any third-party dependency

## Testing

- Table-driven tests for all non-trivial functions
- Test file beside the source: `foo.go` → `foo_test.go`
- Run `make test` to verify

## Linting

- Run `golangci-lint run ./...` before any commit
- Fix every finding rather than suppressing it
```

### Python conventions

`.agents/skills/platform-python/SKILL.md`:

```markdown
---
name: platform-python
description: "Write Python code following our conventions. Use when creating or modifying Python scripts and services."
---

## Style

- Python 3.11+
- Type hints on all function signatures
- Use pathlib, not os.path
- f-strings over format() or %

## Testing

- pytest with fixtures
- Parametrize for multiple input cases
- Run `make pytest` to verify

## Dependencies

- Pin exact versions
- Use a virtualenv, not the system Python
```

## Maintaining them

**Version control.** Commit `.agents/skills/` so everyone shares the same set and
changes go through normal review.

**Review periodically.** Skills drift as conventions change. Ask whether the
instructions are still accurate, whether new patterns have been adopted, and whether
anything is unused — and delete what is.

### Writing a good description

The description is the single most important field, because the agent uses it and
nothing else to decide relevance.

Good descriptions:

- Start with a verb — "Build…", "Write…", "Review…"
- Say when to trigger — "Use when creating Go services"
- Include the keywords that will appear in a matching request

Bad descriptions:

- "Helper skill" — too vague to match anything
- "Does stuff with code" — no trigger keywords
- A full paragraph — dilutes the signal

### Testing a skill

1. Open a fresh agent conversation.
2. Ask for something the skill covers.
3. Check whether the agent actually follows it.
4. Refine the description if it did not activate, or the body if it deviated.

Step 3 is the one people skip. A skill that never activates is indistinguishable from
one that does not exist.

## Where to go next

- [[ai/prompt-optimization]] — where always-on rules belong instead
- [[ai/mcp]] — the other extension mechanism, for tools rather than instructions
- [[ai/pi]] — an agent that loads these

## Further reading

- [skills.sh](https://www.skills.sh) — registry and leaderboard
- [skills.sh CLI docs](https://www.skills.sh/docs/cli)
- [Cursor skills documentation](https://cursor.com/docs/skills)

<!-- uplink -->
Part of [[dev/index|Development]].
