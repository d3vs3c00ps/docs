---
title: "Exercise — deploying on Kubernetes"
description: "Exercise: deploy the three-tier wordsmith app with kubectl create deployment and kubectl expose"
tags: [kubernetes, kubectl]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/exercise-wordsmith.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Exercise — deploying on Kubernetes

Let's deploy the wordsmith app on Kubernetes. As a reminder, it has these components:

| Name  | Image                           | Port |
|-------|---------------------------------|------|
| db    | jpetazzo/wordsmith-db:latest    | 5432 |
| web   | jpetazzo/wordsmith-web:latest   | 80   |
| words | jpetazzo/wordsmith-words:latest | 8080 |

`web` must be reachable from outside the cluster.

Try it on your own first. The next section has hints.

> [!warning] amd64 only
> The three wordsmith images exist only for `linux/amd64`. An arm64 node (Apple
> silicon, Raspberry Pi, Graviton) still pulls them, but it can only run them if it
> emulates amd64. Docker Desktop does, so a kind cluster on a Mac runs them, slowly.
> Without emulation, the containers fail with `exec format error` and the Pods go into
> `CrashLoopBackOff`.

## Hints

Read them one at a time.

- For each component, we need a Deployment and a Service.
- `kubectl create deployment` creates a Deployment.
- `kubectl expose` creates a Service.
- A public service, like `web`, needs a special type, for example `NodePort`.

## Solution

```bash
kubectl create deployment db --image=jpetazzo/wordsmith-db:latest
kubectl create deployment web --image=jpetazzo/wordsmith-web:latest
kubectl create deployment words --image=jpetazzo/wordsmith-words:latest
kubectl expose deployment db --port=5432
kubectl expose deployment words --port=8080
kubectl expose deployment web --port=80 --type=NodePort
kubectl get service web
```

Connect to the port shown after `80:` on any node's IP address. The page shows a
sentence; each word comes from the `words` API, which reads them from `db`.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/exercise-wordsmith.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/exercise-wordsmith.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> A solution and a note on the amd64-only images were added.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
