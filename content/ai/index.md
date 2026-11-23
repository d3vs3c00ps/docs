---
title: Local LLMs
description: Running large language models on your own hardware — inference engines, model selection, quantization, IDE integration and agent tooling
tags: [ai]
type: moc
status: complete
---

# Local LLMs

Everything needed to run large language models locally for development work: a
reproducible, well-understood setup for LLM-assisted development that does not send
your code anywhere.

This is the desktop and workstation angle. For serving models *on a cluster* — with
autoscaling, queueing and metrics — see [[kubernetes/mlops/index|MLOps on Kubernetes]],
which covers the same engines from the operations side.

## Quick start

**On macOS with Apple Silicon**, [[ai/quickstart-macos]] is a complete step-by-step
setup — four models, llama-swap, Open WebUI and Pi, in about thirty minutes.

For other platforms, or a manual build:

1. **Build the inference engine** — [[ai/llama-cpp]] (preferred) or [[ai/ollama]]
   (simpler fallback)
2. **Check your hardware** — [[ai/hardware-requirements]] decides which model and
   quantization you can actually run
3. **Pick a model** — [[ai/models]]
4. **Configure your editor** — [[ai/zed-local-llm]]
5. **Improve the workflow** — [[ai/prompt-optimization]], [[ai/parallel-agents]] and
   agent-skills

## Infrastructure

| Note | | What it covers |
| --- | --- | --- |
| [[ai/llama-cpp\|llama.cpp]] | how-to | Building, configuring and running the primary inference engine |
| [[ai/ollama\|Ollama]] | how-to | The simpler alternative when llama.cpp is impractical |
| [[ai/mlx\|MLX]] | how-to | Apple's native ML framework, macOS only |
| [[ai/llama-swap\|llama-swap]] | how-to | Proxy managing several model instances behind one endpoint |
| [[ai/hardware-requirements\|Hardware requirements]] | reference | VRAM and RAM sizing, GPU versus CPU, partial offload |
| [[ai/quickstart-macos\|macOS quick start]] | howto | The whole stack on Apple Silicon in one guide |

## Interfaces and frontends

| Note | | What it covers |
| --- | --- | --- |
| [[ai/open-webui\|Open WebUI]] | how-to | Self-hosted chat interface for any OpenAI-compatible backend |
| [[ai/pi\|Pi]] | how-to | Minimal terminal coding agent, 15+ providers including local models |
| [[ai/msty-claw\|Msty Claw]] | reference | Desktop autonomous agent runner with sandboxed execution |

## Editor and tooling

| Note | | What it covers |
| --- | --- | --- |
| [[ai/zed-local-llm\|Zed with local models]] | how-to | Connecting Zed to Ollama and llama.cpp |
| [[ai/mcp\|Model Context Protocol]] | concept | Using and writing MCP servers |
| [[ai/strands-agents\|Strands Agents]] | how-to | Building an agent against a local model — tools, MCP, and when an agent is the wrong shape |
| [[ai/parallel-agents\|Parallel agents]] | how-to | Multiple agent threads with worktree isolation |

## Background

| Note | | What it covers |
| --- | --- | --- |
| [[ai/models\|Model landscape]] | reference | Which models are worth running locally, and why |
| [[ai/quantization-glossary\|Quantization glossary]] | concept | What Q4_K_M, MoE, GGUF and the rest actually mean |
| [[ai/prompt-optimization\|Prompt optimization]] | how-to | Prompting local models, which differs from prompting frontier ones |

## Finding tools

The space moves fast enough that curated indexes are more useful than any fixed list:

- [free-ai-tools](https://github.com/ShaikhWarsi/free-ai-tools) — a broad index of
  freely available AI tools, well beyond local inference
- [skills.sh](https://www.skills.sh) — the agent skills registry; see
  agent-skills
- [HuggingFace](https://huggingface.co/) — models, and the quantized GGUF builds this
  section depends on

> [!note] Treat aggregated lists as a starting point
> An index tells you a tool exists, not whether it is maintained, self-hosted, or
> sending your prompts somewhere. For anything that will see real code, check where
> inference happens before installing it — which is the whole reason this section
> exists.

## External references

- [llama.cpp](https://github.com/ggml-org/llama.cpp) — inference engine
- [Ollama](https://ollama.com/) — model runner
- [MLX](https://github.com/ml-explore/mlx) and [mlx-lm](https://github.com/ml-explore/mlx-examples/tree/main/llms) — Apple Silicon
- [Open WebUI](https://github.com/open-webui/open-webui) — self-hosted chat UI
- [llama-swap](https://github.com/mostlygeek/llama-swap) — multi-model proxy
- [Zed](https://zed.dev/) — editor with local LLM support
- [HuggingFace](https://huggingface.co/) — model repository
- [MCP specification](https://modelcontextprotocol.io/) — protocol documentation

Part of [[index|Ops Notes]].
