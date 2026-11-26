---
title: "Kubernetes network model"
description: "One big flat IP network — what the model guarantees, what the CNI provides, and how to pick a network stack"
tags: [kubernetes, networking, cni]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kubenet.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Kubernetes network model

The short version: *the cluster — nodes and pods — is one big flat IP network.*

In detail, the model guarantees that, **without NAT**:

- all nodes can reach each other directly;
- all pods can reach each other directly;
- pods and nodes can reach each other directly;
- each pod knows its own IP address (again: no NAT).

Most clusters rely on a [[kubernetes/networking/cni|CNI plugin]] to deliver this:
it allocates the addresses, creates and configures the interfaces, and sets up
the routing.

## The good

- Everything can reach everything: no address translation, no port translation,
  no new protocol.
- IP addresses are allocated by the network stack, not by users, which avoids the
  constraints that come with address portability.
- CNI is flexible: switching, routing, tunneling — virtually any model works.
  For example, one subnet per node with a simple routed topology.

## The less good

- Everything can reach everything: isolation requires
  [[kubernetes/networking/netpol|network policies]], and some clusters (AWS EKS,
  before 2023) do not ship a network policy controller at all.
- There are literally dozens of implementations —
  [the CNI repository](https://github.com/containernetworking/cni/) lists more
  than 25 plugins.
- Pods get level 3 (IP) connectivity, but *services* are level 4: a service maps
  a single TCP or UDP port — no port ranges, no arbitrary IP packets.
- The default service proxy, `kube-proxy`, historically scaled poorly, though
  [recent versions improved considerably][tables-have-turned].

[tables-have-turned]: https://www.youtube.com/watch?v=yOGHb2HjslY

## In practice

You do not have to think about any of this in local development clusters (it is
set up automatically) or in managed clusters (unless you want to replace what was
installed). You **do** have to pick a network stack when installing Kubernetes on
bare metal or raw virtual machines — whenever you run the control plane yourself.

## Which network stack?

*It depends* on what you optimise for — speed, reliability, security,
observability:

- [Cilium] — powerful and flexible, considered best in class by many; based on
  eBPF, which can make troubleshooting harder. Documented in depth in
  [[kubernetes/networking/cilium/index|Cilium]], including
  [[kubernetes/networking/cilium/troubleshooting|what to run when it misbehaves]].
- [Calico], [Flannel], [kube-router] — other solid choices.
- [Weave] — was the easy, zero-config option, but it is **no longer maintained**.
- Cloud providers and network vendors ship their own, which may or may not fit.

[Weave]: https://github.com/weaveworks/weave
[Cilium]: https://cilium.io/
[Calico]: https://docs.tigera.io/calico/latest/about/
[Flannel]: https://github.com/flannel-io/flannel
[kube-router]: https://www.kube-router.io/

## Multiple moving parts

"The network" is really three layers, which can come from one component or
several:

| Layer | Provides | Implemented by |
| --- | --- | --- |
| Pod-to-pod network ("the CNI") | communication between pods and nodes | CNI plugins |
| Pod-to-service network | internal communication and load balancing | `kube-proxy` by default |
| Network policies | firewalling and isolation | bundled with the CNI, or a separate component |

![Overview of the three Kubernetes network layers](kubernetes/_attachments/k8s-net-0-overview.svg)

![Pod-to-pod network](kubernetes/_attachments/k8s-net-1-pod-to-pod.svg)

![Pod-to-service network](kubernetes/_attachments/k8s-net-2-pod-to-svc.svg)

![Network policies](kubernetes/_attachments/k8s-net-3-netpol.svg)

![View with all the layers again](kubernetes/_attachments/k8s-net-4-overview.svg)

> [!note]- Even more moving parts
> Inbound traffic can be handled by several components: kube-proxy or kube-router
> for NodePort services, and load balancers, ideally connected to the pod
> network. It is possible to run several pod networks in parallel, with
> "meta-plugins" like CNI-Genie or Multus. And some solutions fill several roles
> at once — kube-router can provide the pod network, the network policies, and
> replace kube-proxy.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/kubenet.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kubenet.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, rewritten as
> prose, remark markup converted to Obsidian callouts, referenced files inlined
> or linked.

<!-- uplink -->
Part of [[kubernetes/networking/index|Networking]].
