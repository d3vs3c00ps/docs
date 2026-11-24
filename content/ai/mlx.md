---
title: MLX
description: Apple's native ML framework for local inference on Apple Silicon — when to prefer it over llama.cpp, running mlx_lm.server, and its quirks behind a proxy
tags: [ai, llm, inference, macos, mlx]
type: howto
status: complete
---

# MLX

> [!note] Not tested locally
> MLX runs on Apple Silicon only. The test harness runs Linux containers.

[MLX](https://github.com/ml-explore/mlx) is Apple's open-source machine learning
framework, built specifically for Apple Silicon. For LLM inference the `mlx-lm`
package provides a CLI and an OpenAI-compatible server — a macOS-native alternative
to [[ai/llama-cpp]].

**Apple Silicon only.** MLX does not run on Linux or on Intel Macs.

## When to prefer it over llama.cpp

| | MLX | llama.cpp |
| --- | --- | --- |
| Platform | Apple Silicon only | Cross-platform |
| Model format | MLX — a separate download from GGUF | GGUF |
| Install | `brew install mlx-lm` | `brew install llama.cpp` |
| Python dependency | Yes | None |
| Quantization options | 4-bit, 8-bit, bf16 | Many |
| Prompt processing | Often faster on M-series | Good |
| Generation speed | Similar or slightly faster | Good |
| Model availability | Growing | Very broad |

**Choose MLX** when you are Python-heavy, want Apple's native stack, or a model you
need has an MLX release but no well-maintained GGUF quantization.

**Stay on llama.cpp** for the broadest model selection, the most quantization
control, or a setup with no Python dependency at all.

## Installation

```bash
brew install mlx-lm
brew upgrade mlx-lm
```

This pulls in `mlx` as a dependency and puts `mlx_lm.server`, `mlx_lm.generate` and
`mlx_lm.chat` on your PATH, with no Python environment to manage.

Three related Homebrew packages exist; only one matters here:

| Package | What it is | Install? |
| --- | --- | --- |
| `mlx` | Core array framework — Apple's numpy for Apple Silicon | Automatic, as a dependency |
| `mlx-lm` | LLM inference: CLI plus OpenAI-compatible server | **Yes, this one** |
| `mlx-c` | C bindings for embedding MLX in C/C++ | No |

Via pip, if you need something newer than the bottle or want it inside a specific
environment:

```bash
python3 -m venv ~/.venvs/mlx && source ~/.venvs/mlx/bin/activate && pip install mlx-lm
```

## Downloading models

> [!warning] MLX cannot read GGUF
> It uses its own format. If you point it at a GGUF file you get a format error.
> Download the `-MLX` variant of the repository instead.

Unsloth publishes separate MLX repositories per quantization level:

| Repository | Size | When |
| --- | --- | --- |
| `unsloth/Qwen3.6-27B-UD-MLX-4bit` | ~16 GB | Default — best balance on 36 GB |
| `unsloth/Qwen3.6-27B-UD-MLX-6bit` | ~21 GB | Quality bump, still comfortable |
| `unsloth/Qwen3.6-27B-UD-MLX-3bit` | ~12 GB | When you need headroom for other apps |
| `unsloth/Qwen3.6-27B-MLX-8bit` | ~29 GB | Near-lossless, but tight on 36 GB |

`UD-` marks Unsloth Dynamic quantization — better quality at the same bit width, so
prefer it. See [[ai/quantization-glossary]].

Let `mlx_lm` fetch it on first run, caching into `~/.cache/huggingface/`:

```bash
mlx_lm.server \
  --model unsloth/Qwen3.6-27B-UD-MLX-4bit \
  --port 8080 \
  --max-tokens 8192
```

Or download first and run offline:

```bash
hf download unsloth/Qwen3.6-27B-UD-MLX-4bit --local-dir ~/models/Qwen3.6-27B-UD-MLX-4bit

mlx_lm.server \
  --model ~/models/Qwen3.6-27B-UD-MLX-4bit \
  --port 8080 \
  --max-tokens 8192
```

An MLX 4-bit 27B is about the same size as a GGUF Q4_K_M, so memory requirements
match — see [[ai/hardware-requirements]].

## Running the server

`mlx_lm.server` exposes the same `/v1/chat/completions` API as `llama-server`, so
[[ai/zed-local-llm|Zed]] needs nothing but a different port.

| Flag | Default | Notes |
| --- | --- | --- |
| `--model` | — | Repo ID or path to the MLX model directory |
| `--port` | 8080 | HTTP port |
| `--host` | `127.0.0.1` | Bind address |
| `--max-tokens` | model max | **Always set this** |
| `--trust-remote-code` | false | Needed for some custom architectures |

> [!danger] Always set `--max-tokens`
> MLX has the same KV-cache over-allocation problem as llama.cpp on unified memory:
> uncapped, it will consume whatever is available and push the machine into swap. See
> [[ai/hardware-requirements]].

> [!warning] `--trust-remote-code` executes model-supplied Python
> It runs arbitrary code from the model repository at load time. Only enable it for
> repositories you trust, and never as a habitual flag to make an error go away.

Verify:

```bash
curl http://localhost:8080/v1/models
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mlx","messages":[{"role":"user","content":"Hello"}]}'
```

### As a background service

```bash
brew services start mlx-lm
brew services stop mlx-lm
brew services list
```

> [!note] The service starts with default flags
> `brew services start mlx-lm` runs without `--model` or `--max-tokens`, which is
> almost never what you want. Either edit
> `~/Library/LaunchAgents/homebrew.mxcl.mlx-lm.plist`, or simply run the command
> directly with your flags — easier to configure and to inspect. Better still, put
> MLX behind [[ai/llama-swap]], which manages the process lifecycle for you.

## CLI, without a server

```bash
mlx_lm.generate --model ~/models/Qwen3.6-27B-MLX \
  --prompt "Write a Go function that reverses a string"

mlx_lm.chat --model ~/models/Qwen3.6-27B-MLX
```

## Troubleshooting

### `mlx_lm` command not found

For a Homebrew install the binaries are under `/opt/homebrew/opt/mlx-lm/bin/`:

```bash
brew link mlx-lm
```

For pip, activate the virtualenv, or invoke the module directly:

```bash
python3 -m mlx_lm.server --model ~/models/Qwen3.6-27B-MLX --port 8080 --max-tokens 8192
```

### Memory pressure and swap

Same root cause as llama.cpp — context over-allocation. Pass `--max-tokens`. Confirm
in Activity Monitor that wired memory stays under roughly 26 GB on a 36 GB machine
while the model is loaded.

### `404 Repository Not Found` behind llama-swap

`mlx_lm.server` reads the `model` field of each request and tries to load *that
name*, unlike `llama-server` which ignores it and always serves whatever `--model`
loaded. Behind a proxy the request arrives carrying the alias, which MLX treats as a
HuggingFace repo ID:

```text
404 Client Error. Repository Not Found for url: https://huggingface.co/api/models/qwen-27b-mlx/revision/main
```

Fix it with `useModelName` in the [[ai/llama-swap]] config, so the `model` field is
rewritten to the local path before forwarding:

```yaml
  qwen-27b-mlx:
    cmd: >
      mlx_lm.server --port ${PORT}
      --model /Users/YOUR_USER/models/Qwen3.6-27B-UD-MLX-4bit
      --max-tokens 8192
    useModelName: "/Users/YOUR_USER/models/Qwen3.6-27B-UD-MLX-4bit"
```

## Where to go next

- [[ai/llama-cpp]] — the cross-platform alternative
- [[ai/llama-swap]] — running MLX and GGUF backends side by side
- [[ai/hardware-requirements]] — unified memory sizing

<!-- uplink -->
Part of [[ai/index|Local LLMs]].
