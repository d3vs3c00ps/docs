---
title: Parallel agents
description: Running several agent threads at once in Zed — worktree isolation, splitting work by domain, phase or model size, and serving multiple models
tags: [ai, llm, agents, zed, workflow, git]
type: howto
status: complete
---

# Parallel agents

> [!note] Partly tested
> The `git worktree` commands and the Ollama model names and default are checked.
> Zed itself, its agent panel and its settings, is not run.

Zed's [parallel agents](https://zed.dev/docs/ai/parallel-agents) run several agent
threads simultaneously, each with its own context window, history and — optionally —
its own Git worktree. That lets you split complex work across concurrent agents.

## Concepts

### Threads

Each thread is an independent conversation. You can send a prompt in one and switch
away while it is still generating.

| Action | Shortcut |
| --- | --- |
| Open the threads sidebar | `Ctrl+Alt+J` / `Cmd+Alt+J` |
| Focus the sidebar without toggling | `Ctrl+Alt+;` / `Cmd+Alt+;` |
| Cycle threads | `Ctrl+Tab`, `Ctrl+Shift+Tab` |
| Search threads | `Ctrl+F` with the sidebar focused |

Threads are grouped by project, each with its own sidebar section. To scope a new
thread to a project, hover its header and click `+`.

Each thread can use a **different model**, which is the key to splitting work
sensibly: a large model for hard tasks, a small one for mechanical ones.

## Worktree isolation

> [!warning] Two threads editing the same file will corrupt it
> Agent threads have no awareness of one another. Without separate worktrees,
> concurrent edits to the same files interleave and produce garbage — not merge
> conflicts you can resolve, but silently mixed output. Use a worktree for **any**
> file-editing parallelism.

To create one:

1. Click the **worktree picker** in the title bar, right of the project picker.
2. Choose "New Worktree" — Zed creates a linked worktree in detached HEAD.
3. Use the **branch picker** beside it to create a branch immediately.

New worktrees start detached, so always create the branch before the agent starts.

```text
main worktree (your branch)
  │
  ├── Thread 1: works directly on your branch
  │
  ├── Thread 2: → new worktree → branch "feat/api-tests"
  │                → agent writes tests
  │                → review diff → merge
  │                → archive thread → worktree cleaned up
  │
  └── Thread 3: → new worktree → branch "feat/docs"
                   → agent writes docs
                   → review diff → merge
                   → archive thread → worktree cleaned up
```

Archiving a thread that used a linked worktree — where no other thread uses it —
saves the Git state and removes the worktree from disk. Restoring the thread restores
the worktree.

### Automating worktree setup

A Zed task hook can run setup steps when a worktree is created. The `create_worktree`
hook receives:

- `ZED_WORKTREE_ROOT` — path to the new worktree
- `ZED_MAIN_GIT_WORKTREE` — path to the original repository

Useful for installing dependencies so the agent does not start in a broken tree.

## Splitting the work

### By domain

| Thread | Model | Area | Example task |
| --- | --- | --- | --- |
| 1 | Qwen 3.6-27B | Go backend | "Implement the ingestion service handler" |
| 2 | Qwen 3.5-9B | Python scripts | "Write a migration script for the new schema" |
| 3 | Qwen 3.5-4B | Infrastructure | "Update the Dockerfile and compose file" |

### By phase

| Thread | Model | Phase | Task |
| --- | --- | --- | --- |
| 1 | Qwen 3.6-27B | Plan | "Design the API contract. Output an OpenAPI spec." |
| 2 | Qwen 3.6-27B | Implement | "Implement the handler from this spec: …" |
| 3 | Qwen 3.5-9B | Test | "Write table-driven tests for the handler" |
| 4 | Qwen 3.5-4B | Document | "Write godoc comments for exported functions" |

Phases are sequential by nature — thread 2 cannot start until thread 1 has produced
its spec — so this pattern is about keeping context separate, not about concurrency.

### By model capability

| Task | Model | Why |
| --- | --- | --- |
| Architecture, complex refactoring | Qwen 3.6-27B or Qwopus-27B | Needs reasoning across many files |
| Focused, single-file implementation | Qwen 3.5-9B | Good enough for clearly scoped work |
| Boilerplate, formatting, simple docs | Qwen 3.5-4B | Fast and cheap; no reasoning required |
| Code review, debugging | Qwopus-27B | Distilled reasoning is good at subtle bugs |

See [[ai/models]] for the full comparison.

## Thread management

**Archiving** — hover a finished thread and click the archive icon, or press
`Shift+Backspace`. Running threads cannot be archived until they finish.

**History** — `Ctrl+G` / `Cmd+G`, or the clock icon. Clicking a thread restores it,
along with any associated worktree.

**Deleting** — in thread history, the trash icon. This removes conversation history
and worktree data permanently.

## Serving several models at once

Parallel threads need their models available simultaneously.

### Through llama-swap

The cleanest option: one endpoint, models loaded and unloaded on demand, with groups
controlling what stays resident. See [[ai/llama-swap]].

### Through Ollama

Ollama manages multiple models and Zed lists them natively:

```bash
ollama pull qwen3.6:27b
ollama pull qwen3.5:9b
```

Switch per thread from the model name at the top of the agent panel. Ollama loads and
unloads on demand, taking 5–10 seconds to swap.

Both can stay resident — roughly 22 GB for a 27B plus a 9B. Ollama does this by
default when memory allows: `OLLAMA_MAX_LOADED_MODELS` is `0`, which means up to 3
models per GPU. Set it only to cap the number, in a `systemctl edit ollama` override:

```ini
[Service]
Environment="OLLAMA_MAX_LOADED_MODELS=2"
```

### Mixed: llama-server plus Ollama

Keep `llama-server` for a model needing custom flags, and Ollama for the rest. Both
appear in Zed as separate providers:

```json
{
  "language_models": {
    "ollama": { "api_url": "http://localhost:11434" },
    "openai": {
      "api_url": "http://localhost:8080/v1",
      "api_key": "local",
      "available_models": [
        { "name": "model.gguf", "display_name": "Qwen 3.6 27B (llama-server)", "max_tokens": 16384 }
      ]
    }
  }
}
```

> [!note] Two llama-server instances need two providers
> Zed cannot route different model names to different ports through one provider
> block, so running two bare `llama-server` instances means a service file and port
> each. Use [[ai/llama-swap]] or the Ollama approach instead.

## Worktrees outside Zed

The pattern is not Zed-specific — it is plain `git worktree`, and works with any agent
that operates on a directory:

```bash
git worktree add ../tasks-app-api   -b feature/api
git worktree add ../tasks-app-tests -b feature/tests
git worktree list
```

Point one agent at each directory. See git for the mechanics, the rules —
notably that the same branch cannot be checked out twice — and the dependency-setup
problem every fresh worktree has.

## Tips

- **Start with one thread.** Add parallelism only for genuinely independent tasks —
  premature parallelisation costs more time than it saves.
- **Copy context between threads.** They share nothing. If thread 2 depends on thread
  1's output, paste it in.
- **Small models for small tasks.** A 4B generating boilerplate leaves the 27B's
  context window free for work that needs it.
- **Watch memory.** Several large models at once needs real RAM — see
  [[ai/hardware-requirements]].
- **Review every diff.** Parallel agents multiply output, and reviewing it is still
  your job. Worktrees exist so each thread's changes arrive as a separate,
  reviewable branch.

## Where to go next

- [[ai/llama-swap]] — serving several models cleanly
- [[ai/zed-local-llm]] — connecting Zed in the first place
- git — worktrees and branching

<!-- uplink -->
Part of [[ai/index|Local LLMs]].
