---
title: Open WebUI
description: A self-hosted chat interface for any OpenAI-compatible backend — installation, connecting local models, RAG and the security settings that matter
tags: [ai, llm, web-ui, self-hosted]
type: howto
status: complete
---

# Open WebUI

> [!note] Partly tested
> Tested with the v0.13.4 Docker image and a fake OpenAI backend: the `docker run`,
> sign-up and the admin account, `OPENAI_API_BASE_URL`, the Ollama default and the data
> volume. The macOS app, the pip install and the UI features are not tested.

[Open WebUI](https://github.com/open-webui/open-webui) is a self-hosted, ChatGPT-like
web interface that works against any OpenAI-compatible backend, and natively against
[[ai/ollama]]. It is the chat front end in the
[[ai/quickstart-macos|macOS quick start]] stack.

Against the alternatives: [[ai/pi]] is a terminal coding agent, and
[[ai/msty-claw|Msty Claw]] is an autonomous task runner. Open WebUI is the one for
ordinary conversation, with document upload and multi-user support.

## Installation

### macOS

```bash
brew install open-webui
open -a "Open WebUI"
```

This installs a native desktop app rather than a CLI binary. It runs its own embedded
server and manages the port internally.

### Docker

The usual choice on Linux and servers:

```bash
docker run -d \
  --name open-webui \
  -p 3000:8080 \
  -v open-webui:/app/backend/data \
  --restart unless-stopped \
  ghcr.io/open-webui/open-webui:main
```

Then open `http://localhost:3000`.

> [!warning] Port 8080 collides with llama-swap
> Open WebUI listens on 8080 internally, which is also [[ai/llama-swap]]'s default. In
> Docker the `-p 3000:8080` mapping avoids it. For a native install, use
> `open-webui serve --port 3000`. Two services fighting over one port produces confusing
> "connection refused" errors in whichever lost.

### Python

```bash
pip install open-webui
open-webui serve --port 3000
```

Needs Python 3.11 or 3.12 (v0.13.4 does not install on 3.13).

> [!note] There is no `WEBUI_PORT`
> Open WebUI does not read `WEBUI_PORT`. The native server takes `--port`. The Docker
> image reads `PORT` (default 8080), but with Docker you change the host side of `-p`
> instead.

## Connecting a local backend

### llama-swap, llama.cpp or MLX

**Settings → Admin → Connections → Add OpenAI connection**:

- **URL** — `http://localhost:8080/v1`
- **API key** — `none`, or any placeholder; local servers ignore it

With [[ai/llama-swap]] behind it, every configured model appears in the picker
automatically, because the proxy lists them all at `/v1/models`. You can switch model
mid-conversation and the swap happens transparently.

> [!note] From inside Docker, `localhost` is the container
> A containerised Open WebUI cannot reach a host-side inference server at
> `localhost`. Use `http://host.docker.internal:8080/v1` on macOS and Windows, or run
> the container with `--network=host` on Linux.

### Ollama

Auto-detected at `http://localhost:11434`. The Docker image looks at
`http://host.docker.internal:11434` instead, so it finds an Ollama on the host where
that name resolves (macOS, Windows). Set `OLLAMA_BASE_URL` otherwise.

## Features worth knowing

**Documents and RAG** — upload files, or reference them with `#`, and Open WebUI
chunks and embeds them for retrieval. The default embedding model runs locally, so
nothing is sent anywhere. Configure it under **Settings → Documents**.

**Model presets** — save a system prompt and sampling parameters as a named model,
the equivalent of an [[ai/ollama|Ollama Modelfile]] but managed in the UI.

**Multi-user** — accounts with roles, so a single instance can serve a household or a
team. The first account created becomes the administrator.

**Pipelines** — a plugin framework for injecting custom logic such as filters, rate
limits or routing between models.

## Security

Open WebUI is a full multi-user web application, not a local toy, and its defaults
suit a trusted network rather than the open internet.

> [!danger] Do not expose it without authentication in front
> - **The first account to register becomes an administrator.** If the instance is
>   reachable before you have registered, someone else can claim it. Create your
>   account immediately after starting it for the first time.
> - **Sign-up closes after that first account.** Add the other users from the admin
>   panel, or turn sign-up back on there for a while.
> - **Put TLS and a reverse proxy in front** of any instance that leaves localhost.
>   See nginx, and [[security/cryptography/tls-protocol]] for the settings.
> - **Conversations and uploaded documents are stored on disk**, in the volume mounted
>   at `/app/backend/data`. Anyone with access to that volume can read every chat.

Useful environment variables:

| Variable | Purpose |
| --- | --- |
| `PORT` | Listening port inside the Docker image, default 8080 |
| `ENABLE_SIGNUP` | Sign-up before the first account. After it, the admin setting wins |
| `WEBUI_AUTH` | Set `false` only for a strictly single-user local instance |
| `OLLAMA_BASE_URL` | Where to find Ollama |
| `OPENAI_API_BASE_URL` | An OpenAI-compatible backend such as llama-swap |
| `DATA_DIR` | Where conversations and uploads are stored |

> [!note] Sign-up closes by itself
> The first sign-up stores "sign-up off" in Open WebUI's database. From then on the
> stored setting wins: a restart with `ENABLE_SIGNUP=true` does not reopen it. Change
> it in the admin settings.

## Running at login

```bash
# Docker — the run command above already has --restart unless-stopped
docker update --restart unless-stopped open-webui
```

On macOS, add the Open WebUI app to **System Settings → General → Login Items**.
Remember `--port` on a native install if llama-swap already holds 8080.

> [!note] No `brew services` on macOS
> Homebrew has only an `open-webui` cask (the desktop app), no formula, and
> `brew services` works with formulae only.

## Troubleshooting

**No models in the picker** — confirm the backend is reachable first:

```bash
curl http://localhost:8080/v1/models
```

If that works, reconnect the provider in **Settings → Admin → Connections**.

**Connection refused from a container** — `localhost` inside the container is the
container. Use `host.docker.internal`, or `--network=host` on Linux.

**First message hangs, later ones are fast** — the backend is cold-loading the model.
A 27B takes 30–90 seconds on Apple Silicon. See [[ai/hardware-requirements]].

**Responses are truncated** — the backend's context window is smaller than the
conversation. Raise `-c` on the server; the UI cannot override it.

## Where to go next

- [[ai/llama-swap]] — the backend that makes every model appear here at once
- [[ai/quickstart-macos]] — this as part of a complete stack
- [[ai/models]] — what to put behind it

<!-- uplink -->
Part of [[ai/index|Local LLMs]].
