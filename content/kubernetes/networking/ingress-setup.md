---
title: "Setting up an Ingress Controller"
description: "Installing Traefik with Helm — LoadBalancer, hostPort, hostNetwork and dev-cluster strategies, plus the dashboard"
tags: [kubernetes, networking, ingress, traefik, helm]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/ingress-setup.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Setting up an Ingress Controller

We install **Traefik** here — an arbitrary choice, but it has a helpful
dashboard for troubleshooting, and its releases are named after tasty cheeses.
We install it with the official **Helm chart** — also arbitrary, but
straightforward, and a chart fits easily into Flux, ArgoCD or
Terraform/OpenTofu later.

What varies is how inbound traffic reaches the controller. Five scenarios:

| Scenario | Controller runs as | Exposed by | When |
| --- | --- | --- | --- |
| 1. `LoadBalancer` | Deployment (2+ replicas) | a LoadBalancer Service | cloud, or MetalLB / kube-vip on-premises — the charts' default |
| 2. `hostPort` | DaemonSet | direct port mapping on each node | no LoadBalancer, but nodes have public IPs |
| 3. `hostNetwork` | DaemonSet | the node's own network stack | like hostPort, a bit less secure |
| 4. `externalIPs` | — | manually assigned Service IPs | exotic; how MetalLB / kube-vip work underneath |
| 5. local dev | Deployment | `kubectl port-forward` or port mappings | kind, minikube and friends |

Details worth keeping in mind:

- **hostPort** maps, say, port 80 on the node to port 8080 in the pod, and can
  shorten the path to the application pods. A `nodeSelector` can restrict the
  DaemonSet to specific nodes.
- **hostNetwork** lets the pod bind any node port; binding below 1024 needs
  root or `NET_BIND_SERVICE`. That breadth is exactly why it is less secure.
- **[externalIPs]** can be set manually on any Service, even ClusterIP; nodes
  then forward matching traffic to the pods. You manage the IP pool yourself,
  and you still need network engineering to bring the traffic to the nodes.
- **Local dev clusters** rarely have LoadBalancer Services, and their nodes may
  not be reachable; `kubectl port-forward` always works, and
  [kind's `extraPortMappings`][kind-extraportmappings] can map a local port
  (see [[kubernetes/cluster-setup/kind-in-practice#Port mappings]]).

[externalIPs]: https://kubernetes.io/docs/concepts/services-networking/service/#external-ips
[kind-extraportmappings]: https://kind.sigs.k8s.io/docs/user/configuration/#extra-port-mappings

> [!note]- Why not a NodePort Service?
> Node ports live in the 30000-32767 range, and web site users will not type
> `https://blahblah.whatever:31550`. An Ingress controller needs to answer on
> the real ports 80 and 443.

## Installing Traefik with a `LoadBalancer`

The [official chart](https://artifacthub.io/packages/helm/traefik/traefik)
works out of the box when the cluster supports LoadBalancer Services:

> [!example] Hands-on
> - Install the Traefik Helm chart:
>   ```bash
>   helm upgrade --install --repo https://traefik.github.io/charts \
>        traefik traefik --namespace traefik --create-namespace \
>        --version 37.4.0
>   ```
> - Retrieve the `EXTERNAL-IP` allocated to the Service, and send a test
>   request — it should answer `404 not found`:
>   ```bash
>   kubectl get services --namespace=traefik
>   curl http://<EXTERNAL-IP>
>   ```

The `EXTERNAL-IP` may show `<Pending>` for a little while; try again a few
seconds later. To script the wait:

```bash
kubectl wait service traefik --namespace=traefik \
        --for=jsonpath=.status.loadBalancer.ingress
kubectl get service traefik --namespace=traefik \
        -o jsonpath={.status.loadBalancer.ingress[0].ip}
```

On some providers (AWS), use `.hostname` instead of `.ip`; and there can be
several addresses — this returns the first.

> [!note]- Make it production-ready
> For availability: at least 2 replicas, a `podAntiAffinity` so they do not
> share a node, a PodDisruptionBudget for planned maintenance, and resource
> requests and limits. For visibility: scrape Traefik's metrics (Prometheus)
> and alert on them (e.g. [stakater/IngressMonitorController]).
>
> [stakater/IngressMonitorController]: https://github.com/stakater/IngressMonitorController

## Installing Traefik with a `DaemonSet` + `hostPort`

The plan: one Traefik pod per node, exposed on the node's ports 80 and 443 —
no LoadBalancer Service. Reading the chart's [default values] and
[values schema] gives the knobs:

- `deployment.kind=DaemonSet` — the chart's `deployment:` block switches
  between Deployment and DaemonSet;
- `ports.web.hostPort=80` and `ports.websecure.hostPort=443`;
- `service.type=ClusterIP` (or `service.enabled=false`) — the default
  LoadBalancer Service is no longer needed; either option is fine.

[default values]: https://artifacthub.io/packages/helm/traefik/traefik?modal=values
[values schema]: https://artifacthub.io/packages/helm/traefik/traefik?modal=values-schema

A Traefik **entrypoint** is simply an open port. Common configurations have
three: `web` (HTTP), `websecure` (HTTPS) and `traefik` (dashboard and API).
Traefik entrypoints have nothing to do with `ENTRYPOINT` in a Dockerfile.

> [!example] Hands-on
> - Install Traefik with all the options (a `--values` file would work too):
>   ```bash
>   helm upgrade --install --repo https://traefik.github.io/charts \
>        traefik traefik --namespace traefik --create-namespace \
>        --set deployment.kind=DaemonSet \
>        --set ports.web.hostPort=80 \
>        --set ports.websecure.hostPort=443 \
>        --set service.type=ClusterIP \
>        --version 37.4.0
>   ```
> - Send a test request to **any** node of the cluster — a `404 not found`
>   means Traefik answered:
>   ```bash
>   curl http://<node address>
>   ```

> [!note]- Control plane nodes
> On-premises clusters often dedicate control plane nodes to the control plane,
> with a taint keeping normal workloads off. `kubectl get pods -n traefik -o wide`
> will show Traefik avoiding them. To run it there anyway, give it the matching
> toleration:
> ```bash
> kubectl get nodes -o custom-columns=NAME:metadata.name,TAINTS:spec.taints
> ```
> ```bash
> --set tolerations[0].key=node-role.kubernetes.io/control-plane \
> --set tolerations[0].effect=NoSchedule
> ```
> As options pile up, a values YAML file becomes the more convenient form. See
> taints-and-tolerations.

## What about local dev clusters?

Install the normal (LoadBalancer) way, then port-forward:

```bash
kubectl port-forward --namespace=traefik service/traefik 8888:80
```

Connect to `http://localhost:8888` — a Traefik `404 not found`. Whenever a lab
says "the IP address of the Ingress controller", use `localhost:8888`, port
included. (kind can also map ports with `extraPortMappings`, but the
port-forward works everywhere.)

## The Traefik dashboard

Three things must line up: the dashboard feature enabled in Traefik (the chart
does that by default), a route inside Traefik exposing it
(`--set ingressRoute.dashboard.enabled=true`), and a connection to the internal
`traefik` entrypoint on port 8080:

```bash
kubectl port-forward --namespace=traefik deployment/traefik 1234:8080
kubectl port-forward --namespace=traefik daemonset/traefik 1234:8080
```

(whichever matches how Traefik runs), then open
`http://localhost:1234/dashboard/` — **with** the trailing slash.

> [!warning] No authentication by default
> The dashboard is only on the internal entrypoint, but it is unauthenticated.
> Add authentication, or a [[kubernetes/networking/netpol|NetworkPolicy]], before
> leaving it enabled anywhere that matters.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/ingress-setup.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/ingress-setup.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, rewritten
> as prose, remark markup converted to Obsidian callouts, referenced files
> inlined or linked.

<!-- uplink -->
Part of [[kubernetes/networking/index|Networking]].
