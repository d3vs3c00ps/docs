---
title: Local LLM quick start on macOS
description: A complete Apple Silicon stack in about thirty minutes — llama.cpp, MLX, llama-swap, Open WebUI, Pi and Zed, with the memory budget worked out
tags: [ai, llm, macos, quickstart, inference]
type: howto
status: complete
---

# Local LLM quick start on macOS

> [!note] Not tested locally
> A macOS stack (Homebrew, MLX, launchd, desktop apps). The Linux parts of each tool
> are tested in their own notes.

A complete local LLM stack on an M-series Mac. End state: several models managed by
[[ai/llama-swap]], reachable from a web chat UI ([[ai/open-webui]]), a terminal agent
([[ai/pi]]) and [[ai/zed-local-llm|Zed]].

**Reference hardware** — an M3 Pro with 36 GB unified memory. Adjustments for other
configurations are noted inline; see [[ai/hardware-requirements]] for the full sizing
logic.

**Time** — about 30 minutes, excluding model downloads.

## Step 1 — Install the tools

```bash
# Inference engines
brew install llama.cpp
brew install mlx-lm

# Model proxy — one endpoint for every model
brew tap mostlygeek/llama-swap
brew install llama-swap
brew trust --formula mostlygeek/llama-swap/llama-swap

# Web chat UI
brew install open-webui

# Terminal coding agent
curl -fsSL https://pi.dev/install.sh | sh
```

Homebrew warns that `mostlygeek/llama-swap` is an untrusted third-party tap — this
becomes an error in Homebrew 6.x — so trust the specific formula rather than the tap.

Verify:

```bash
llama-server --version
mlx_lm.server --help | head -5
llama-swap --version
pi --version
```

Open WebUI has no CLI binary on macOS; it installs as a desktop app.

## Step 2 — Download models

Roughly 60 GB in total. Downloads are resumable.

```bash
# Chat model — MoE, ~17 GB: good quality and fast, since only ~4B is active
mkdir -p ~/models/gemma-4-26b
hf download unsloth/gemma-4-26B-A4B-it-GGUF \
  --include "*UD-Q4_K_XL*" \
  --local-dir ~/models/gemma-4-26b

# Lighter chat alternative, ~8 GB — can stay resident beside the 27B
mkdir -p ~/models/gemma-4-12b
hf download unsloth/gemma-4-12b-it-GGUF \
  --include "*UD-Q4_K_XL*" \
  --local-dir ~/models/gemma-4-12b

# Fast secondary for quick tasks, ~7 GB
hf download unsloth/Qwen3.5-9B-GGUF \
  --include "Qwen3.5-9B-Q5_K_M.gguf" \
  --local-dir ~/models

# Primary coding model, ~16 GB
hf download unsloth/Qwen3.6-27B-GGUF \
  --include "Qwen3.6-27B-Q4_K_M.gguf" \
  --local-dir ~/models

# MLX build of the same model, to compare
mkdir -p ~/models/Qwen3.6-27B-UD-MLX-4bit
hf download unsloth/Qwen3.6-27B-UD-MLX-4bit \
  --local-dir ~/models/Qwen3.6-27B-UD-MLX-4bit

# FIM coder for Zed edit prediction, ~5 GB — instruct models will not work here
hf download unsloth/Qwen2.5-Coder-7B-GGUF \
  --include "*Q5_K_M*" \
  --local-dir ~/models/qwen2.5-coder-7b
```

## Step 3 — Configure llama-swap

Create `~/llama-swap.yaml`.

> [!danger] Absolute paths only
> llama-swap launches processes without a shell, so neither `~` nor `$HOME` expands.
> Replace `YOUR_USER` below with the output of `echo $USER`.

```yaml
healthCheckTimeout: 300
startPort: 5800
globalTTL: 600            # unload idle models after 10 minutes

models:
  # -c 32768 = 32K total context, input and output combined.
  # Agent tasks reach 20-30K tokens after a few tool-call round trips;
  # 16K causes spurious "context limit" failures on simple edits.
  # Memory: ~17 GB model + ~4.7 GB KV cache = ~22 GB. Safe on 36 GB.
  qwen-27b:
    cmd: >
      llama-server --port ${PORT}
      -m /Users/YOUR_USER/models/Qwen3.6-27B-Q4_K_M.gguf
      -ngl 99 -c 32768 --parallel 1
      --temp 0.2 --top-p 0.9 --repeat-penalty 1.05

  # useModelName is REQUIRED for mlx_lm.server — see the note below.
  # --max-tokens        = maximum OUTPUT tokens per response.
  # --max-kv-cache-size = total context window; caps the memory reservation
  #   instead of defaulting to the model's full 128K, which would pre-allocate
  #   ~18 GB of KV cache and trigger memory pressure.
  qwen-27b-mlx:
    cmd: >
      mlx_lm.server --port ${PORT}
      --model /Users/YOUR_USER/models/Qwen3.6-27B-UD-MLX-4bit
      --max-tokens 16384
      --max-kv-cache-size 32768
    useModelName: "/Users/YOUR_USER/models/Qwen3.6-27B-UD-MLX-4bit"

  # A 9B at 32K costs only ~1.5 GB of KV cache — essentially free.
  qwen-9b:
    cmd: >
      llama-server --port ${PORT}
      -m /Users/YOUR_USER/models/Qwen3.5-9B-Q5_K_M.gguf
      -ngl 99 -c 32768 --parallel 1

  gemma4-26b:
    cmd: >
      llama-server --port ${PORT}
      -m /Users/YOUR_USER/models/gemma-4-26b/gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf
      -ngl 99 -c 32768 --parallel 1
      --jinja

  gemma4-12b:
    cmd: >
      llama-server --port ${PORT}
      -m /Users/YOUR_USER/models/gemma-4-12b/gemma-4-12b-it-UD-Q4_K_XL.gguf
      -ngl 99 -c 32768 --parallel 1
      --jinja

  # FIM coder for edit prediction — no --jinja, this is raw completion.
  # Autocomplete requests are always short, so 8K is correct here.
  qwen-coder:
    cmd: >
      llama-server --port ${PORT}
      -m /Users/YOUR_USER/models/qwen2.5-coder-7b/Qwen2.5-Coder-7B-Q5_K_M.gguf
      -ngl 99 -c 8192 --parallel 1
```

> [!tip] Three things to get right first time
> **`--jinja`** — both Gemma variants ship a Jinja2 chat template. Older llama.cpp
> builds needed the flag, or responses came back garbled rather than failing. Current
> builds turn Jinja on by default (checked in [[ai/llama-swap]]), so the flag is
> harmless.
>
> **`useModelName`** is required for `mlx_lm.server`, which loads whatever model name
> the request carries. Without it, it tries to fetch `qwen-27b-mlx` from HuggingFace
> and 404s.
>
> **Verify the filenames.** Run `ls ~/models/gemma-4-26b/` — quantizer suffixes shift
> between uploads.

> [!warning] Do not add a `groups:` block until the basics work
> The `exclusive: true` plus `persistent: true` combination can make llama-swap abort
> model startup. Get every model working individually first, then see
> [[ai/llama-swap]] for groups.

### Choosing between the two chat models

| | 26B-A4B (MoE) | 12B unified |
| --- | --- | --- |
| Memory at Q4 | ~18 GB | ~8 GB |
| Generation speed | Faster — only ~4B active | Moderate, dense |
| Quality | Higher | Good |
| Audio support | No | Yes |
| Resident beside the 27B | No — too tight on 36 GB | Yes, ~26 GB combined |

## Step 4 — Start llama-swap

```bash
llama-swap --config ~/llama-swap.yaml --listen localhost:8080
```

The first request to any model triggers its load — 30–90 seconds for a 27B. The
built-in UI at `http://localhost:8080` shows which models are loaded, plus logs.

For a launchd service that starts it at login, see [[ai/llama-swap]].

## Step 5 — Start Open WebUI

`brew install open-webui` installs a native desktop app, not a CLI binary:

```bash
open -a "Open WebUI"
```

It runs its own embedded server. Connect llama-swap under **Settings → Admin →
Connections → Add OpenAI**, with URL `http://localhost:8080/v1` and API key `none`.

Every model appears in the picker, and you can switch mid-conversation — llama-swap
swaps transparently.

> [!note] The port
> The desktop app manages its own port. If you run `open-webui serve` from pip
> instead, pass `--port 3000` to keep 8080 free for llama-swap. Open WebUI does not
> read `WEBUI_PORT`.

## Step 6 — Configure Pi

```bash
mkdir -p ~/.pi/agent
cat > ~/.pi/agent/models.json << 'EOF'
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
EOF
```

Set a default model and restrict `Ctrl+P` cycling to local models:

```bash
cat > ~/.pi/agent/settings.json << 'EOF'
{
  "defaultProvider": "llama-swap",
  "defaultModel": "qwen-27b",
  "enabledModels": ["qwen-27b", "qwen-9b", "gemma4-12b", "gemma4-26b"]
}
EOF
```

Pi now starts on `qwen-27b`. `Ctrl+L` opens the full picker, `Ctrl+P` cycles the
local models only.

Global response-quality rules go in `~/.pi/agent/AGENTS.md`, loaded automatically —
there is a ready-made template in [[ai/prompt-optimization]].

## Step 7 — Connect Zed

Merge into Zed's `settings.json`, using `openai_compatible` with a named sub-key:

```json
{
  "language_models": {
    "openai_compatible": {
      "llama": {
        "api_url": "http://localhost:8080/v1",
        "available_models": [
          {
            "name": "qwen-27b",
            "max_tokens": 16384,
            "max_output_tokens": 32000,
            "max_completion_tokens": 200000,
            "capabilities": {
              "tools": true, "images": false, "parallel_tool_calls": false,
              "prompt_cache_key": false, "chat_completions": true,
              "interleaved_reasoning": false
            }
          }
        ]
      }
    }
  },
  "agent": {
    "default_model": { "provider": "llama", "model": "qwen-27b" }
  }
}
```

Add one entry per model. For **edit prediction**, a separate `edit_predictions` block
must point at `qwen-coder` on the `/v1/completions` endpoint — chat models cannot do
it at all. Full detail in [[ai/zed-local-llm]].

## What you end up with

| Model ID | Size | Speed | Best for |
| --- | --- | --- | --- |
| `qwen-27b` | ~17 GB | ~20 tok/s | Coding, multi-file edits, tool calling |
| `qwen-27b-mlx` | ~16 GB | ~25 tok/s | Same, slightly faster prompt processing |
| `qwen-9b` | ~7 GB | ~50 tok/s | Quick completions, parallel agent threads |
| `gemma4-26b` | ~18 GB | ~30 tok/s | Chat and reasoning — best quality |
| `gemma4-12b` | ~8 GB | ~35 tok/s | Chat with audio; resident beside the 27B |

On 36 GB at 32K context: ~17 GB model plus ~4.7 GB KV cache is about **22 GB** per
active large model — comfortable, no swap. At 48K (`-c 49152`) it is roughly 24 GB,
still fine if nothing else large is resident.

## Troubleshooting

**A model takes forever to load** — raise `healthCheckTimeout`. The 300 second
default is usually enough from NVMe.

**The agent crashes with "context length exceeded", or stops mid-edit** — the growing
conversation, including tool outputs, overflowed `-c` or the MLX KV cache. Raise to
`-c 49152`. A five-step edit session with file reads easily reaches 20–30K tokens.

**Memory pressure and swap** — two large models are resident at once. Check
`http://localhost:8080` to see which, and lower `globalTTL` to unload sooner. Note
that raising `-c` from 16K to 32K only adds ~2.4 GB, so it is rarely the cause.

**Garbled output from Gemma** — on an older llama.cpp build, `--jinja` is missing.
Add it, or update llama.cpp, and restart.

**Every model fails with "upstream command exited prematurely"** — the `cmd` paths
are not absolute. llama-swap expands neither `~` nor `$HOME`.

**Open WebUI shows no models** — confirm llama-swap is up with
`curl http://localhost:8080/v1/models`, then reconnect the provider.

## Where to go next

- [[ai/llama-swap]] — TTL, groups, launchd
- [[ai/llama-cpp]] — server flags and sampling
- [[ai/mlx]] — the MLX backend in detail
- [[ai/hardware-requirements]] — memory sizing and KV cache pitfalls
- [[ai/open-webui]] · [[ai/pi]] · [[ai/zed-local-llm]] — the clients

<!-- uplink -->
Part of [[ai/index|Local LLMs]].
