---
title: "The Gateway API"
description: "The successor to Ingress — Gateways, HTTPRoutes, filters, weighted canary routing, and the permission model Ingress never had"
tags: [kubernetes, networking, gateway-api, ingress]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/gateway-api.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# The Gateway API

Kubernetes has exposed containers in several generations. First came `Service`
of type `LoadBalancer`. HTTP services needed more — content-based routing, TLS
termination, middlewares like authentication — which brought the `Ingress`
resource (v1beta1 in Kubernetes 1.8, 2017; GA in 1.19, 2020).

Ingress supports routing on the URI and the `Host:` header, and TLS
termination (with neat cert-manager integration). It does **not** support
routing on other headers or cookies, middlewares, or traffic splitting for
canary deployments. So virtually every controller grew proprietary extensions
— NGINX's `configuration-snippet` annotation, Traefik's `IngressRoute` /
`Middleware` CRDs, HAProxy's `Backend` CRDs — none portable
(see [[kubernetes/networking/ingress#Ingress shortcomings]]).

The **Gateway API** is the fresh start:

- routes for HTTP, GRPC, TCP, TLS and UDP (as of October 2025, HTTP and GRPC
  are GA);
- a finer permission model — which namespaces may use which gateway;
- more features standardised as core: header routing, traffic weighing,
  request and response rewriting;
- a defined extension ladder — `Core` / `Extended` / `Implementation-specific`;
- usable for service meshes too.

Where Ingress informally had two personas (cluster admin, app developer), the
Gateway API [formally defines three][gateway-personas]: infrastructure
provider, cluster operator, application developer.

[gateway-personas]: https://gateway-api.sigs.k8s.io/concepts/roles-and-personas/

## The resources

![Diagram showing GatewayClass, Gateway, HTTPRoute, Service](https://gateway-api.sigs.k8s.io/images/resource-model.png)

| Resource | Role |
| --- | --- |
| `GatewayClass` | a type of Gateway; most controllers offer one |
| `Gateway` | how traffic enters — often materialised as a LoadBalancer Service |
| `HTTPRoute` | which requests go to which Service (the Ingress analogue) |
| `Service` | the good old Kubernetes service |

An `HTTPRoute`'s anatomy:

- `spec.parentRefs` — where requests come from: typically one `Gateway`,
  possibly several, or a `Service` for mesh use;
- `spec.hostnames` — which `Host:` headers it applies to;
- `spec.rules[].matches` — which requests (paths, headers...);
- `spec.rules[].filters` — optional transformations;
- `spec.rules[].backendRefs` — where requests go.

Minimal example:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: xyz
spec:
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: my-gateway
    namespace: my-gateway-namespace
  hostnames: [ xyz.example.com ]
  rules:
  - backendRefs:
    - name: xyz
      port: 80
```

## Gateway API in action

Deploy Traefik in Gateway API mode with the
[official Helm chart][traefik-chart]. Two values matter:
`providers.kubernetesGateway.enabled=true` turns on Gateway API provisioning,
and `gateway.listeners.web.namespacePolicy.from=All` lets HTTPRoutes in all
namespaces use the default Gateway.

[traefik-chart]: https://artifacthub.io/packages/helm/traefik/traefik

On a managed cluster, use the chart's defaults (Deployment + LoadBalancer
Service, connect to its public IP):

```bash
helm upgrade --install --namespace traefik --create-namespace \
  --repo https://traefik.github.io/charts traefik traefik \
  --version 37.1.2 \
  --set providers.kubernetesGateway.enabled=true \
  --set gateway.listeners.web.namespacePolicy.from=All \
  #
kubectl get services --namespace traefik
```

Without a CCM or LoadBalancer Services, run it as a DaemonSet on the node
ports instead, and connect to any node's address (the same trade-offs as in
[[kubernetes/networking/ingress-setup]]):

```bash
helm upgrade --install --namespace traefik --create-namespace \
  --repo https://traefik.github.io/charts traefik traefik \
  --version 37.1.2 \
  --set deployment.kind=DaemonSet \
  --set ports.web.hostPort=80 \
  --set ports.websecure.hostPort=443 \
  --set service.type=ClusterIP \
  --set providers.kubernetesGateway.enabled=true \
  --set gateway.listeners.web.namespacePolicy.from=All \
  #
```

> [!note]- Two DaemonSet gotchas
> Traefik pods respect node taints: running on tainted control plane nodes
> needs tolerations (taints-and-tolerations). And two
> pods cannot share one `hostPort` on a node, so mind the DaemonSet rolling
> update parameters: with `maxUnavailable` non-zero, old pods stop first and
> there is a short interruption; with `maxSurge` non-zero, the new pods cannot
> start at all and the rollout wedges.

> [!example] Hands-on
> - Send a test request — `curl http://<ipaddress>` answers `404 not found`
>   while no route exists.
> - Create a backend and a route for it:
>   ```bash
>   kubectl create deployment blue --image jpetazzo/color --port 80
>   kubectl expose deployment blue
>   ```
>   ```yaml
>   apiVersion: gateway.networking.k8s.io/v1
>   kind: HTTPRoute
>   metadata:
>     name: blue
>   spec:
>     parentRefs:
>     - group: gateway.networking.k8s.io
>       kind: Gateway
>       name: traefik-gateway
>       namespace: traefik
>     rules:
>     - backendRefs:
>       - name: blue
>         port: 80
>   ```
> - The same `curl` now shows a response from the `blue` pod.

> [!note]- The Traefik dashboard
> ```bash
> kubectl port-forward --namespace traefik daemonset/traefik 1234:8080
> ```
> (or `deployment/traefik`), then `http://localhost:1234/dashboard/` — with the
> final `/`.

## Core, Extended, Implementation-specific

Every Gateway controller must support **Core** features. **Extended** features
are optional, but at least their specification is part of the API.
**Implementation-specific** features are proprietary extensions, now clearly
labelled as such.

### Matches

```yaml
match:
  path:                   # Core
    value: /hello
    type: PathPrefix      # default value; can also be "Exact"
  headers:                # Core
  - name: x-custom-header
    value: foo
  queryparams:            # Extended
  - type: Exact           # can also have implementation-specific values, e.g. Regex
    name: product
    value: pizza
  method: GET             # Extended
```

### Header modifiers

`RequestHeaderModifier` is Core; `ResponseHeaderModifier` is Extended:

```yaml
type: RequestHeaderModifier       # or ResponseHeaderModifier
requestHeaderModifier:            # or responseHeaderModifier
  set:                            # replace an existing header
  - name: x-my-header
    value: hello
  add:                            # appends to an existing header
  - name: x-my-header             # (adding a comma if it's already set)
    value: hello
  remove:
  - x-my-header
```

### Redirects and rewrites

```yaml
type: RequestRedirect
requestRedirect:
  scheme: https                     # http or https
  hostname: newxyz.example.com
  path: /new
  port: 8080
  statusCode: 302                   # default=302; can be 301 302 303 307 308
```

All fields optional; empty means "leave as is". `RequestRedirect` is Core, but
some of its options are Extended — see [the spec][http-request-redirect].

```yaml
type: URLRewrite
urlRewrite:
  hostname: newxyz.example.com      # rewrites the HTTP Host: header
  path: /new
```

`URLRewrite` is Extended, and conflicts with `RequestRedirect`.

[http-request-redirect]: https://gateway-api.sigs.k8s.io/reference/spec/#httprequestredirectfilter

### Mirroring

`RequestMirror` (Extended) copies all or a fraction of requests to another
backend, ignoring its responses — handy for shadow testing:

```yaml
type: RequestMirror
requestMirror:
  percent: 10
  backendRef:
    name: log-some-requests
    port: 80
```

Specify `percent` or `fraction`, not both; neither means "mirror everything".

## Weighted backends: canary without annotations

Traffic weighing is standard — this is what Ingress could never do portably
(see [[kubernetes/networking/ingress-canary]]):

```yaml
rules:
- backendRefs:
  - {name: web-stable, port: 80, weight: 99}
  - {name: web-canary, port: 80, weight: 1}
```

## Other routes

- `GRPCRoute` — routes on GRPC services and methods; ignore it if you do not
  use GRPC.
- `TLSRoute` — routes on the SNI header **without decrypting**: several TLS
  services behind one address, end-to-end encrypted.
- `TCPRoute` — routes raw TCP: HTTP+HTTPS+SSH on one address.
- `UDPRoute` — ditto for UDP, e.g. DNS variants.

## Guardrails: `allowedRoutes`

With Ingress, *any* resource can catch traffic — a staging namespace can
accidentally (or maliciously) claim a production hostname. A `Gateway` says
who may bind to it: routes from all namespaces, from its own namespace only,
or from namespaces matching a selector. That is what
`gateway.listeners.web.namespacePolicy.from=All` opted into above.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/gateway-api.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/gateway-api.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, rewritten
> as prose, remark markup converted to Obsidian callouts, a weighted-backends
> example added, referenced files inlined or linked.

<!-- uplink -->
Part of [[kubernetes/networking/index|Networking]].
