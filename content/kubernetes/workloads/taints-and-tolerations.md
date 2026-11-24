---
title: "Taints and tolerations"
description: "Taints keep Pods off a node unless they tolerate them: effects, operators, tolerationSeconds and taint-based evictions"
tags: [kubernetes, kubectl]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/taints-and-tolerations.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Taints and tolerations

Kubernetes has many ways to influence where Pods run: taints and tolerations, node
selectors, affinity, resource requests...

Taints and tolerations are used to:

- reserve a node for special workloads (for example the control plane, GPUs,
  security-sensitive workloads);
- block a node for a while (for example for maintenance or troubleshooting);
- evacuate a node that has a problem.

In fact, the default failover mechanism of Kubernetes relies on "taint-based
evictions". Let's dive into all that!

## Taints and tolerations

A *taint* is an attribute added to a node. It keeps Pods from running on the node,
unless they have a matching *toleration*.

For example, when you deploy with `kubeadm`:

- a taint is placed on the control plane node(s)
  (`node-role.kubernetes.io/control-plane:NoSchedule`);
- the Pods that must run there, like CoreDNS, have a matching toleration. (The API
  server, etcd, the scheduler and the controller manager are *static Pods*: the kubelet
  starts them without the scheduler, so a `NoSchedule` taint does not apply to them.)

## Checking taints on our nodes

Here are a few ways to view the taints on our nodes:

```bash
kubectl describe nodes | grep ^Taints

kubectl get nodes -o custom-columns=NAME:metadata.name,TAINTS:spec.taints

kubectl get nodes -o json | jq '.items[] | [.metadata.name, .spec.taints]'
```

Your nodes may have no taints at all. That is not an error or a problem.

## Taint structure

As shown by `kubectl explain node.spec.taints`, a taint has:

- an `effect` (required);
- a `key` (required);
- a `value` (optional).

(It also has `timeAdded`, which Kubernetes sets for `NoExecute` taints.) Let's see what
they mean!

## Taint `key` (mandatory)

The `key` is any string that identifies a particular taint. It can mean many things,
for instance:

- a reservation for a special set of Pods ("this node is reserved for the control
  plane");
- an error condition on the node, hopefully temporary ("this node's disk is full, do
  not start new Pods there!");
- a temporary "hold" on the node ("we are going to do maintenance on this node").

## Taint `effect` (mandatory)

- `NoSchedule`: do not place new Pods on that node. Existing Pods are not affected.
- `PreferNoSchedule`: try not to place new Pods on that node. Place them on other
  nodes if possible. Use case: the cluster autoscaler, when it plans to remove a node.
- `NoExecute`: stop the Pods on that node. Existing Pods are terminated (technically:
  evicted). Use case: the node is in a critical state, and its workloads should move.

## Taint `value` (optional)

A taint can have just a `key`, or a `key` and a `value`. Tolerations can match a
taint's `key`, or its `key` and `value`. (We explain tolerations below.)

## Checking tolerations on our Pods

Here are a few ways to see the tolerations of the Pods in the current Namespace:

```bash
kubectl get pods -o custom-columns=NAME:metadata.name,TOLERATIONS:spec.tolerations

kubectl get pods -o json |
jq '.items[] | {"pod_name": .metadata.name} + .spec.tolerations[]'
```

The output is likely to be very long. Suggestion: try it...

- in a Namespace with a few "normal" Pods (created by a Deployment);
- in `kube-system`, with a selector to see only the CoreDNS Pods (`-l k8s-app=kube-dns`).

## Toleration structure

As shown by `kubectl explain pod.spec.tolerations`, a toleration has:

- an `effect`;
- a `key`;
- an `operator`;
- a `value`;
- a `tolerationSeconds`.

All fields are optional, but they cannot all be empty: an empty key needs the
`Exists` operator (see below). Let's see what they mean!

## Toleration `effect`

It has the same meaning as the `effect` of taints. If it is omitted, the toleration
matches taints with any effect.

## Toleration `key`

It has the same meaning as the `key` of taints: "tolerate the taints that have this
`key`".

Special case: the `key` can be omitted, to mean "match all keys". Then the `operator`
must be `Exists`. (We cannot omit both the `key` and the `operator`.)

## Toleration `operator`

It is either `Equal` (the default) or `Exists`.

- `Equal` means: *match taints with exactly the same `key` and `value` as this
  toleration*.
- `Exists` means: *match taints with the same `key` as this toleration, whatever their
  `value`*.

As seen above, `Exists` with an empty `key` means: *match taints with any `key` or
`value`*.

## Toleration `value`

It matches taints with the same `value` (with the `Equal` operator).

## Toleration `tolerationSeconds`

It only applies to `NoExecute` taints and tolerations: the ones that cause an
*eviction* (termination) of Pods.

It means that the taint is ignored for that amount of time. After that time, the taint
takes effect, and the Pod is evicted and terminated.

This is mostly used for automated failover with *taint-based evictions*, and more
generally to tolerate short problems.

## Taint-based evictions

Pods[^1] automatically get these two tolerations (from the `DefaultTolerationSeconds`
admission controller):

  ```yaml
    - key: node.kubernetes.io/not-ready
      effect: NoExecute
      operator: Exists
      tolerationSeconds: 300
    - key: node.kubernetes.io/unreachable
      effect: NoExecute
      operator: Exists
      tolerationSeconds: 300
  ```

So, what is the effect of these tolerations?

[^1]: Except Pods that already have tolerations for these taints. DaemonSet Pods are
    an example: the DaemonSet controller gives them the same two tolerations, but with
    no `tolerationSeconds`, so they are never evicted for these taints.

## Node `not-ready` or `unreachable`

Nodes must check in with the control plane regularly. By default, the kubelet renews
its Lease (in the `kube-node-lease` Namespace) every 10 seconds.

When a node stops checking in for 50 seconds (the controller manager's
`--node-monitor-grace-period`), the control plane marks it `Unknown` and adds the
`node.kubernetes.io/unreachable` taint to it.

> [!note] Timings
> The kubelet renews its Lease every 10 seconds (a quarter of
> `nodeLeaseDurationSeconds`, 40 seconds), and the node is marked unreachable after
> `--node-monitor-grace-period`: 50 seconds in current versions (40 seconds in older
> ones).

The taint is tolerated for 300 seconds: for 5 minutes, nothing happens. After that
delay, the taint applies fully: *the Pods are evicted*, and *replacement Pods should be
scheduled on healthy nodes*.

## Use-cases

By default, about 5 minutes after a node stops responding, its Pods are rescheduled.

That delay can be changed: add tolerations with the same `key` + `effect` + `operator`
and another `tolerationSeconds`. So we can set:

- longer delays for Pods that are "expensive" to move (for example because they hold
  a lot of state);
- shorter delays for Pods that should fail over as fast as possible.

## Manipulating taints

We can add and remove taints with the usual Kubernetes commands (`kubectl edit`,
`kubectl patch`, `kubectl apply`...). There are also `kubectl` commands just for
taints:

- `kubectl taint node NodeName key=val:effect` adds a taint (`=val` is optional).
- `kubectl taint node NodeName key=val:effect-` (with a trailing `-`) removes it.
  `kubectl taint node NodeName key-` removes all the taints with that key.
- `kubectl cordon NodeName` / `kubectl uncordon NodeName` mark the node unschedulable
  or schedulable again. The control plane then adds or removes the taint
  `node.kubernetes.io/unschedulable:NoSchedule`.

> [!note] There is no `kubectl untaint`
> Remove a taint with `kubectl taint` and a trailing `-`, as above.

The command `kubectl drain` does a `cordon`, then evicts the Pods on the node (see
[[kubernetes/workloads/disruptions|Disruptions]]).

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/taints-and-tolerations.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/taints-and-tolerations.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; heartbeat timings and taint removal corrected.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
