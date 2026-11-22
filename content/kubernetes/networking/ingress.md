---
title: "Exposing HTTP services with Ingress resources"
description: "Layer-7 routing on a single IP — Ingress controllers, exact and prefix rules, virtual hosting, and why Gateway API is the successor"
tags: [kubernetes, networking, ingress]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/ingress.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Exposing HTTP services with Ingress resources

> [!important] These labs expect the upstream repository
> Commands below reference files by their path in a local clone. Get it with:
>
> ```bash
> git clone https://github.com/jpetazzo/container.training
> ```
>
> The manifests can also be browsed at the pinned commit
> [`56563629`](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2).

A [[kubernetes/networking/service-types|Service]] works at layer 4: any TCP, UDP
or SCTP protocol, but it never looks inside HTTP. An **Ingress** works at layer
7: HTTP only, routing by URI or `Host:` header, and able to terminate TLS.

Typical reasons to use one:

- **URI routing** — `/api` to service `api:5000`, everything else to
  `static:80` (the single-page-app pattern);
- **cost** — one load balancer for many services, instead of one
  `LoadBalancer` service each;
- **TLS certificates** handled transparently, outside the app (see
  [[kubernetes/networking/ingress-tls]]).

| | `type: LoadBalancer` | Ingress |
| --- | --- | --- |
| Needs | a cloud controller or MetalLB | an Ingress controller |
| Protocols | any TCP | HTTP only |
| Content-based routing | no | yes (URI, host) |
| TLS | the app's problem | terminated for you |
| Cost | per service | shared |

## Ingress controllers

Ingress is an ordinary API resource (`kubectl get ingress` / `ingresses` /
`ing`) — but it does nothing without an **Ingress controller** watching it. You
can create resources all day; without a controller, nothing happens. Few
distributions install one by default, because controllers are not one size fits
all:

- based on existing load balancers: HAProxy, NGINX;
- standalone, often Kubernetes-native: Traefik, Contour;
- proprietary to a cloud or hardware vendor: GKE Ingress, AWS ALB.

There is no "default" or "official" controller.

To check whether a cluster has one: a modern controller registers an
IngressClass —

```bash
kubectl get ingressclasses
```

An IngressClass can also exist while its controller is broken or half
uninstalled, so treat it as a hint, not proof.

> [!note]- The proprietary controllers
> GKE's custom controller is enabled by default (and
> [does not use IngressClass][gke-ingressclass]); EKS's AWS ALB controller needs
> extra setup. Both drive cloud HTTP load balancers and typically cost money
> *per Ingress resource*, because they allocate one load balancer per resource —
> where most controllers create a single LoadBalancer Service and receive all
> HTTP traffic through it. Multiple rules per resource reduce that cost, at some
> management inconvenience.

[GKE Ingress]: https://cloud.google.com/kubernetes-engine/docs/concepts/ingress
[gke-ingressclass]: https://docs.cloud.google.com/kubernetes-engine/docs/concepts/ingress#deprecated_annotation

**Standard features**: load balancing, SSL termination, name-based virtual
hosting, URI routing. **Extended features** — header or cookie routing, A/B
testing, [[kubernetes/networking/ingress-canary|canary deployments]] — exist
but are controller-specific, through annotations or CRDs. Standardising them is
one of the goals of the [[kubernetes/networking/gateway-api|Gateway API]].

## Principle of operation

1. Deploy an Ingress controller — one-time setup, typically by the cluster
   admin (see [[kubernetes/networking/ingress-setup]]).
2. Create Ingress resources mapping a domain or path to a Service; the
   controller watches them and configures its load balancer.
3. Optionally, point DNS at the load balancer address — automatable with
   [[kubernetes/networking/externaldns|ExternalDNS]].

## Ingress in action

The labs below use Traefik, installed with the course's ready-made manifest: a
DaemonSet with `hostPort: 80` and a toleration for the control plane, so every
node answers on port 80. (That manifest suits lab clusters; for the production
options, see [[kubernetes/networking/ingress-setup]].)

> [!example] Hands-on
> - Install Traefik:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/traefik.yaml
>   ```

> [!note] Correction
> The upstream slides say `traefik.yml`, but the file in the repository is
> `traefik.yaml` — the slide command fails as written.

Then run a web app and expose it. `jpetazzo/color` is a static HTTP server on
port 80 that reports its pod name:

> [!example] Hands-on
> - Create a Deployment and a Service:
>   ```bash
>   kubectl create deployment blue --image=jpetazzo/color
>   kubectl expose deployment blue --port=80
>   ```
> - Create an Ingress with a single rule (`kubectl create ingress` exists since
>   Kubernetes 1.19):
>   ```bash
>   kubectl create ingress blue --rule=/blue=blue:80
>   ```

`/blue` is the HTTP path; `blue:80` is the Service name and port.

To test it, connect to the controller's address: with a DaemonSet and
`hostPort` (or `hostNetwork`), that is **any node's IP**; with a LoadBalancer
Service, the service's `EXTERNAL-IP`; on a local dev cluster,
`kubectl port-forward` and `localhost`. `http://<IP address>/blue` answers from
the `blue` deployment.

## Using domain names

Name-based virtual hosting serves many apps from one IP — one domain name each
(`blue.example.com`, `green.example.com`...). Without a real domain, [nip.io]
helps: `anything.1.2.3.4.nip.io` resolves to `1.2.3.4`. Below, `A.B.C.D` stands
for the Ingress controller's address — substitute it.

[nip.io]: https://nip.io/

> [!example] Hands-on
> - Before the Ingress exists, Traefik answers a terse `404 not found` — that is
>   expected:
>   ```bash
>   curl http://blue.A.B.C.D.nip.io
>   ```
> - Create an Ingress whose rule carries the domain, and test it:
>   ```bash
>   kubectl create ingress blue-with-domain --rule=blue.A.B.C.D.nip.io/=blue:80
>   curl http://blue.A.B.C.D.nip.io
>   ```

## Exact or prefix matches

By default, rules are **exact** matches — the request is routed only for the
specified URL:

> [!example] Hands-on
> - Only `/` routes to the app:
>   ```bash
>   curl http://blue.A.B.C.D.nip.io         # works
>   curl http://blue.A.B.C.D.nip.io/hello   # does not work
>   ```
> - A rule ending in `*` becomes a **prefix** match:
>   ```bash
>   kubectl create ingress blue-with-prefix --rule=blue.A.B.C.D.nip.io/*=blue:80
>   curl http://blue.A.B.C.D.nip.io/hello
>   ```

## What the manifests look like

`-o yaml --dry-run=client` shows the YAML that `kubectl create ingress`
generates — exact rule, domain rule, prefix rule, and several rules in one
resource:

> [!example] Hands-on
> ```bash
> kubectl create ingress -o yaml --dry-run=client \
>         exact-route --rule=/blue=blue:80
>
> kubectl create ingress -o yaml --dry-run=client \
>         with-a-domain --rule=blue.test/=blue:80
>
> kubectl create ingress -o yaml --dry-run=client \
>         now-with-a-prefix --rule=blue.test/*=blue:80
>
> kubectl create ingress -o yaml --dry-run=client rgb \
>         --rule=/red*=red:80 \
>         --rule=/green*=green:80 \
>         --rule=/blue*=blue:80
> ```

The difference between exact and prefix shows up as `pathType: Exact` versus
`pathType: Prefix`.

> [!note]- Multiple Ingress controllers at once
> Several controllers can be active simultaneously — Traefik and NGINX, or two
> instances of one controller for internal and external traffic. An Ingress
> picks its controller with the `ingressClassName` field (since Kubernetes
> 1.18), pointing at an IngressClass; before that, the
> `kubernetes.io/ingress.class` annotation did the job.

## Ingress shortcomings

Much was left out of the Ingress v1 spec: weight-based routing, cookies,
cross-namespace routing... Controllers fill the gaps with vendor-specific
annotations and CRDs, which makes migrations painful. Stripping a path prefix,
for example: NGINX uses
[`nginx.ingress.kubernetes.io/rewrite-target: /`](https://github.com/kubernetes/ingress-nginx/blob/main/docs/examples/rewrite/README.md),
Traefik v1 used an annotation, [Traefik v2+ requires a CRD](https://doc.traefik.io/traefik/migration/v1-to-v2/#strip-and-rewrite-path-prefixes).

## A word about Ingress NGINX

Two open-source controllers are based on NGINX, and the names are a trap:

- **F5 NGINX Ingress Controller** ("NGINX Ingress") — developed by F5, which
  acquired NGINX in 2019; vendor CRDs like
  [VirtualServer and VirtualServerRoute][f5-nginx-crds].
- **Ingress NGINX Controller** ("Ingress NGINX") — the community-developed
  pioneer, and for years the most deployed controller.
  **Retired: maintenance stops in March 2026** — see the
  [announcement][k8s-nginx-announcement].

[f5-nginx-crds]: https://docs.nginx.com/nginx-ingress-controller/configuration/virtualserver-and-virtualserverroute-resources/
[k8s-nginx-announcement]: https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/

From the retirement announcement: *"the project has had only one or two people
doing development work, on their own time, after work hours and on weekends."*
Worth asking about everything mission-critical you run: for open source — what
happens if the maintainers throw the towel? For commercial software — what if
the company folds, or changes its [pricing][vmware1] [structure][vmware2]?

[vmware1]: https://www.theregister.com/2025/05/22/euro_cloud_body_ecco_says_broadcom_licensing_unfair/
[vmware2]: https://www.ciodive.com/news/att-broadcom-vmware-price-hikes-court-battle/728603/

## Ingress in the future

The [Gateway API](https://gateway-api.sigs.k8s.io/) is the designated
successor: new resources (GatewayClass, Gateway, HTTPRoute, TCPRoute...), now
at feature parity with Ingress, usable instead of it or alongside it — at the
price of more setup complexity, at least for now. See
[[kubernetes/networking/gateway-api]].

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/ingress.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/ingress.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, rewritten
> as prose, remark markup converted to Obsidian callouts, referenced files
> inlined or linked.

<!-- uplink -->
Part of [[kubernetes/networking/index|Networking]].
