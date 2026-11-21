---
title: "MLOps hands-on sections"
description: "Misattributed to Benjamin Franklin"
tags: [kubernetes, mlops]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/handson-mlops.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# MLOps hands-on sections

> [!note] Not tested locally
> A workshop introduction with no commands. The links were checked in November 2026.

*Tell me and I forget.*  
*Teach me and I remember.*  
*Involve me and I learn.*

Misattributed to Benjamin Franklin

[(Probably inspired by Chinese Confucian philosopher Xunzi)](https://www.barrypopik.com/index.php/new_york_city/entry/tell_me_and_i_forget_teach_me_and_i_may_remember_involve_me_and_i_will_lear/)

## Hands-on sections

- There will be *a lot* of examples and demos

- If you are attending a live workshop:

  - follow along with the demos, ask questions at any time

  - if you can, try to run some of the examples and demos in your environment

  - if things are going too fast, ask the trainer to slow down :)

- If you are watching a recording or only reading the slides:

  - it is **strongly** recommended to run **all** the examples and demos

  - take advantage of the fact that you can pause at any time

## If you're attending a live training or workshop

- Each person gets a private lab environment

- Your lab environments will be available for the duration of the workshop

  (check with your instructor to know exactly when they'll be shut down)

- Note that for budget reasons¹, your environment will be fairly modest

  - scenario 1: 4 nodes with 2 cores and 4 GB RAM ; no cluster autoscaling

  - scenario 2: 1 node with 4 cores and 8 GB RAM ; cluster autoscaling

*¹That cloud thing is mighty expensive*

## Running your own lab environment

- If you are following a self-paced course...

- Or watching a replay of a recorded course...

- ...You will need to set up a local environment for the labs

  *or*

- If you want to use a specific cloud provider...

- Or want to see these concepts "at scale"...

- ...You can set up your own clusters with whatever capacity suits you

## Deploying your own Kubernetes cluster

- You need cloud provider credentials for this

- Option 1: use the cloud provider CLI, web UI, ...

- Option 2: use [one of these Terraform configurations][one-kubernetes]

  (set `cluster_name`, `node_size`, `max_nodes_per_pool`, `location`, and GO!)

[one-kubernetes]: https://github.com/jpetazzo/container.training/tree/main/prepare-labs/terraform/one-kubernetes

## Deploying many Kubernetes clusters

- If you want to deliver your own training or workshop:

  - deployment scripts are available in the [prepare-labs] directory

  - you can use them to automatically deploy many lab environments

  - they support many different infrastructure providers

  - they can deploy dozens (even hundreds) of clusters at a time

[prepare-labs]: https://github.com/jpetazzo/container.training/tree/main/prepare-labs

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/handson-mlops.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/handson-mlops.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.

<!-- uplink -->
Part of [[kubernetes/mlops/index|MLOps]].
