---
title: "Ingress and canary releases"
description: "What a canary release is, a historical Traefik v1 weighted-routing example, and the Gateway API way to do it today"
tags: [kubernetes, networking, ingress, deployment]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/ingress-canary.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Ingress and canary releases

> [!note] Not tested locally
> The worked example below is deliberately historical — Traefik v1 annotations
> on an `extensions/v1beta1` Ingress, which no current cluster accepts. The
> current mechanism, Gateway API weighted routes, is covered and tested in
> [[kubernetes/networking/gateway-api]].

A **canary release** processes only a small fraction of the workload. After
deploying the canary, you compare its metrics to the normal release. If they
look good, the canary progressively receives more traffic, until it reaches
100% and becomes the new normal. If they do not, the canary is removed — and
only a tiny fraction of traffic ever saw the bad release.

The "fraction" can be sliced in different ways:

- **per request** — 1% of requests, sampled randomly, go to the canary (the
  microservice case, implemented below);
- **per user** — 1% of users are sent to the canary web site;
- **per unit of work** — 1% of orders ship with the canary process.

## The historical example: Traefik v1 weights

With Traefik v1, the canary was deployed and exposed as a separate Service;
the Ingress then listed several `paths` entries — one per Service — and an
annotation gave each one a weight (more than two services were allowed):

```yaml
apiVersion: networking.k8s.io/v1beta1
kind: Ingress
metadata:
  name: rgb
  annotations:
    traefik.ingress.kubernetes.io/service-weights: |
      red: 50%
      green: 25%
      blue: 25%
spec:
  rules:
  - host: rgb.A.B.C.D.nip.io
    http:
      paths:
      - path: /
        backend:
          serviceName: red
          servicePort: 80
      - path: /
        backend:
          serviceName: green
          servicePort: 80
      - path: /
        backend:
          serviceName: blue
          servicePort: 80
```

This illustrates the Ingress-era problem: every controller had its **own**
way. The NGINX controller wanted two Ingress resources with
`nginx.ingress.kubernetes.io/canary` annotations; Linkerd wanted an extra
aggregate Service plus a `TrafficSplit` CRD from the SMI spec. None of it was
portable.

## The current way: Gateway API weights

Weighted routing is a first-class, vendor-neutral feature of the
[[kubernetes/networking/gateway-api|Gateway API]] — no annotations:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web
spec:
  parentRefs: [{name: my-gateway}]
  rules:
  - backendRefs:
    - {name: web-stable, port: 80, weight: 99}
    - {name: web-canary, port: 80, weight: 1}
```

## Weights are only one building block

A real canary pipeline also needs:

- **metrics** (latency, error rate...) for both releases;
- **automation** moving the weights — up when the metrics look good, down
  otherwise;
- **lifecycle management** for the canaries — create, promote, delete.

For inspiration, look at [Flagger](https://github.com/weaveworks/flagger) or
[[kubernetes/cicd-gitops/argocd|Argo Rollouts]].

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/ingress-canary.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/ingress-canary.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, rewritten
> as prose, remark markup converted to Obsidian callouts, a Gateway API example
> added, referenced files inlined or linked.

<!-- uplink -->
Part of [[kubernetes/networking/index|Networking]].
