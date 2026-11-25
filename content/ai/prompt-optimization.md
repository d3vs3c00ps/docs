---
title: Prompt optimization
description: Prompting local models well — the anti-patterns that waste the most output, structural prompting, and where always-on rules belong
tags: [ai, llm, prompts, workflow]
type: howto
status: complete
---

# Prompt optimization

> [!note] Partly tested
> Only the `npx skills add` install is tested (skills CLI 1.9.0). The prompting advice
> is about how models behave and is not tested.

Local models need more deliberate prompting than cloud APIs. Smaller models are more
sensitive to prompt structure, ambiguity and length — a prompt that a frontier model
recovers from will simply fail here.

## prompt-master

[prompt-master](https://github.com/nidhinjs/prompt-master) is an agent
skill that writes optimised prompts for any AI tool: it analyses
your intent, picks a framework, and produces a clean prompt.

```bash
npx skills add nidhinjs/prompt-master
```

> [!tip] In a script
> The command asks which agent to install the skill for. Without a terminal it stops
> and installs nothing. Name the agent and skip the questions:
> `npx skills add nidhinjs/prompt-master --agent claude-code -y`.

Its pipeline, per request:

1. **Detect the target tool** and route accordingly.
2. **Extract nine dimensions of intent** — task, input, output, constraints, context,
   audience, memory, success criteria, examples.
3. **Ask clarifying questions**, at most three, and only if something critical is
   missing.
4. **Select a framework** from twelve templates, automatically.
5. **Run a token efficiency audit**, stripping words that do not change the output.
6. **Deliver one copyable block** with a strategy note.

It adapts per backend — asking which Ollama model is loaded, shortening structure for
smaller local models, matching the chat template and thinking mode for Qwen, or
adding file paths and a do-not-touch list for editor agents.

## The anti-patterns that cost most

Filtered to what actually matters for development work.

### Vague task verb

- **Bad** — "help me with this code"
- **Good** — "Refactor `getUserData()` to take a `context.Context` and handle nil
  returns"

Local models infer intent far less well than large ones. Name the action.

### No scope boundary

- **Bad** — "fix my app"
- **Good** — "Fix only the login validation in `internal/auth/handler.go`. Do not
  touch any other file."

Without a boundary the model proposes changes across the whole project, burning
context and producing something unusable.

### No stop condition

- **Bad** — "build the whole feature"
- **Good** — "Implement the HTTP handler. Stop after the handler and its tests. Do
  not implement the database layer."

This matters most in agent workflows where the model edits files on its own.

### Assumed prior knowledge

- **Bad** — "continue where we left off"
- **Good** — restate it:

```text
## Context
- Stack: Go 1.22, chi router, PostgreSQL
- Auth uses JWT in httpOnly cookies (decided last session)
- Table-driven tests exclusively
```

There is no memory across sessions. Everything relevant must be in the prompt.

### Missing output format

- **Bad** — "explain this concept"
- **Good** — "Explain context cancellation in Go. Three bullet points, each under 25
  words, with one code example."

Explicit format prevents rambling, which small models do readily.

### Two tasks in one prompt

- **Bad** — "explain **and** rewrite this function"
- **Good** — two prompts. Explain, then rewrite.

### No stack constraints

- **Bad** — "build a REST API"
- **Good** — "Build a REST API with Go 1.22, chi router, no ORM — use `database/sql`
  directly — against PostgreSQL 16"

Unconstrained, the model reaches for whatever dominated its training data.

## Tips specific to local models

**Keep prompts shorter.** Cloud models handle 2,000-word prompts fine. Local models,
especially under 27B, do better with focused 200–500 word prompts. Cut anything that
does not constrain the output.

**System prompts matter more.** With a smaller model the system prompt has outsized
influence. Set a persistent one through an [[ai/ollama|Ollama Modelfile]] or
`llama-server --chat-template`:

```text
You are a senior Go developer. You write idiomatic, well-tested code using the
standard library. You follow Effective Go conventions. You always take
context.Context as the first parameter and wrap errors with fmt.Errorf.
```

**Use explicit structure.** Local models follow structured prompts far better than
conversational ones:

```text
## Task
Refactor the handler to use middleware for auth.

## Files
- internal/api/handler.go   (main changes here)
- internal/middleware/auth.go   (create this)

## Constraints
- Use the chi middleware interface
- Preserve the existing API contract
- Table-driven tests required

## Output
Return both files with full content.
```

**Chain-of-thought, conditionally.** "Think step by step" helps models under about
30B without a built-in thinking mode.

> [!warning] Do not add chain-of-thought to a thinking model
> Models with a native thinking mode reason internally already. Adding an explicit
> "think step by step" instruction measurably **degrades** their output — it competes
> with the mechanism rather than reinforcing it. See [[ai/models]] for which models
> have it.

**Low temperature for code** — 0.1 to 0.3. Higher values increase both creativity and
hallucinated APIs. The exception is again thinking models, which want ~0.6; see
[[ai/llama-cpp]].

## The memory block pattern

For multi-session work, keep a block you paste into each new conversation:

```markdown
## Memory (carry forward)
- Project: ingestion service
- Stack: Go 1.22, chi, PostgreSQL 16, Docker
- Auth: JWT in httpOnly cookies, RS256 signing
- Testing: table-driven, testify/assert only
- Decided: no ORM, no Redis — session state in the database
- Last session: implemented /api/v1/ingest, still needs tests
```

This stops the model contradicting decisions already made, which is the largest
single source of wasted re-prompting on a long-running project.

## Where always-on rules belong

To enforce response-quality rules on **every** interaction — be concise, no
sycophancy, verified answers, security-aware — use an always-on mechanism, not a
skill.

> [!important] Skills load conditionally, so they cannot carry defaults
> The agent reads only a skill's `description` and decides whether it is relevant to
> the current task. That is right for task-specific guidance, and unreliable for
> global behaviour: a generic "be concise" skill will often not be judged relevant
> and gets silently skipped. Skills do progressive disclosure, not defaults.

| Rule | Type | Where it belongs |
| --- | --- | --- |
| No sycophancy | Always-on | `AGENTS.md` or the system prompt |
| Stay concise | Always-on | `AGENTS.md` or the system prompt |
| Verified, no invention | Always-on | `AGENTS.md` or the system prompt |
| Security-aware | Always-on | `AGENTS.md` or the system prompt |
| Coding conventions | Conditional | A path-scoped skill, or `AGENTS.md` |

`AGENTS.md` is read automatically at startup by most agent tools — [[ai/pi]] loads it
from `~/.pi/agent/`, from parent directories and from the current directory. Put a
global one at `~/.pi/agent/AGENTS.md`, or commit one to a repository root to share it.

```markdown
# AGENTS.md

## Response quality
- Be direct and truthful. Do not agree just to be agreeable, and do not soften
  correct-but-unwelcome answers. If I am wrong, say so and explain why.
- Be concise. Lead with the answer, then justify. No filler, no restating the
  question, no summary of what you just did unless asked.
- Only state what you can verify. Distinguish fact from inference. If unsure, say
  so and say how to check. Never invent APIs, flags, file paths or citations.

## Security
- Treat all input as untrusted. Flag injection, secrets in code, unsafe defaults
  and missing authorization or validation as you go.
- Never write secrets to disk or logs. Prefer least-privilege examples.

## Coding
- Follow the language's idioms and the conventions already in the repository.
- Prefer the standard library; justify third-party dependencies.
- Include error handling and tests. Do not leave TODOs in place of logic.
```

For raw inference without an agent harness, put the same rules in the system prompt
instead — via an Ollama Modelfile `SYSTEM` block, `llama-server --chat-template`, or
Pi's `SYSTEM.md`. Keep it shorter for models under 27B.

The coding block can move into a path-scoped skill so it only loads for code. Keep it
in `AGENTS.md` if you prefer one file everywhere; split it out if it grows large and
you would rather not carry it in context for non-coding work.

## Where to go next

- [[dev/agent-skills]] — installing and writing skills
- [[ai/models]] — which models handle prompts best
- [[ai/llama-cpp]] — the sampling parameters behind all of this

<!-- uplink -->
Part of [[ai/index|Local LLMs]].
