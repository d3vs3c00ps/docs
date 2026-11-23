---
title: Msty Claw
description: A desktop autonomous agent runner — connecting it to a local model, and its sandboxing, PII scrubbing and network guardrails
tags: [ai, llm, agents, tooling]
type: reference
status: complete
---

# Msty Claw

> [!note] Not tested locally
> Msty Claw is a desktop app. The `llama-server` line is tested in [[ai/llama-cpp]];
> the `mlx_lm.server` line needs Apple Silicon.

[Msty Claw](https://msty.ai/claw) is a desktop autonomous agent runner for macOS,
Windows and Linux. You describe a task in plain English, point it at a folder, API or
website, and it performs multi-step work on your machine — with sandboxing, on-device
PII scrubbing and container support.

It is a different product from its sibling **Msty Studio**, a multi-model chat
workspace closer to [[ai/open-webui]]. Claw is the agentic one; Studio is the
conversational one.

Against [[ai/pi]], which is a terminal coding agent, Claw is a native desktop
application aimed at general task automation rather than coding specifically. Both
can drive local models.

## Installation

Download from [msty.ai/claw](https://msty.ai/claw). Native app, no CLI needed.

## Connecting a local model

Claw accepts any OpenAI-compatible endpoint. Start the inference server first, then
add a custom provider.

### With llama-server

```bash
llama-server \
  -m ~/models/Qwen3.6-27B-Q4_K_M.gguf \
  -ngl 99 \
  -c 16384 \
  --parallel 1 \
  --port 8081
```

**Settings → Models → Add Provider**:

- **Type** — OpenAI-compatible
- **Base URL** — `http://localhost:8081/v1`
- **API Key** — any string; `llama-server` ignores it
- **Model name** — anything, used only as a label

> [!tip] Keep `--parallel 1` and an explicit `-c`
> Claw may open several concurrent connections, but for a single-user local setup one
> slot is correct — each additional slot multiplies KV cache by the context size. See
> [[ai/hardware-requirements]].

### With mlx_lm.server

```bash
mlx_lm.server \
  --model unsloth/Qwen3.6-27B-UD-MLX-4bit \
  --port 8082 \
  --max-tokens 8192
```

Same provider setup, pointing at `http://localhost:8082/v1`. Claw cannot tell the two
backends apart — use different ports if you run both.

### Which backend

For agentic work — multi-step, tool use — longer context and lower temperature matter
more than peak generation speed.

- **llama-server** — more quantization choice (`Q4_K_M` or `Q5_K_M`), and works
  wherever mlx-lm is unavailable.
- **mlx_lm.server** — native Apple Silicon, slightly faster prompt processing, which
  helps on tasks that resend large context repeatedly.

Better still, put [[ai/llama-swap]] in front of both and point Claw at one endpoint.

## Features worth knowing

**Sandboxing** — agents get scoped folder access by default and can only read and
write inside the folder you point them at. Docker or Podman environments give tighter
isolation.

**PII scrubbing** — when enabled, prompts are scanned on-device before reaching any
model, including local ones, stripping names, emails, phone numbers, account numbers,
addresses and secrets.

**Airlock** — per-agent network rules restricting which hosts an agent may reach.
Useful when an agent needs one specific API but not the open internet.

**Agents and roles** — named agents with their own role, tool access and model. A
"code reviewer" can use the 27B while a "quick summariser" uses a 9B.

> [!warning] Sandboxing is a guardrail, not a boundary
> Scoped folder access and Airlock meaningfully reduce the blast radius of an agent
> doing something unintended, but an autonomous agent with write access to a
> repository can still cause real damage. Run it against a clean working tree so
> `git diff` tells you exactly what it did, and do not point it at anything you have
> not committed.

> [!note] On-device scrubbing still sends the rest of the prompt
> PII scrubbing removes recognised patterns. It cannot recognise your own internal
> identifiers, hostnames or product names. With a local model none of it leaves the
> machine anyway — with a cloud model, do not treat scrubbing as sufficient for
> genuinely sensitive material.

## Typical workflow

1. Start `llama-server` or `mlx_lm.server`, or [[ai/llama-swap]].
2. Open Claw and select the local model.
3. Point it at a folder — a Go project, say.
4. Describe the task: *"Review all .go files for error handling gaps, list them by
   severity, and draft fixes for the top three."*
5. Claw runs and returns a structured report of what it did.

## Where to go next

- [[ai/pi]] — the terminal-based alternative
- [[ai/llama-swap]] — one endpoint for every client
- [[ai/open-webui]] — chat rather than agentic work

<!-- uplink -->
Part of [[ai/index|Local LLMs]].
