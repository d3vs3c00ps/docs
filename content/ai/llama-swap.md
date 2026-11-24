---
title: llama-swap
description: A proxy that gives every client one stable endpoint and hot-swaps model backends on demand, with automatic unloading on idle
tags: [ai, llm, inference, proxy]
type: howto
status: complete
---

# llama-swap

> [!note] Partly tested
> Tested with the llama-swap v275 Linux binary, with small fake backends in place of
> `llama-server` and `mlx_lm.server`: the config, `useModelName`, `startPort`, TTLs,
> absolute paths, groups and the web UI. The `--jinja` default is checked in the llama.cpp
> source. Homebrew, launchd and the clients are not tested.

[llama-swap](https://github.com/mostlygeek/llama-swap) is a small Go proxy that sits
in front of [[ai/llama-cpp|llama-server]] — or any other OpenAI-compatible backend
such as [[ai/mlx|mlx_lm.server]]. It presents one stable endpoint and starts, stops
and swaps inference servers automatically, based on the `model` field of each
request.

**The problem it solves.** Without it, running several models means several terminal
sessions, several ports, and editing every client's configuration whenever you
switch. With it, [[ai/zed-local-llm|Zed]], [[ai/open-webui]] and
[[ai/msty-claw|Msty Claw]] all point at one address forever.

## Installation

```bash
brew tap mostlygeek/llama-swap
brew install llama-swap
llama-swap --version
```

Homebrew warns that this is an untrusted third-party tap, and will make that an error
in Homebrew 6.x. Trust the specific formula rather than the whole tap:

```bash
brew trust --formula mostlygeek/llama-swap/llama-swap
```

## Configuration

A single YAML file. Create `~/llama-swap.yaml`:

```yaml
# Global settings
healthCheckTimeout: 300   # seconds to wait for a model to load; a 27B needs ~60-90s from NVMe
startPort: 5800           # backends get ports assigned from here
globalTTL: 600            # unload idle models after 10 minutes

models:
  # --- Primary coding model, GGUF via llama-server ---
  qwen-27b:
    cmd: >
      llama-server --port ${PORT}
      -m /Users/YOUR_USER/models/Qwen3.6-27B-Q4_K_M.gguf
      -ngl 99 -c 16384 --parallel 1
      --temp 0.2 --top-p 0.9 --repeat-penalty 1.05

  # --- Same model through MLX, to compare quality and speed ---
  # useModelName is REQUIRED for mlx_lm.server — see below.
  qwen-27b-mlx:
    cmd: >
      mlx_lm.server --port ${PORT}
      --model /Users/YOUR_USER/models/Qwen3.6-27B-UD-MLX-4bit
      --max-tokens 8192
    useModelName: "/Users/YOUR_USER/models/Qwen3.6-27B-UD-MLX-4bit"

  # --- Fast secondary, for quick tasks and parallel threads ---
  qwen-9b:
    cmd: >
      llama-server --port ${PORT}
      -m /Users/YOUR_USER/models/Qwen3.5-9B-Q5_K_M.gguf
      -ngl 99 -c 16384 --parallel 1

  # --- A chat model; MoE, so fast despite the total parameter count ---
  gemma4:
    cmd: >
      llama-server --port ${PORT}
      -m /Users/YOUR_USER/models/gemma-4-26b/gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf
      -ngl 99 -c 16384 --parallel 1
      --jinja
```

Replace `YOUR_USER` throughout with the output of `echo $USER`.

> [!danger] Absolute paths only — `~` and `$HOME` both fail
> llama-swap launches processes directly, without a shell, so **no path expansion of
> any kind** happens. If every model fails instantly with *"upstream command exited
> prematurely"*, a non-absolute path in `cmd` is the first thing to check.

> [!tip] Three configuration details that cost an evening each
> **`--jinja`** — models shipping a Jinja2 chat template need the Jinja engine.
> Older llama.cpp builds needed the flag; without it they fell back to a generic
> template and responses came back malformed rather than failing loudly. Current
> builds (b12647 checked) turn Jinja on by default, so the flag is harmless; use
> `--no-jinja` to turn it off.
>
> **`globalTTL`** — essential on unified memory. On a 36 GB machine two 27B models
> cannot coexist, so the TTL guarantees the idle one is unloaded before the next
> loads.
>
> **`useModelName`** — mandatory for `mlx_lm.server` backends. `llama-server` ignores
> the request's `model` field and always serves whatever `-m` loaded, but
> `mlx_lm.server` *reads* that field and tries to load it. Without `useModelName`,
> llama-swap forwards the alias (`qwen-27b-mlx`), MLX treats it as a HuggingFace repo
> ID, and you get `404 Repository Not Found`. Setting it to the local model path
> makes llama-swap rewrite the field before forwarding, so MLX matches its
> already-loaded model.

### Configuration reference

| Field | Level | Effect |
| --- | --- | --- |
| `healthCheckTimeout` | global | Seconds to wait for `/health` to return 200. Default 120, minimum 15 |
| `startPort` | global | First port for the `${PORT}` macro, assigned alphabetically by model ID |
| `globalTTL` | global | Idle seconds before auto-unload; `0` never unloads |
| `cmd` | model | Command to launch the backend; `${PORT}` is substituted |
| `ttl` | model | Per-model override; `-1` inherits the global value |
| `useModelName` | model | Rewrites the `model` value sent upstream |

## Running it

```bash
llama-swap --config ~/llama-swap.yaml --listen localhost:8080
```

It now serves `http://localhost:8080/v1` — the same path a bare `llama-server` would.
Client configuration never changes again.

### As a macOS login service

```xml
<!-- ~/Library/LaunchAgents/dev.llama-swap.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.llama-swap</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/llama-swap</string>
    <string>--config</string>
    <string>/Users/YOUR_USER/llama-swap.yaml</string>
    <string>--listen</string>
    <string>localhost:8080</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/llama-swap.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/llama-swap.err</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/dev.llama-swap.plist
launchctl start dev.llama-swap

# Reload after editing the plist or the config
launchctl stop dev.llama-swap
launchctl unload ~/Library/LaunchAgents/dev.llama-swap.plist
launchctl load ~/Library/LaunchAgents/dev.llama-swap.plist
```

Logs: `tail -f /tmp/llama-swap.log`.

## Connecting clients

Everything points at `http://localhost:8080/v1` and selects a model by name.

### Zed

One `openai` provider, with every model listed:

```json
{
  "language_models": {
    "openai": {
      "api_url": "http://localhost:8080/v1",
      "api_key": "local",
      "available_models": [
        { "name": "qwen-27b",     "display_name": "Qwen 3.6 27B (coding)", "max_tokens": 16384 },
        { "name": "qwen-27b-mlx", "display_name": "Qwen 3.6 27B MLX",      "max_tokens": 8192  },
        { "name": "qwen-9b",      "display_name": "Qwen 3.5 9B (fast)",    "max_tokens": 16384 },
        { "name": "gemma4",       "display_name": "Gemma 4 26B (chat)",    "max_tokens": 16384 }
      ]
    }
  }
}
```

### Open WebUI

**Settings → Admin → Connections → Add OpenAI connection**, URL
`http://localhost:8080/v1`, API key `none`. Every model appears in the picker
automatically, because llama-swap returns them all from `/v1/models`.

### Msty Claw and Pi

Any OpenAI-compatible provider pointed at `http://localhost:8080/v1`, API key `none`,
selecting the model by its ID.

## Model groups

For the common case — one large model at a time — the default swap behaviour is
enough. Groups matter when you want a small model permanently resident alongside the
active large one:

```yaml
groups:
  main:
    swap: true       # only one member active at a time
    exclusive: true  # unloads other groups when this one activates
    members:
      - qwen-27b
      - qwen-27b-mlx
      - gemma4

  fast:
    swap: false       # members may run simultaneously
    exclusive: false
    persistent: true  # never unloaded by other groups
    members:
      - qwen-9b
```

Here `qwen-9b` stays resident at about 6 GB while the 27B models hot-swap within
`main`.

> [!note] `groups` has a new home
> Since the `routing` section was added, the documented place is
> `routing.settings.groups`, with `routing.router.use: group`. The top-level
> `groups:` shown here still loads and works in v275. Peak memory is roughly 6 + 20 = 26 GB, comfortable on 36 GB.

## Built-in web UI

Open `http://localhost:8080` in a browser for loaded models, token metrics and a live
log stream. Useful for confirming which backend actually served a request.

## Updating

```bash
brew upgrade llama-swap
launchctl stop dev.llama-swap && launchctl start dev.llama-swap
```

## Where to go next

- [[ai/llama-cpp]] — the backend this proxies
- [[ai/mlx]] — the MLX backend and its `useModelName` requirement
- [[ai/quickstart-macos]] — this in context, as part of a full setup

<!-- uplink -->
Part of [[ai/index|Local LLMs]].
