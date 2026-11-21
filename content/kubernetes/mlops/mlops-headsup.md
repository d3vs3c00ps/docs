---
title: "MLOps: scope and caveats"
description: "Kubernetes provides low-level building blocks (pods, deployments, services...)"
tags: [kubernetes, mlops]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/mlops-headsup.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# MLOps: scope and caveats

> [!note] Not tested locally
> A workshop introduction with no commands. The links were checked in November 2026.

## What we will / won't cover

- Kubernetes provides low-level building blocks (pods, deployments, services...)

- There are many high-level frameworks out there for serverless, AI...:

  [Knative](https://knative.dev/docs/),
  [KubeAI](https://www.kubeai.org/),
  [Kueue](https://kueue.sigs.k8s.io/)...

- We're going to sit somewhere in the middle:

  reimplement some of the features of these high-level frameworks, in a flexible way

- This workshop will (hopefully!) give you a better eye to evaluate these frameworks, too

- We won't showcase GPUs today for budget reasons

  (giving everyone a few GPU nodes would be prohibitive, sorry!)

## A word about our demo app

- We'll use Ollama with a relatively small LLM

  (qwen2:1.5b)

- We'll use it to generate very short completions

  (a few seconds of CPU)

- All the challenges that we will address are also visible on longer requests

  (in fact, they are even more visible on longer requests!)

- We're sticking to short requests to save time and cover a lot of ground today

  (but feel free to use more expensive prompts if you'd like!)

## Tiny bit of backstory...

The original prompt that we used when building the first version of this content was:

```
If you go to {city}, I suggest that you
```

This would typically take 10-30 seconds - and with much bigger Kubernetes nodes.

Today, we suggest that we use a prompt that generates shorter answers!

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/mlops-headsup.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/mlops-headsup.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.

<!-- uplink -->
Part of [[kubernetes/mlops/index|MLOps]].
