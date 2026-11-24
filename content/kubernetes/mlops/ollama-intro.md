---
title: "Ollama in a nutshell"
description: "'Get up and running with large language models'"
tags: [kubernetes, mlops]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/ollama-intro.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Ollama in a nutshell

https://ollama.com

"Get up and running with large language models"

"Docker, but for LLMs"

- Server to host (run) LLMs

- Controlled with CLI or API

- Download a model with `ollama pull`

- Run inference with `ollama run`

## Quick demo

⚠️ **Important note 1:** the commands in this section aren't meant
to be executed on your Kubernetes clusters. They are meant to
be executed on a local machine, and they assume that Ollama is
installed and running. If you don't have Ollama on your local
machine, it's OK to skip these demos!

⚠️ **Important note 2:** the models used by Ollama are fairly big
(1.5 GB for the one used here; up to 10s or 100s of GB for bigger
models). We do not recommend downloading them on conference WiFi.

Assuming Ollama is installed and running:

```
ollama run qwen2:1.5b "What's the solution to global warming?"
```

We're going to use this model because it's relatively small.

Many others are available (see https://ollama.com/search).

## Other useful commands

- Start an interactive chat session:
  ```bash
  ollama run qwen2:1.5b
  ```

- Pull a model (or check for updates):
  ```bash
  ollama pull qwen2:1.5b
  ```

- See information on a model:
  ```bash
  ollama show qwen2:1.5b
  ```

## Models on disk, in memory

- See models available on disk:
  ```bash
  ollama list
  ```

- See models loaded in memory:
  ```bash
  ollama ps
  ```

- Unload a model:
  ```bash
  ollama stop qwen2:1.5b
  ```

Models are automatically unloaded after 5 minutes (by default).

Ollama loads models in RAM, and in VRAM if it detects a supported GPU.

# Ollama on Kubernetes

Let's run Ollama on our Kubernetes cluster!

- Option 1: `kubectl run`

- Option 2: create a Deployment and a Service

- Option 3: use a Helm chart

## 1️⃣ `kubectl run`

Note: the `ollama/ollama` image is quite big (~2 GB transfer, ~4 GB on disk).

```bash
kubectl run ollama --image ollama/ollama:0.40.6
```

(Pinned, not `latest`; this page was tested with 0.40.6.)

Wait for the pod to be up and running:
```bash
kubectl wait pod ollama --for=condition=Ready --timeout=10m
```

(If that command times out, try again and/or specify a higher timeout.)

```bash
kubectl exec ollama -- ollama run qwen2:1.5b "What's Bach's best piece?"
```

Shutdown the pod:
```bash
kubectl delete pod ollama
```

## 2️⃣ Deployment + Service

Create the Deployment:
```bash
kubectl create deployment ollama --image ollama/ollama:0.40.6
```

Create the Service:
```bash
kubectl create service clusterip ollama --tcp 11434
```

Wait for the Service Endpoints to be available:
```bash
kubectl wait endpoints ollama --for=jsonpath={..ip}
```

## By the way... Why port 11434?

| 1 | 1 | 4 | 3 | 4 |
|---|---|---|---|---|
| L | L | A | M | A |

## Connecting to the Service

Let's use the `/api/generate` endpoint:

```bash
kubectl run httpclient --rm -it --image alpine/httpie -- --ignore-stdin \
  http://ollama:11434/api/generate \
  model=qwen2:1.5b prompt="Write a limerick about Kubernetes"
```

(See [Ollama API docs](https://github.com/ollama/ollama/blob/main/docs/api.md#generate-a-completion) for details.)

🤔 We get an error: the model needs to be downloaded first.

💡 When we used the `ollama run` CLI command earlier, it did it automatically for us.

## Pulling the model

Method 1:
```bash
kubectl exec deployment/ollama -- ollama pull qwen2:1.5b
```

Method 2:
```bash
kubectl run httpclient --rm -it --image alpine/httpie -- --ignore-stdin \
  http://ollama:11434/api/pull \
  name=qwen2:1.5b
```

## Houston, we (are going to) have a problem...

- This works when there is only one pod

- What happens if we scale up the Deployment?

- We need to pull the model on every pod

- How should we do that?

## Potential solutions

- Bake the model into the image

  🙅 Personal opinion: this is a bad idea (image size, maintenance...)

- Directly send a "pull" command to each pod, individually

  🙁 Hackish, not great

- Use a Kubernetes lifecycle hook

  💡 That works!

- Use a sidecar container to pull the model

  🤔 Doable, but more work than the lifecycle hook

## 🙋 Choose your own adventure

Should we add that lifecycle hook?

## 3️⃣ Helm chart

- Let's check the [ArtifactHUB] for an Ollama Helm chart

- The most popular (as of November 2024) is [this one, by OTWLD][ollama-chart]

  (tested here with chart version 1.90.0)

- ~~It has pockets~~

- It can pre-pull models! 🎉

[ArtifactHub]: https://artifacthub.io
[ollama-chart]: https://artifacthub.io/packages/helm/ollama-helm/ollama

## Installing the Helm chart

Traditional method:
```bash
helm repo add ollama https://otwld.github.io/ollama-helm/
helm install ollama ollama/ollama --version 1.90.0 \
  --set 'ollama.models.pull={qwen2:1.5b}'
```

Idempotent¹, single-command method:
```bash
helm upgrade --install --repo https://otwld.github.io/ollama-helm/ \
  ollama ollama --version 1.90.0 --set 'ollama.models.pull={qwen2:1.5b}'
```

> [!note] `ollama.models.pull`
> In current versions of the chart, `ollama.models` holds `pull`, `run` and `create`
> lists: the models to pre-pull go in `ollama.models.pull`. The quotes stop the shell
> from expanding the braces.

*¹Idempotent: which can be executed multiple times without adverse effect.*

## Testing the Helm installation

Just like before:
```bash
kubectl run httpclient --rm -it --image alpine/httpie -- --ignore-stdin \
  http://ollama:11434/api/generate \
  model=qwen2:1.5b prompt="Write a limerick about YAML" stream:=false
```

And while we're here, check resource usage:
```bash
kubectl exec deployment/ollama -ti -- top
```

There should be two processes:

- `ollama` itself, relatively small (~50-100 MB)

- the LLM subprocess, relatively big (~1.2-1.4 GB for qwen2:1.5b). With Ollama 0.40
  it is `llama-server`, which `top` shortens to `llama-s+`

The subprocess only exists while a model is loaded: Ollama unloads it after 5 minutes
without requests.

> [!note]- Extra details
> ## HTTPie
>
> https://httpie.io/
>
> - CLI client to send requests to web services
>
> - Similar to curl, but made specifically to talk to API backends
>
> ```bash
> http <URL> [key=value] [key=value] [key:=value]
> ```
>
> (the command is `http`, or `https`; `alpine/httpie` runs it as its entrypoint)
>
> - The `key=value` pairs get turned into a JSON object
>
> - `key:=value` indicates a parameter to be sent "as-is"
>
>   (ideal for e.g. boolean or numbers)

## Sending some load

We're going to use `hey`:

```bash
kubectl run hey --rm -it --image nixery.dev/hey -- \
  hey -c 10 -n 10 -t 60 -m POST \
  -d '{"model": "qwen2:1.5b", "prompt": "vi or emacs?"}' \
  http://ollama:11434/api/generate
```

Some explanations:

- `nixery.dev` = automatically generates images with [Nixery]

  (these images are amd64 only; on arm64 nodes, use `nixery.dev/arm64/hey`)
- `-c` = concurrent requests
- `-n` = total number of requests
- `-t` = timeout in seconds

This is probably going to take (literally) a minute.

[Nixery]: https://nixery.dev/

## Performance analysis

- Let's start an interactive container with `hey`

  (e.g., use the `alpine` image, then `apk add hey`)

- Try 10 requests, with a concurrency of 1/2/4

- Meanwhile, check the logs of the `ollama` pod

- Some results (your results may vary depending on CPU, random seed...):

  - 1 = 0.08 reqs/s, average latency: 12s
  - 2 = 0.10 reqs/s, average latency: 18s
  - 4 = 0.12 reqs/s, average latency: 28s

- Higher concurrency = slightly higher throughput, much higher latency

🤔 We need metrics!

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/ollama-intro.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/ollama-intro.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> Service port and Helm values fixed, runner process name updated, versions pinned,
> tested on kind.

<!-- uplink -->
Part of [[kubernetes/mlops/index|MLOps]].
