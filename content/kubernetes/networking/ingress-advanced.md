---
title: "Optimizing request flow"
description: "Cutting hops between client and pod — traffic policies, DaemonSet controllers, and getting the real client IP through the stack"
tags: [kubernetes, networking, ingress]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/ingress-advanced.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Optimizing request flow

With most Ingress controllers, a request follows this path:

```text
HTTP client → load balancer → NodePort → ingress controller Pod → app Pod
```

Some of these components may share a machine (the controller pod and the app
pod, say) — but each arrow is a potential hop between machines, and each hop
adds latency.

![kubernetes services 61 ING](kubernetes/_attachments/kubernetes-services-61-ING.png)

![kubernetes services 62 ING path](kubernetes/_attachments/kubernetes-services-62-ING-path.png)

## External traffic policy

`spec.externalTrafficPolicy` on the Service takes `Cluster` (the default:
balance to all pods) or `Local` (only pods on the node that received the
connection). With `Local`, one hop disappears — the NodePort no longer bounces
to a controller pod on another node:

```text
HTTP client → load balancer → [NodePort + ingress controller Pod, same node] → app Pod
```

![kubernetes services 63 ING policy](kubernetes/_attachments/kubernetes-services-63-ING-policy.png)

What if the node has **no** matching pod? The connection is refused. That is
detectable from outside, and external load balancers use it as a health check:
nodes without a controller pod are taken out of rotation.

![kubernetes services 64 ING nolocal](kubernetes/_attachments/kubernetes-services-64-ING-nolocal.png)

> [!note] `internalTrafficPolicy`
> Since Kubernetes 1.21 the same idea exists for internal traffic,
> `spec.internalTrafficPolicy` — **stable since 1.26** (the upstream slide
> still called it alpha). See the
> [documentation](https://kubernetes.io/docs/concepts/services-networking/service-traffic-policy/)
> and [[kubernetes/networking/service-types#Traffic engineering]].

## Other ways to save hops

- Run the controller as a **DaemonSet on port 80** of every node:
  `client → load balancer → controller on node → app Pod`.
- Go further: point DNS records straight at the nodes:
  `client → controller on node → app Pod`.
- Or run a combined load balancer / ingress controller at the edge:
  `client → edge controller → app Pod`.

## Source IP address

Getting the real client IP to the app takes two steps: the controller must
learn it, and the controller must pass it on. The second step is routine —
controllers inject a header, typically `X-Forwarded-For`, out of the box. The
first step depends on the topology:

1. **Direct connection** — client talks straight to the controller (edge
   controller, or DaemonSet on port 80): the controller sees the client, easy.
2. **External load balancer in TCP mode** — the controller sees the **load
   balancer's** address instead. Many load balancers support the
   [Proxy Protocol](https://www.haproxy.com/blog/haproxy/proxy-protocol/),
   which carries the original address — enable it **on both ends**.
3. **`externalTrafficPolicy: Local`** — when the load balancer preserves
   client addresses, `Local` lets the controller see them. With `Cluster`, the
   address survives sometimes and is rewritten when the connection bounces to
   another node. A big "it depends" — prefer the two other techniques.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/ingress-advanced.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/ingress-advanced.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, rewritten
> as prose, remark markup converted to Obsidian callouts, the
> internalTrafficPolicy maturity updated, referenced files inlined or linked.

<!-- uplink -->
Part of [[kubernetes/networking/index|Networking]].
