---
title: Ollama
description: The convenience wrapper around llama.cpp — installation, Modelfiles, loading custom GGUF files, and the API editors connect to
tags: [ai, llm, inference, ollama]
type: howto
status: complete
---

# Ollama

> [!note] Partly tested
> Tested with Ollama 0.40.6 on Fedora 44 (CPU only), with a 135M GGUF model in place
> of the 27B models; those are only checked to exist in the library. The `yay` and
> `brew` lines are not tested.

[Ollama](https://ollama.com/) wraps llama.cpp in a friendlier interface, handling
model downloads, quantization choice and server management for you.

Use Ollama for the fastest path to something working. Use [[ai/llama-cpp]] when you
need real control over quantization, context length, GPU offload or server
parameters.

## Choosing between them

| | Ollama | llama.cpp |
| --- | --- | --- |
| Setup time | Minutes | 10–30 minutes from source |
| Editor integration | Native auto-detection | Manual OpenAI-compatible config |
| Quantization control | Limited — it picks for you | Full — any GGUF variant |
| Context window | Modelfile only | Direct CLI flag |
| GPU layer offload | Automatic | Manual `-ngl` |
| Custom GGUF | Via Modelfile | Direct file path |
| Service management | Built in | Manual |

## Installation

```bash
# Linux, any distribution
curl -fsSL https://ollama.com/install.sh | sh

# Arch
yay -S ollama

# Fedora, via COPR
sudo dnf copr enable ferdnyc/ollama && sudo dnf install ollama

# macOS
brew install ollama
```

> [!warning] `curl | sh` executes whatever the server returns
> It is the vendor's documented method and the script is readable, but piping a
> remote script straight into a shell means you are trusting the endpoint at the
> moment you run it. On anything that matters, download it, read it, then run it.

The Linux installer also sets up a systemd service.

## Basic usage

```bash
ollama serve          # listens on http://localhost:11434
```

With the systemd install, the service starts automatically.

```bash
ollama pull qwen3.6:27b     # download
ollama run qwen3.6:27b      # interactive chat
ollama list                 # what is installed
ollama rm qwen3.6:27b       # remove
```

Models worth having:

```bash
ollama pull qwen3.6:27b      # dense 27B — best for coding
ollama pull qwen3.5:27b      # previous generation
ollama pull qwen3.5:9b       # smaller, faster
ollama pull qwen3.5:4b       # laptop-friendly
```

See [[ai/models]] for the comparison and [[ai/hardware-requirements]] for sizing.

## Modelfiles

A Modelfile customises behaviour, system prompt and parameters — useful for
task-specific configurations.

```dockerfile
# Modelfile.golang
FROM qwen3.6:27b

PARAMETER temperature 0.3
PARAMETER num_ctx 32768
PARAMETER top_p 0.9

SYSTEM """You are a senior Go developer. You write idiomatic, well-tested Go code.
Always prefer the standard library. Use table-driven tests. Follow the conventions
in Effective Go and the Go Code Review Comments wiki."""
```

```bash
ollama create go-assistant -f Modelfile.golang
ollama run go-assistant
```

| Parameter | Default | Meaning |
| --- | --- | --- |
| `temperature` | 0.8 | Lower is more deterministic — use 0.1–0.3 for code |
| `num_ctx` | 4096, 32768 or 262144, by VRAM | Context window in tokens |
| `top_p` | 0.9 | Nucleus sampling threshold |
| `num_gpu` | auto | GPU layers; `0` for CPU only |
| `repeat_penalty` | 1.0 | Penalty for repeated tokens |

> [!important] Check the context you actually get
> Without `num_ctx`, Ollama picks 4k, 32k or 256k tokens from the free VRAM. On a
> CPU-only machine that is 4096, far below what a real coding task needs. If the
> model seems to "forget" the file you just pasted, this is almost always why. Set
> `num_ctx` in a Modelfile, set `OLLAMA_CONTEXT_LENGTH` for the server, or pass it
> per request in `options`:
>
> ```bash
> curl http://localhost:11434/api/generate -d '{
>   "model": "go-assistant", "prompt": "Hello",
>   "options": {"num_ctx": 32768}
> }'
> ```
>
> `curl http://localhost:11434/api/ps` shows the `context_length` in use.

> [!note] Defaults in Ollama 0.40.6
> The default `num_ctx` depends on the GPU memory, and `options.num_ctx` sets it per
> request. `repeat_penalty` defaults to 1.0. `OLLAMA_MAX_LOADED_MODELS` defaults to 3
> per GPU.

## Loading a custom GGUF

For a [[ai/quantization-glossary|quantization]] that Ollama's own library does not
offer:

```dockerfile
# Modelfile.custom
FROM /path/to/your-model.gguf

PARAMETER num_ctx 32768
```

```bash
ollama create my-custom-model -f Modelfile.custom
ollama run my-custom-model
```

## API

Ollama serves on port 11434, and offers both its own API and an OpenAI-compatible
one. Zed uses this directly — see [[ai/zed-local-llm]].

```bash
# List models
curl http://localhost:11434/api/tags

# Native API
curl http://localhost:11434/api/chat -d '{
  "model": "qwen3.6:27b",
  "messages": [{"role": "user", "content": "Hello"}]
}'

# OpenAI-compatible endpoint
curl http://localhost:11434/v1/chat/completions -d '{
  "model": "qwen3.6:27b",
  "messages": [{"role": "user", "content": "Hello"}]
}'
```

## Environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `OLLAMA_HOST` | `127.0.0.1:11434` | Bind address and port |
| `OLLAMA_MODELS` | `~/.ollama/models` | Where models are stored. For the systemd service this is the `ollama` user's home: `/usr/share/ollama/.ollama/models` |
| `OLLAMA_NUM_PARALLEL` | `1` | Parallel request slots |
| `OLLAMA_MAX_LOADED_MODELS` | `0`: 3 per GPU, or 3 on CPU | Models resident simultaneously. Each must still fit in memory |

Set them in your shell profile, or as a systemd override:

```bash
sudo systemctl edit ollama
```

`systemctl edit` opens an editor for a drop-in file. Put this in it:

```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_NUM_PARALLEL=2"
```

> [!warning] `OLLAMA_HOST=0.0.0.0` exposes an unauthenticated API
> Ollama has no authentication. Binding to all interfaces lets anyone on the network
> run inference on your hardware and read whatever is in context. Keep the default
> loopback binding unless you have put authentication in front of it.

## Where to go next

- [[ai/llama-cpp]] — when you outgrow the abstraction
- [[ai/llama-swap]] — several models behind one endpoint
- [[ai/zed-local-llm]] — editor integration
- [[kubernetes/mlops/ollama-intro]] — the same engine, running on a cluster

<!-- uplink -->
Part of [[ai/index|Local LLMs]].
