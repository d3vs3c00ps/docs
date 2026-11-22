---
title: "Accessing internal services"
description: "Reaching a ClusterIP service from your machine without exposing it — kubectl proxy for HTTP, kubectl port-forward for any TCP"
tags: [kubernetes, networking, kubectl]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/accessinternal.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Accessing internal services

Logged in on a cluster node, you can reach every internal service — the
[[kubernetes/networking/kubenet|network model]] guarantees that nodes reach all
pods and services. From your own machine, talking to a remote cluster, you
cannot: your machine has no route into the cluster's internal subnets.

Two kubectl commands give temporary access without exposing anything to everyone:

- `kubectl proxy` — access to the API, which includes a proxy for HTTP resources;
- `kubectl port-forward` — a TCP relay to an arbitrary pod, service or
  deployment.

Both work anywhere kubectl works. Run from a node they are less interesting (the
node could reach the service directly), but the commands are the same.

## `kubectl proxy`

`kubectl proxy` serves the entire Kubernetes API on `localhost:8001`,
authenticated with your kubeconfig credentials. The API includes routes that
proxy HTTP traffic to services and pods:

```text
/api/v1/namespaces/<namespace>/services/<service>/proxy/<uri>
```

Append the request URI to the end — `.../services/webui/proxy/index.html`.

> [!example] Hands-on
> - Run an API proxy in the background, use it, and stop it:
>   ```bash
>   kubectl proxy &
>   curl localhost:8001/api/v1/namespaces/default/services/webui/proxy/index.html
>   kill %1
>   ```

## `kubectl port-forward`

For a TCP service that is not HTTP, use a port forward instead:

```text
kubectl port-forward service/<name> <local_port>:<remote_port>
```

With a single port number, it is used on both sides.

> [!example] Hands-on
> - Forward local port 10000 to a Redis server's port 6379, and talk to it:
>   ```bash
>   kubectl port-forward svc/redis 10000:6379 &
>   redis-cli -p 10000 INFO server
>   kill %1
>   ```

> [!note] Correction
> The original connected with `telnet localhost 10000` and typed `INFO server`
> by hand. Modern Redis answers `telnet` probes poorly and few machines still
> ship telnet; `redis-cli -p` (or `nc`) does the same job scriptably.

> [!tip] Port-forwards bypass network policies
> Both commands tunnel through the API server, so they work even where
> [[kubernetes/networking/netpol|network policies]] block direct traffic —
> convenient for debugging, and worth remembering in a security review.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/accessinternal.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/accessinternal.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, rewritten as
> prose, remark markup converted to Obsidian callouts, the telnet lab replaced
> with redis-cli, referenced files inlined or linked.

<!-- uplink -->
Part of [[kubernetes/networking/index|Networking]].
