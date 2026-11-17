---
title: "Scaling a deployment"
description: "Scaling the DockerCoins worker Deployment with kubectl scale, and watching Pods and Deployments change"
tags: [kubernetes, kubectl]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kubectlscale.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Scaling a deployment

We start with an easy one: the `worker` Deployment of DockerCoins (see
[[kubernetes/workloads/ourapponkube]]).

> [!example] Hands-on
> - Open two new terminals to check what's going on with pods and deployments:
>   ```bash
>   kubectl get pods -w
>   kubectl get deployments -w
>   ```
>
> - Now, create more `worker` replicas:
>   ```bash
>   kubectl scale deploy/worker --replicas=10
>   ```

The first terminal shows the new Pods, from `Pending` to `ContainerCreating` to
`Running`. The second shows the `READY` count of the Deployment going up to `10/10`.

After a few seconds, the graph in the web UI goes up. It peaks at about 10
hashes/second, the same as when DockerCoins ran with Compose on a single machine.
[[kubernetes/workloads/scalingdockercoins]] explains why.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/kubectlscale.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kubectlscale.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose, with what the two watches show.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
