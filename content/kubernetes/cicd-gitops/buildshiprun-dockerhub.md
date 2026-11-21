---
title: "Using images from the Docker Hub"
description: "For everyone's convenience, we took care of building DockerCoins images"
tags: [kubernetes, cicd, gitops]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/buildshiprun-dockerhub.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Using images from the Docker Hub

## Using images from the Docker Hub

- For everyone's convenience, we took care of building DockerCoins images

- We pushed these images to the DockerHub, under the [dockercoins](https://hub.docker.com/u/dockercoins) user

- These images are *tagged* with a version number, `v0.1`

- The full image names are therefore:

  - `dockercoins/hasher:v0.1`

  - `dockercoins/rng:v0.1`

  - `dockercoins/webui:v0.1`

  - `dockercoins/worker:v0.1`

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/buildshiprun-dockerhub.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/buildshiprun-dockerhub.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.

<!-- uplink -->
Part of [[kubernetes/cicd-gitops/index|CI/CD and GitOps]].
