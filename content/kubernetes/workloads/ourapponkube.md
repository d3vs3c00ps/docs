---
title: "Running our application on Kubernetes"
description: "Deploying DockerCoins with kubectl create deployment and kubectl expose, then reaching its web UI through a NodePort"
tags: [kubernetes, kubectl]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/ourapponkube.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Running our application on Kubernetes

We can now deploy our code, and a Redis instance. We use the images published on the
Docker Hub as `dockercoins/<component>:v0.1`.

> [!example] Hands-on
> - Deploy `redis`:
>   ```bash
>   kubectl create deployment redis --image=redis
>   ```
>
> - Deploy everything else:
>   ```bash
>   kubectl create deployment hasher --image=dockercoins/hasher:v0.1
>   kubectl create deployment rng --image=dockercoins/rng:v0.1
>   kubectl create deployment webui --image=dockercoins/webui:v0.1
>   kubectl create deployment worker --image=dockercoins/worker:v0.1
>   ```

> [!note]- Extra details
> ## Deploying other images
>
> To deploy images from another registry, or with another tag, use a loop:
>
> ```bash
>   REGISTRY=dockercoins
>   TAG=v0.1
>   for SERVICE in hasher rng webui worker; do
>     kubectl create deployment $SERVICE --image=$REGISTRY/$SERVICE:$TAG
>   done
> ```

## Is this working?

Wait for the Deployments to be ready, then look at the logs. Use `kubectl get deploy -w`
to watch the Deployments change.

> [!example] Hands-on
> - Look at some logs:
>   ```bash
>   kubectl logs deploy/rng
>   kubectl logs deploy/worker
>   ```

`rng` is fine, but `worker` is not: it logs errors because it cannot resolve the
name `redis`. We forgot to `expose` the Deployments, so there is no Service and no
DNS name for them.

## Connecting containers together

Three Deployments must be reachable by the others: `hasher`, `redis` and `rng`.
`worker` does not need to be exposed: nothing connects to it. We deal with `webui`
later.

> [!example] Hands-on
> - Expose each deployment, specifying the right port:
>   ```bash
>   kubectl expose deployment redis --port 6379
>   kubectl expose deployment rng --port 80
>   kubectl expose deployment hasher --port 80
>   ```

## Is this working yet?

The `worker` runs an infinite loop. After an error, it waits 10 seconds and tries
again.

> [!example] Hands-on
> - Stream the worker's logs:
>   ```bash
>   kubectl logs deploy/worker --follow
>   ```
>
>   Give it about 10 seconds to recover. Press Ctrl-C to stop.

The `worker` should now work: it logs `units of work done, updating hash counter`.

## Exposing services for external access

Now we want to access the web UI. We expose it with a `NodePort` Service.

> [!example] Hands-on
> - Create a `NodePort` service for the Web UI:
>   ```bash
>   kubectl expose deploy/webui --type=NodePort --port=80
>   ```
>
> - Check the port that was allocated:
>   ```bash
>   kubectl get svc
>   ```

The allocated port is in the 30000-32767 range by default.

## Accessing the web UI

We can now connect to *any node*, on the allocated node port, to view the web UI.

> [!example] Hands-on
> - Open the web UI in your browser (http://node-ip-address:3xxxx/)

It may take a little while to update. (The cause is often DNS.)

We are back to where we started when we ran DockerCoins with Compose on a single
node, but now on Kubernetes.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/ourapponkube.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/ourapponkube.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; the failure before `expose` is explained.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
