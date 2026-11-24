---
title: Pi
description: A minimal terminal coding agent — connecting it to local models, the compat block that makes local backends work, and session trees
tags: [ai, llm, agents, cli, tooling]
type: howto
status: complete
---

# Pi

> [!note] Partly tested
> Tested with Pi 1.6.0 in print mode against a fake OpenAI server: the npm install,
> `models.json` with and without `compat`, `settings.json`, `AGENTS.md` loading and
> `--mode json`. The TUI keys and commands, and the Ollama provider, are not tested.

[Pi](https://pi.dev) is a minimal terminal coding agent. It is closer to Claude Code
or Aider than to a chat UI: it runs in the terminal, works on your codebase, and is
built to be extended and adapted to your workflow rather than the other way round.

It connects to 15+ providers — Anthropic, OpenAI, Ollama, Mistral, Groq, OpenRouter
and others — and can be pointed at any local model served by [[ai/ollama]] or an
OpenAI-compatible endpoint. Sessions are stored as branching trees.

## Installation

```bash
curl -fsSL https://pi.dev/install.sh | sh

# or via a package manager
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
```

Then run `pi`. It needs Node.js 22.19 or later. The install script installs the same npm
package, and offers to install Node and npm when they are missing.

> [!note] `--ignore-scripts` is deliberate
> It prevents npm lifecycle scripts from executing during install, which is a
> sensible default for any globally installed tool. The same caution applies to the
> `curl | sh` route — read the script before piping it to a shell.

## Connecting a local model

### Ollama

Supported natively:

```bash
ollama serve
ollama pull qwen3.6:27b
```

Then, inside Pi:

```text
/model ollama/qwen3.6:27b
```

### llama.cpp, MLX or llama-swap

For OpenAI-compatible backends, create `~/.pi/agent/models.json`:

```bash
mkdir -p ~/.pi/agent
```

```json
{
  "providers": {
    "llama-swap": {
      "baseUrl": "http://localhost:8080/v1",
      "api": "openai-completions",
      "apiKey": "local",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false,
        "supportsUsageInStreaming": false,
        "maxTokensField": "max_tokens"
      },
      "models": [
        { "id": "qwen-27b" },
        { "id": "qwen-9b" },
        { "id": "gemma4-12b" },
        { "id": "gemma4-26b" }
      ]
    }
  }
}
```

> [!important] The `compat` block is not optional for local backends
> `llama-server` and `mlx_lm.server` do not support the `developer` system role,
> `reasoning_effort`, or usage statistics in streaming responses — all of which Pi
> sends by default. Without this block you get outright errors or garbled output, and
> the cause is not obvious from the symptoms.

Model `id` values must match exactly what the backend reports at `/v1/models`. After
saving, launch Pi and switch models with `Ctrl+L`.

To set a default and restrict `Ctrl+P` cycling to local models only, add
`~/.pi/agent/settings.json`:

```json
{
  "defaultProvider": "llama-swap",
  "defaultModel": "qwen-27b",
  "enabledModels": ["qwen-27b", "qwen-9b", "gemma4-12b", "gemma4-26b"]
}
```

`enabledModels` limits `Ctrl+P` cycling to those IDs. The full `Ctrl+L` picker still
shows every provider, but Pi starts on a local model and cycles only through local
ones.

## Concepts

### AGENTS.md

Pi loads project instructions at startup from, in order:

1. `~/.pi/agent/` — global defaults
2. Parent directories of the current path
3. The current directory

This is the same `AGENTS.md` convention other agent tools use, so Pi picks up files
you already have when you `cd` into a project.

### Skills

Capability packages — instructions plus tools — loaded on demand. Pi uses progressive
disclosure, so a skill does not enter the context window until it is needed, which
keeps prompts lean and cache-friendly. See agent-skills for the format.

### Sessions as trees

Sessions branch rather than running linearly. `/tree` navigates back to any earlier
point and continues from there, preserving each branch. `/share` uploads a session to
a GitHub gist and returns a URL.

> [!warning] `/share` publishes the session
> It uploads your conversation — including whatever source code was in context — to a
> GitHub gist. Check what the session contains before sharing one from a private
> repository.

### Modes

| Mode | Usage |
| --- | --- |
| Interactive | Full TUI, the default |
| Print / JSON | `pi -p "query"` for scripts; `--mode json` for event streams |
| RPC | JSON over stdin/stdout, for non-Node integrations |
| SDK | Embedding Pi in your own applications |

## Commands

| Command | What it does |
| --- | --- |
| `/model`, `Ctrl+L` | Switch model mid-session |
| `Ctrl+P` | Cycle favourite models |
| `/tree` | Navigate the session tree |
| `/share` | Export the session to a GitHub gist |
| `/export` | Export the session to HTML |
| `Enter` while running | Steer — delivered after the current tool call |
| `Alt+Enter` while running | Queue a follow-up until the agent finishes |

## What Pi deliberately leaves out

The core stays minimal; these are left to extensions or packages:

- **No built-in MCP** — build an extension, or expose CLI tools as skills. See
  [[ai/mcp]].
- **No sub-agents** — use tmux, or build them.
- **No plan mode** — write plans to files.
- **No permission prompts** — run it in a container, or build your own.

That last one matters: Pi will act without asking. Run it against a clean working
tree, or in a container, so that `git diff` is a complete record of what it changed.

Packages are distributed via npm or git: `pi install npm:@foo/pi-tools`.

## Updating

```bash
curl -fsSL https://pi.dev/install.sh | sh
# or
npm update -g @earendil-works/pi-coding-agent
```

## Where to go next

- [[ai/llama-swap]] — the endpoint the `compat` block above points at
- agent-skills — authoring the skills Pi loads
- [[ai/msty-claw]] — the desktop equivalent

<!-- uplink -->
Part of [[ai/index|Local LLMs]].
