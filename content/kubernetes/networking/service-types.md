---
title: "Service types"
description: "ClusterIP, NodePort, LoadBalancer, ExternalName — plus headless services, endpoints and traffic policies"
tags: [kubernetes, networking, services]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/service-types.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Service types

A Service gives a stable address to a set of pods. There are four types:
`ClusterIP`, `NodePort`, `LoadBalancer` and `ExternalName`. On top of that, a
Service can be *headless*, can carry *external IPs*, and HTTP traffic has its own
resource type, [[kubernetes/networking/ingress|Ingress]].

| Type | Reachable from | Use for |
| --- | --- | --- |
| `ClusterIP` | inside the cluster only | internal communication (the default) |
| `NodePort` | any node's IP, on a high port | external traffic without a load balancer |
| `LoadBalancer` | an external load balancer | external traffic on cloud or with an LB add-on |
| `ExternalName` | — (DNS alias only) | pointing a cluster name at an outside service |

## `ClusterIP`

The default type. Kubernetes allocates a virtual IP address in an internal, private
range (for example 10.96.0.0/12). That address is reachable only from within the
cluster — nodes and pods. Clients connect to the service's port number, unchanged.

![kubernetes services 11 CIP by addr](kubernetes/_attachments/kubernetes-services-11-CIP-by-addr.png)

![kubernetes services 12 CIP by name](kubernetes/_attachments/kubernetes-services-12-CIP-by-name.png)

![kubernetes services 13 CIP both](kubernetes/_attachments/kubernetes-services-13-CIP-both.png)

![kubernetes services 14 CIP headless](kubernetes/_attachments/kubernetes-services-14-CIP-headless.png)

## `LoadBalancer`

Kubernetes asks the infrastructure for an external load balancer — typically a cloud
one, like ELB on AWS or GLB on GCE. The type only works when the platform provides
"load balancer as a service", or with an add-on like [MetalLB] on bare metal
(on kind, [[kubernetes/cluster-setup/kind-in-practice#LoadBalancer, Ingress and Gateway API with cloud-provider-kind|cloud-provider-kind]]
plays that role).

Each `LoadBalancer` service typically costs money (a few cents per hour on AWS or
GCE). Ideally traffic would flow from the load balancer straight to the pods; in
practice it often flows through a `NodePort` first.

[MetalLB]: https://metallb.io/

![kubernetes services 31 LB no service](kubernetes/_attachments/kubernetes-services-31-LB-no-service.png)

![kubernetes services 32 LB plus cip](kubernetes/_attachments/kubernetes-services-32-LB-plus-cip.png)

![kubernetes services 33 LB plus lb](kubernetes/_attachments/kubernetes-services-33-LB-plus-lb.png)

![kubernetes services 34 LB internal traffic](kubernetes/_attachments/kubernetes-services-34-LB-internal-traffic.png)

![kubernetes services 35 LB pending](kubernetes/_attachments/kubernetes-services-35-LB-pending.png)

![kubernetes services 36 LB ccm](kubernetes/_attachments/kubernetes-services-36-LB-ccm.png)

![kubernetes services 37 LB externalip](kubernetes/_attachments/kubernetes-services-37-LB-externalip.png)

![kubernetes services 38 LB external traffic](kubernetes/_attachments/kubernetes-services-38-LB-external-traffic.png)

![kubernetes services 39 LB all traffic](kubernetes/_attachments/kubernetes-services-39-LB-all-traffic.png)

## `NodePort`

Kubernetes allocates a port number for the service, by default in the 30000-32767
range. That port is opened **on every node**, and anybody who can reach a node can
connect to it. Clients must be changed to use that port number.

Under the hood, `kube-proxy` sets up forwarding rules on the nodes — with
`iptables`, `ipvs` or `nftables`, depending on its mode (see
[[kubernetes/networking/kubenet]]).

`NodePort` is the useful option for external traffic when `LoadBalancer` services
are not available — for example on clusters deployed on-premises with kubeadm.

![kubernetes services 41 NP why](kubernetes/_attachments/kubernetes-services-41-NP-why.png)

![kubernetes services 42 NP how 1](kubernetes/_attachments/kubernetes-services-42-NP-how-1.png)

![kubernetes services 43 NP how 2](kubernetes/_attachments/kubernetes-services-43-NP-how-2.png)

![kubernetes services 44 NP how 3](kubernetes/_attachments/kubernetes-services-44-NP-how-3.png)

![kubernetes services 45 NP how 4](kubernetes/_attachments/kubernetes-services-45-NP-how-4.png)

![kubernetes services 46 NP how 5](kubernetes/_attachments/kubernetes-services-46-NP-how-5.png)

![kubernetes services 47 NP only](kubernetes/_attachments/kubernetes-services-47-NP-only.png)

## `ExternalName`

An `ExternalName` service is different from the other three: no load balancer,
internal or external, is created. Kubernetes only adds a DNS entry — a `CNAME` to
the name you provide.

```bash
kubectl create service externalname k8s --external-name kubernetes.io
```

This creates a CNAME `k8s` pointing to `kubernetes.io`.

## External IPs

A service can also carry an explicit external IP:

```bash
kubectl expose deploy my-little-deploy --port=80 --external-ip=1.2.3.4
```

`1.2.3.4` should be the address of one of the nodes — or a virtual address (VIP)
shared by several nodes. Connections to `1.2.3.4:80` are sent to the service.
External IPs also show up on `LoadBalancer` services, added automatically by
whatever provisions the load balancer.

## Headless services

Sometimes you want to reach the pods of a scaled service directly:

- to save a little latency (typically under 1 ms),
- to connect on arbitrary ports instead of a few fixed ones,
- to use a protocol other than TCP or UDP,
- or to balance requests client-side.

A *headless* service does that. Set `clusterIP` to `None` (with
`--cluster-ip=None`, or in YAML). The service then has no virtual IP and no load
balancing: CoreDNS returns the pods' addresses as multiple `A` records. That is an
easy way to discover all the replicas of a deployment, and it is how
[[kubernetes/storage/statefulsets|StatefulSets]] give each pod a stable DNS name.

## Services and endpoints

A service maintains a list of *endpoints* — the `host:port` pairs where it is
available, one per ready pod. Kubernetes updates the list automatically.

> [!example] Hands-on
> - Create a deployment with a service, and look at its endpoints:
>   ```bash
>   kubectl create deployment blue --image=jpetazzo/color --replicas=3
>   kubectl expose deployment blue --port=80 --target-port=80
>   kubectl describe service blue
>   ```

In the output, the `Endpoints:` line lists addresses in `host:port` format. They
match the pod addresses shown by `kubectl get pods -l app=blue -o wide`.

> [!note] `Endpoints` is deprecated in favour of `EndpointSlice`
> The classic `Endpoints` object (`kubectl get endpoints`) is the only resource
> whose name cannot be singular — the type itself is a list, `type Endpoints
> struct`. It is **deprecated since Kubernetes 1.33**: large services overflow a
> single object. The replacement, `EndpointSlice`, splits the list into chunks:
>
> ```bash
> kubectl get endpointslices -l kubernetes.io/service-name=blue
> ```
>
> `kubectl describe service` keeps working either way; controllers and tooling
> should read EndpointSlices.

## `Ingress`

Ingresses are another resource type, specifically for HTTP services — not TCP or
UDP. They can handle TLS certificates and URL rewriting, and they require an
*Ingress controller* to function. See [[kubernetes/networking/ingress]].

![kubernetes services 61 ING](kubernetes/_attachments/kubernetes-services-61-ING.png)

![kubernetes services 62 ING path](kubernetes/_attachments/kubernetes-services-62-ING-path.png)

![kubernetes services 63 ING policy](kubernetes/_attachments/kubernetes-services-63-ING-policy.png)

![kubernetes services 64 ING nolocal](kubernetes/_attachments/kubernetes-services-64-ING-nolocal.png)

## Traffic engineering

By default, connections to a `ClusterIP` or `NodePort` are balanced across **all**
the backends of the service, which can add network hops and latency. Several
mechanisms remove that extra hop:

### `internalTrafficPolicy` / `externalTrafficPolicy`

They apply to `ClusterIP` and `NodePort` connections respectively, and take
`Cluster` or `Local`:

- `Cluster` (the default): balance across all backends.
- `Local`: balance only across backends **on the same node**. If the node has no
  local backend, **the connection fails** — the setting is a hard rule, not a
  preference.

`externalTrafficPolicy: Local` is common for Ingress controllers: it preserves the
client source IP and avoids a second hop.

### `spec.trafficDistribution`

[KEP-4444][kep4444] supersedes the older topology-aware routing annotation
(`service.kubernetes.io/topology-mode=Auto`, beta since 1.23, zone-based, and able
to confuse autoscaling):

- `PreferClose` — route to endpoints in the client's zone (stable since 1.33)
- `PreferSameZone` — the same, with a clearer name (beta since 1.34)
- `PreferSameNode` — route to endpoints on the client's node (beta since 1.34)

Unlike `Local`, these are preferences: with no matching endpoint, traffic falls
back to the others.

[kep4444]: https://github.com/kubernetes/enhancements/issues/4444

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/service-types.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/service-types.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, rewritten as
> prose, remark markup converted to Obsidian callouts, EndpointSlice deprecation
> added, referenced files inlined or linked.

<!-- uplink -->
Part of [[kubernetes/networking/index|Networking]].
