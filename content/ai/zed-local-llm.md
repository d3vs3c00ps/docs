---
title: Zed with local models
description: Connecting Zed to local inference — the llama-swap, Ollama and direct llama.cpp paths, edit prediction with a FIM model, and what actually breaks
tags: [ai, llm, zed, editor, tooling]
type: howto
status: complete
---

# Zed with local models

> [!note] Not tested locally
> Zed is a desktop editor. The backends it connects to are tested in
> [[ai/llama-swap]], [[ai/ollama]] and [[ai/llama-cpp]].

[Zed](https://zed.dev/) connects to local models either through native Ollama
detection or through any OpenAI-compatible API.

**Recommended setup**: [[ai/llama-swap]] as a single proxy in front of every local
model. One Zed configuration, every model available, hot-swapped on demand. See
[[ai/quickstart-macos]] for the whole stack.

| Path | Best for |
| --- | --- |
| llama-swap | Several models — one stable endpoint, hot swap |
| Ollama | A single model, zero configuration |
| Direct llama.cpp | A single model, full flag control |

## The llama-swap path

[[ai/llama-swap]] exposes one OpenAI-compatible endpoint in front of every backend.
Zed sees a single provider listing all your models; switching in the agent panel
triggers a hot swap with no restart.

Add to `settings.json`. Use `openai_compatible` with a named sub-key — here
`"llama"` — rather than the legacy `"openai"` key:

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
              "tools": true,
              "images": false,
              "parallel_tool_calls": false,
              "prompt_cache_key": false,
              "chat_completions": true,
              "interleaved_reasoning": false
            }
          },
          {
            "name": "qwen-9b",
            "max_tokens": 16384,
            "max_output_tokens": 32000,
            "max_completion_tokens": 200000,
            "capabilities": {
              "tools": true,
              "images": false,
              "parallel_tool_calls": false,
              "prompt_cache_key": false,
              "chat_completions": true,
              "interleaved_reasoning": false
            }
          }
        ]
      }
    }
  },
  "agent": {
    "default_model": {
      "provider": "llama",
      "model": "qwen-27b"
    }
  }
}
```

Add one entry per model, following the same shape.

> [!important] Three things that silently break this
> **`name` must match the model ID exactly.** Verify what the proxy actually reports:
>
> ```bash
> curl -s http://localhost:8080/v1/models | python3 -m json.tool
> ```
>
> **`max_tokens` must not exceed the backend's `-c` value.** A larger value returns
> HTTP 400 `exceed_context_size_error`.
>
> **The first request to a model triggers a cold load**, 30–90 seconds on Apple
> Silicon. A request that appears to fail silently on first use is usually still
> loading — retry after a minute.

## The Ollama path

Zed auto-detects a running Ollama with no configuration:

```bash
ollama serve
ollama pull qwen3.6:27b
```

Open Zed, choose "Ollama" in the agent panel, pick the model.

For a non-default host, or a longer timeout on slow generations:

```json
{
  "language_models": {
    "ollama": {
      "api_url": "http://localhost:11434",
      "low_speed_timeout_in_seconds": 120
    }
  }
}
```

## The direct llama.cpp path

For a single model with full flag control, or one not in Ollama's library:

```bash
llama-server -m /path/to/qwen3.6-27b-q4_k_m.gguf \
  --host 127.0.0.1 --port 8080 -ngl 99 -c 32768
```

```json
{
  "language_models": {
    "openai": {
      "api_url": "http://localhost:8080/v1",
      "api_key": "local",
      "available_models": [
        {
          "name": "model.gguf",
          "display_name": "Qwen 3.6 27B (local)",
          "max_tokens": 16384
        }
      ]
    }
  }
}
```

> [!note] `name` is the server's model ID, not a label
> `llama-server` uses the filename of the loaded model as its ID. Copy the `id` field
> from `/v1/models` into `name`, and put the human-readable string in `display_name`.

> [!tip] The API key is required but ignored
> `llama-server` has no authentication, but Zed's OpenAI provider refuses an empty
> `api_key`. Any placeholder works — it goes out in the `Authorization` header and
> llama.cpp discards it.

For more than one model, use [[ai/llama-swap]] rather than several `llama-server`
instances on different ports.

## Edit prediction

Inline tab-completion is **separate** from the agent panel and has two different
requirements.

1. **It uses `/v1/completions`**, the raw completion endpoint — not
   `/v1/chat/completions`. The `api_url` must include the full path.
2. **It needs a model with native Fill-in-the-Middle support.** A general instruct
   model produces nothing at all, because it has no FIM tokens
   (`<|fim_prefix|>`, `<|fim_suffix|>`, `<|fim_middle|>`). This is a model capability
   limit, not a misconfiguration — see
   [zed#52918](https://github.com/zed-industries/zed/issues/52918).

The best small option is **Qwen2.5-Coder-7B (base)** — about 5 GB, fast enough for
per-keystroke latency, native FIM. Use the **base** model, not `-Instruct`: raw FIM
works better than chat-wrapped FIM for inline completion.

```bash
hf download unsloth/Qwen2.5-Coder-7B-GGUF \
  --include "*Q5_K_M*" \
  --local-dir ~/models/qwen2.5-coder-7b
```

Add it to [[ai/llama-swap]] — no `--jinja`, since this is raw completion rather than
chat:

```yaml
  qwen-coder:
    cmd: >
      llama-server --port ${PORT}
      -m /Users/YOUR_USER/models/qwen2.5-coder-7b/Qwen2.5-Coder-7B-Q5_K_M.gguf
      -ngl 99 -c 8192 --parallel 1
```

```json
{
  "edit_predictions": {
    "provider": "open_ai_compatible_api",
    "open_ai_compatible_api": {
      "api_url": "http://localhost:8080/v1/completions",
      "model": "qwen-coder",
      "prompt_format": "infer",
      "max_output_tokens": 256
    }
  }
}
```

> [!warning] Keep `/v1/completions` in the URL
> Unlike the agent panel, which takes the bare `/v1` base, edit prediction posts to
> the full completions path. Trimming it back to `/v1` breaks predictions with no
> useful error.

`model` is the raw proxy ID, with no `openai_compatible/` prefix. `prompt_format:
"infer"` auto-detects the FIM format from the model name; set it explicitly
(`deepseek_coder`, `codestral`, …) if predictions come back malformed.

Verify the endpoint by hand — it is POST-only, so a plain `curl` returning "Method
Not Allowed" is expected and not the bug:

```bash
curl -s http://localhost:8080/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen-coder", "prompt": "def fibonacci(n):", "max_tokens": 64}'
```

## MCP servers

Configured under `context_servers` — see [[ai/mcp]] for writing your own:

```json
{
  "context_servers": {
    "my-mcp-server": {
      "command": "/path/to/mcp-server-binary",
      "args": ["--some-flag"],
      "env": { "SOME_VAR": "value" }
    }
  }
}
```

Zed supports MCP **tools** and **prompts** only, not resources or sampling. Status
shows as indicator dots in the agent panel.

## Using the agent panel

- `Ctrl+Shift+Enter` opens or focuses the agent panel.
- The agent can read open files, run terminal commands and edit code.
- Click the model name at the top to switch provider or model.
- Select code and press `Ctrl+Enter` for the inline assistant — the selection plus
  your instruction, for quick edits.

## Limitations

**Tool calling** — local models struggle more than cloud APIs, particularly with enum
parameters in tool schemas and long multi-step tool chains. Qwen 3.5-27B and
3.6-27B are the strongest locally; 4B and 9B models are fine for completions but
unreliable with tools.

**Context window** — bounded by your RAM. Configuring `-c 32768` without the memory
to back it means the server either crashes or quietly falls back to something
smaller. See [[ai/hardware-requirements]].

**Speed** — expect 10–30 tokens/second on a modern GPU with a 27B at Q4_K_M. Slower
than a cloud API, but workable for agent flows. Smaller models reach 40–80 tok/s.

## Where to go next

- [[ai/parallel-agents]] — several agent threads, different models
- [[ai/llama-swap]] — the recommended backend for all of this
- [[ai/quickstart-macos]] — the full stack, start to finish

<!-- uplink -->
Part of [[ai/index|Local LLMs]].
