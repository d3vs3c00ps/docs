---
title: How Cilium works
description: The eBPF datapath, identity-based security, the routing and IPAM modes you have to choose between, and what replacing kube-proxy actually changes
tags: [kubernetes, networking, cilium, cni, ebpf]
type: concept
status: complete
---

# How Cilium works

Cilium is a CNI plugin that implements pod networking, load balancing and network
policy in **eBPF** programs attached to the kernel's network hooks, rather than in
iptables rules.

That single decision explains almost everything else about it: the identity model,
the kube-proxy replacement, the observability, and the troubleshooting commands you
end up needing.

For what a CNI plugin *is* and how kubelet finds one, see
[[kubernetes/networking/cni-internals]].

## Why eBPF instead of iptables

kube-proxy in iptables mode writes a rule chain per Service. Packet processing walks
that chain **linearly**, so cost grows with the number of Services, and every change
rewrites and reloads a large table.

eBPF programs are attached at the network driver hook (`tc`, or XDP on supported
NICs) and use **hash map lookups** instead of sequential matching. Service count
stops mattering, and updating one Service updates one map entry rather than
regenerating a ruleset.

| | iptables kube-proxy | Cilium eBPF |
| --- | --- | --- |
| Service lookup | Linear walk of rule chains | O(1) hash map |
| Update cost | Rewrite and reload the table | One map entry |
| Policy granularity | L3/L4 | L3/L4/L7 |
| Visibility | Counters | Per-flow events with identity |

## Identity, not IP addresses

This is the part that most changes how you reason about the cluster.

A standard `NetworkPolicy` is enforced by resolving pod selectors to IP addresses and
writing IP-based rules. Pods churn, so those rules churn with them, and at scale the
rule set never quite catches up.

Cilium instead assigns every unique set of security-relevant labels a numeric
**identity**, and enforces policy between identities:

```text
app=frontend,env=prod   ──►  identity 12345
app=backend,env=prod    ──►  identity 12346
```

Every packet carries its source identity in the datapath. Scaling a deployment from
3 to 300 pods creates **no new policy state** — all 300 share one identity. This is
why Cilium's policy enforcement cost is a function of the number of distinct label
sets, not the number of pods.

Identities are visible as cluster resources:

```bash
kubectl get ciliumidentities
kubectl get ciliumendpoints -A
```

Reserved identities cover traffic that has no pod labels — `host`, `remote-node`,
`world`, `kube-apiserver`. Seeing `world` in a Hubble flow means "outside the
cluster", and it is often the answer to "why did this get dropped".

## The datapath: routing modes

You must pick one, and changing it later is disruptive.

**Tunnel (encapsulation)** — the default. Pod traffic is wrapped in VXLAN or Geneve
between nodes. The underlying network only ever sees node-to-node traffic, so it
needs to know nothing about pod CIDRs. Works almost anywhere, costs you ~50 bytes of
MTU and a little CPU.

**Native routing** — no encapsulation. Pod IPs are routed by the underlying network,
which must therefore know how to reach them, either because all nodes are on one L2
segment or because you run BGP. Faster and simpler to debug with `tcpdump`, but the
network has to cooperate.

```bash
# which one is in use
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i routing
```

> [!tip] Start with tunnel mode
> Native routing is faster, but a misconfigured underlay produces intermittent
> pod-to-pod failures that are painful to diagnose. Tunnel mode works on day one
> and can be changed once the cluster is otherwise stable.

## IPAM modes

How pods get addresses:

| Mode | Who allocates | Use when |
| --- | --- | --- |
| **Cluster Pool** (default) | Cilium, from a cluster-wide CIDR carved into per-node blocks | Almost always |
| **Kubernetes** | kube-controller-manager, via `Node.spec.podCIDR` | You need the node PodCIDR to stay authoritative |
| **ENI / Azure / GKE** | The cloud provider's own IP ranges | Pods must be first-class citizens on the VPC |
| **Multi-Pool** | Cilium, from several named pools | Different address ranges per workload |

Cloud IPAM modes give pods real VPC addresses that security groups and load
balancers can target directly — at the cost of being bounded by per-instance IP
limits.

## Replacing kube-proxy

Cilium can implement Services itself and let you delete kube-proxy entirely.

```bash
--set kubeProxyReplacement=true
```

What that changes:

- ClusterIP, NodePort and LoadBalancer handling move into eBPF.
- Backend selection can use **Maglev** consistent hashing rather than random, so
  backend changes disturb fewer existing connections.
- `externalTrafficPolicy` and source-IP preservation are handled in the datapath.
- **Direct Server Return** becomes available, letting replies bypass the ingress node.

The catch is bootstrapping: with no kube-proxy, the Cilium agent cannot reach the API
server via the `kubernetes` Service, because nothing is implementing that Service
yet. You must tell it where the API server actually is:

```bash
--set k8sServiceHost=10.0.0.1 \
--set k8sServicePort=6443
```

> [!warning] This is the single most common failed Cilium install
> Omit `k8sServiceHost` with `kubeProxyReplacement=true` and the agent starts,
> fails to reach the API server, and crash-loops — while the events blame something
> else. See [[kubernetes/networking/cilium/troubleshooting]].

Verify what was actually enabled:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose \
  | grep -A6 KubeProxyReplacement
```

## The components

| Component | Runs as | Does |
| --- | --- | --- |
| **cilium-agent** | DaemonSet, one per node | Compiles and loads eBPF programs, manages endpoints and maps |
| **cilium-operator** | Deployment | Cluster-wide work: IPAM blocks, identity garbage collection, CRD management |
| **cilium-envoy** | DaemonSet (since 1.14) | L7 policy and Ingress/Gateway API enforcement |
| **hubble-relay** | Deployment | Aggregates flow data — see [[kubernetes/networking/cilium/hubble]] |
| **clustermesh-apiserver** | Deployment | Only for multi-cluster |

State lives in **eBPF maps** pinned under `/sys/fs/bpf`, not in the agent's memory —
which is why restarting the agent does not drop traffic. The datapath keeps
forwarding while the control plane is down.

## Two different CLIs, confusingly named

This trips up everyone, and the error messages do not help:

| Command | What it is | Where it runs |
| --- | --- | --- |
| `cilium` | **cilium-cli** — installs, upgrades, runs connectivity tests | Your workstation, talks to the API server |
| `cilium-dbg` | The **agent's** debug CLI — inspects one node's eBPF state | Inside a `cilium` pod |

So `cilium status` and `kubectl -n kube-system exec ds/cilium -- cilium-dbg status`
report different things: the first is cluster-wide install health, the second is one
node's datapath. Both are useful; they are not interchangeable.

Before Cilium 1.16 the in-agent binary was also called `cilium`, which is why older
documentation and blog posts show `exec ds/cilium -- cilium status`. That still
works via a shim, but `cilium-dbg` is the current name.

## What is new in 1.20

Released 29 July 2026. Worth knowing before you upgrade:

- Builds against **Kubernetes 1.36**, **Envoy 1.37.x**, **Gateway API 1.6.1**,
  **GoBGP 4.6.1**.
- The default **CNI configuration version moves from 0.3.1 to 1.0.0**. If you ship
  a custom CNI config, check it.
- Gateway API gains **TCPRoute**, **UDPRoute** and **ListenerSets**.
- ENI IPAM supports IPv6 prefixes.
- Runtime images move to Ubuntu 26.04.

Breaking changes need attention if you use legacy Mutual Authentication, Envoy Go
extensions, Kafka-aware policies, the `cilium.io/v2alpha1` CiliumNodeConfig API, or
the libnetwork integration. Read the upgrade notes — Cilium's are genuinely detailed.

## Where to go next

- [[kubernetes/networking/cilium/install]] — Helm, cilium-cli and RKE2
- [[kubernetes/networking/cilium/hubble]] — seeing what the datapath is doing
- [[kubernetes/networking/cilium/security]] — policy, identity and the enforcement modes
- [[kubernetes/networking/cilium/wireguard]] — transparent encryption between nodes
- [[kubernetes/networking/cilium/troubleshooting]] — when it does not come up
- [[kubernetes/networking/netpol]] — the standard NetworkPolicy API Cilium also implements

<!-- uplink -->
Part of [[kubernetes/networking/cilium/index|Cilium]].
