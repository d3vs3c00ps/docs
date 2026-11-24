---
title: "Cluster sizing"
description: "What happens when the cluster gets full?"
tags: [kubernetes, observability, monitoring]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/cluster-sizing.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Cluster sizing

> [!note] Not tested locally
> Evictions need real memory or disk pressure on a node; causing it on purpose would
> disturb the shared test machine. The eviction rules below were checked against the
> Kubernetes documentation on node-pressure eviction.

- What happens when the cluster gets full?

- How can we scale up the cluster?

- Can we do it automatically?

- What are other methods to address capacity planning?

## When are we out of resources?

- kubelet monitors node resources:

  - memory

  - node disk usage (typically the root filesystem of the node)

  - image disk usage (where container images and RW layers are stored)

- For each resource, we can provide two thresholds:

  - a hard threshold (if it's met, it provokes immediate action)

  - a soft threshold (provokes action only after a grace period)

- Resource thresholds and grace periods are configurable

  (`evictionHard`, `evictionSoft` and `evictionSoftGracePeriod` in the kubelet
  configuration file; they used to be command-line flags)

## What happens then?

- If disk usage is too high:

  - kubelet will try to remove terminated pods

  - then, it will try to *evict* pods

- If memory usage is too high:

  - it will try to evict pods

- The node is marked as "under pressure"

- This temporarily prevents new pods from being scheduled on the node

## Which pods get evicted?

- kubelet looks at the pods' usage, requests and PriorityClass

- First, pods whose usage of the starved resource exceeds their *requests*

  (BestEffort pods have no requests, so they are always in this group, together with
  Burstable pods above their requests)

- Finally, pods with Guaranteed QoS, and Burstable pods within their requests

- Within each group, pods are sorted by PriorityClass

- If there are pods with the same PriorityClass, they are sorted by usage excess

  (i.e. the pods whose usage exceeds their requests the most are evicted first)

> [!note] Eviction order
> Current kubelets do not rank by QoS class: BestEffort pods and Burstable pods above
> their requests form one group, ordered by priority, then by how much they exceed
> their requests.

> [!note]- Extra details
> ## Eviction of Guaranteed pods
>
> - *Normally*, pods with Guaranteed QoS should not be evicted
>
> - A chunk of resources is reserved for node processes (like kubelet)
>
> - It is expected that these processes won't use more than this reservation
>
> - If they do use more resources anyway, all bets are off!
>
> - If this happens, kubelet must evict Guaranteed pods to preserve node stability
>
>   (or Burstable pods that are still within their requested usage)

## What happens to evicted pods?

- The pod is terminated

- It is marked as `Failed` at the API level (with the reason `Evicted`)

- If the pod was created by a controller, the controller will recreate it

- The pod will be recreated on another node, *if there are resources available!*

- For more details about the eviction process, see:

  - [this documentation page](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/) about resource pressure and pod eviction,

  - [this other documentation page](https://kubernetes.io/docs/concepts/configuration/pod-priority-preemption/) about pod priority and preemption.

## What if there are no resources available?

- Sometimes, a pod cannot be scheduled anywhere:

  - all the nodes are under pressure,

  - or the pod requests more resources than are available

- The pod then remains in `Pending` state until the situation improves

## Cluster scaling

- One way to improve the situation is to add new nodes

- This can be done automatically with the [Cluster Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler)

- The autoscaler will automatically scale up:

  - if there are pods that failed to be scheduled

- The autoscaler will automatically scale down:

  - if nodes have a low utilization for an extended period of time

## Restrictions, gotchas ...

- The Cluster Autoscaler only supports a few cloud infrastructures

  (see the [kubernetes/autoscaler repo][kubernetes-autoscaler-repo] for a list)

- The Cluster Autoscaler cannot scale down nodes that have pods using:

  - local storage

  - affinity/anti-affinity rules preventing them from being rescheduled

  - a restrictive PodDisruptionBudget

[kubernetes-autoscaler-repo]: https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler/cloudprovider

## Other ways to do capacity planning

- "Running Kubernetes without nodes"

- Systems like [Virtual Kubelet](https://virtual-kubelet.io/) or Kiyot can run pods using on-demand resources

  - Virtual Kubelet can leverage e.g. ACI or Fargate to run pods

  - Kiyot ran pods in ad-hoc EC2 instances (1 instance per pod); the project is no
    longer available

- Economic advantage (no wasted capacity)

- Security advantage (stronger isolation between pods)

Check [this blog post](http://jpetazzo.github.io/2019/02/13/running-kubernetes-without-nodes-with-kiyot/) for more details.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/cluster-sizing.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/cluster-sizing.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> eviction order and kubelet settings updated, dead links fixed, "not tested" notice added.

<!-- uplink -->
Part of [[kubernetes/observability/index|Observability and scaling]].
