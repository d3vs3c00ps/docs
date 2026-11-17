---
title: "Disruptions"
description: "Voluntary and involuntary disruptions, node failures, eviction under pressure, and Pod Disruption Budgets"
tags: [kubernetes, kubectl]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/disruptions.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Disruptions

## In a perfect world...

- hardware never fails;
- software never has bugs;
- ...and never needs to be updated;
- ...and uses a predictable amount of resources;
- ...and these resources are infinite anyway;
- network latency and packet loss are zero;
- humans never make mistakes.

## In the real world...

- hardware fails at random, without warning;
- software has bugs;
- ...and we keep adding new features;
- ...and it sometimes uses more resources than expected;
- ...and these resources are limited;
- network latency and packet loss are NOT zero;
- humans make mistakes (they shut down the wrong machine, the wrong app...).

## Disruptions

In Kubernetes, a "disruption" is something that stops the execution of a Pod. There
are **voluntary** and **involuntary** disruptions:

- voluntary disruptions are started directly by humans (including by mistake!);
- involuntary disruptions are everything else.

This page shows what they are, and how to prevent them, or at least reduce their
effects.

## Node outage

Example: a hardware failure (server or network), or a low-level error (including
kernel bugs, and problems in the hypervisor or the infrastructure below).

This is an **involuntary** disruption, even if it comes from a human error.

Consequence: all the workloads on that node stop responding.

Mitigations:

- scale workloads to at least 2 replicas (or more, if a quorum is needed);
- add anti-affinity scheduling constraints, so that the Pods are not all on the same
  node.

## Node outage play-by-play

1. The node goes down, or is cut from the network.
2. Its Lease (in the `kube-node-lease` Namespace) is no longer renewed.
3. The controller manager detects it, and marks the node as "unreachable". This adds a
   `NoSchedule` and a `NoExecute` taint (`node.kubernetes.io/unreachable`) to the node.
4. After a while, the `NoExecute` taint evicts the node's Pods.
5. The owner controllers create replacement Pods. The exception is Pods with a stable
   network identity, for example in a StatefulSet (see below).

## Node outage notes

By default, Pods tolerate the `unreachable:NoExecute` taint for 5 minutes. The
`DefaultTolerationSeconds` admission controller adds that toleration. (See
[[kubernetes/workloads/taints-and-tolerations|Taints and tolerations]].)

The Pods of a StatefulSet do not recover automatically:

- as long as the Pod object exists, its replacement cannot be created;
- the Pod object exists as long as its Node object exists;
- deleting the Node (by hand or automatically) recovers the Pod.

## Memory/disk pressure

Example: the available memory on a node goes below a set threshold, because a Pod uses
too much memory and has no limit.

This is an **involuntary** disruption.

Consequence: the kubelet starts to *evict* some Pods.

Mitigations:

- set *resource limits* on containers, so that they cannot use too many resources;
- set *resource requests* on containers, so that they are not evicted (as long as they
  use less than what they requested);
- make sure that applications do not use more resources than they requested.

## Memory/disk pressure play-by-play

1. A memory leak in an application container slowly causes very high memory usage.
2. The free memory on the node goes below the *soft* or the *hard* threshold. By
   default, there is no soft threshold. The default hard thresholds are
   `memory.available<100Mi`, `nodefs.available<10%`, `imagefs.available<15%` and
   `nodefs.inodesFree<5%` (on Linux).
3. When the *soft* threshold is reached, the kubelet waits until the "eviction soft
   grace period" expires. Then, if the usage is still above the threshold, it evicts
   Pods gracefully.
4. When the *hard* threshold is reached, the kubelet evicts Pods immediately and
   forcefully.

## Which pods are evicted?

The kubelet ranks the Pods, for the resource that is under pressure only (for example
RAM or disk usage):

1. first, Pods that use *more* than they requested come before the others;
2. then, Pods with a lower *priority* come first (the priority is set with
   `priorityClassName` in the Pod spec);
3. then, Pods that exceed their request by more come first.

It evicts Pods in that order, until enough resources are freed.

> [!warning] Correction
> The original said that the kubelet *only* considers Pods that use more than they
> requested. It considers all Pods: Pods that stay below their requests are only
> evicted last, when evicting the others is not enough.

## Soft (graceful) vs hard (forceful) eviction

- Soft eviction is a graceful shutdown of the Pod. It honors the Pod's
  `terminationGracePeriodSeconds`, limited by the kubelet's `evictionMaxPodGracePeriod`
  setting when that is set.
- Hard eviction is an immediate shutdown of the Pod: all its containers are killed at
  once.

## Memory/disk pressure notes

If resource usage grows *very fast*, the kubelet may not catch it in time.

For memory, the kernel's out-of-memory (OOM) killer is then triggered:

- containers killed by the OOM killer are restarted (according to the Pod's restart
  policy); there is no eviction;
- an eviction may still happen later, if memory usage stays high.

For disk, there is no "out-of-disk" killer, but writes fail:

- the `write` system call fails with `errno = ENOSPC` (`No space left on device`);
- an eviction usually happens shortly after, when the kubelet catches up.

When you rely a lot on disk or memory bursts, PriorityClasses may help.

## Memory/disk pressure delays

By default, no soft threshold is defined. To define one, set both the threshold and
the grace period. Grace periods can be different for each type of resource.

When a node is under pressure, the kubelet adds a `NoSchedule` taint
(`node.kubernetes.io/memory-pressure`, `disk-pressure` or `pid-pressure`), so that no
more Pods are added while the node is under pressure.

Once the node is no longer under pressure, the kubelet removes the taint. It first
waits for an extra delay, `evictionPressureTransitionPeriod` (5 minutes by default).

## Accidental deletion

Example: a developer deletes the wrong Deployment, the wrong Namespace...

This is a **voluntary** disruption (from the point of view of Kubernetes!).

Consequence: the application is down.

Mitigations:

- only deploy to production systems through, for example, GitOps workflows;
- enforce peer review of changes;
- only give users limited (for example read-only) access to production systems;
- use canary deployments (they might not catch all mistakes, though!).

## Bad code deployment

Example: a critical bug is introduced; the application crashes at once, or does not
work.

This is a **voluntary** disruption (again, from the point of view of Kubernetes!).

Consequence: the application is down.

Mitigations:

- readiness probes can catch immediate crashes: a rolling update only goes on while
  enough Pods are ready;
- crashes that happen later need a rollback (by hand, or automated by a canary
  system).

## Node shutdown

Example: scaling down a cluster to save money.

This is a **voluntary** disruption.

Consequences:

- all the workloads on that node are terminated;
- this might disrupt workloads that have too many replicas on that node;
- or workloads that should not be interrupted at all.

Mitigations: we could terminate the workloads one at a time, and coordinate with their
users. But that does not scale. Instead, use Pod Disruption Budgets.

## Pod Disruption Budgets

A Pod Disruption Budget (PDB) is a kind of *contract* between:

- "admins": the people who maintain the cluster (add, remove and update nodes);
- "users": the people who deploy applications and workloads on the cluster.

A PDB says something like: *in this set of Pods, do not "disrupt" more than X at a
time*. Examples:

- in this set of frontend Pods, do not disrupt more than 1 at a time;
- in this set of worker Pods, always keep at least 10 ready (do not disrupt them if it
  would bring the number of ready Pods below 10).

## PDB - user side

Cluster users create a PDB with a manifest like this one:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-pdb
spec:
  #minAvailable: 2
  #minAvailable: 90%
  maxUnavailable: 1
  #maxUnavailable: 10%
  selector:
    matchLabels:
      app: my-app
```
<small>Source: [`k8s/pod-disruption-budget.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/pod-disruption-budget.yaml)</small>

The PDB must give either `minAvailable` or `maxUnavailable`. Both at once are refused.
With neither, the PDB is accepted, but it allows no disruption at all.

## Rounding logic

Percentages are rounded **up**. With `maxUnavailable` as a percentage, this can allow
a higher percentage than you wrote: for example, `maxUnavailable: 50%` with 3 Pods
allows 2 Pods to be unavailable!

## Unmanaged pods

`minAvailable: X` (a number) always works.

`minAvailable: X%` and `maxUnavailable` need *managed Pods*: Pods that belong to a
controller, such as a ReplicaSet or a StatefulSet. This is because the PDB controller
needs the total number of Pods, and it takes it from the controller's `replicas` field,
not merely by counting Pod objects.

The PDB controller tries to find the controller from the Pod selector. If that fails,
it emits warning events (visible with `kubectl describe pdb ...`), and allows no
disruption.

## Zero

`maxUnavailable: 0` means "do not disrupt my Pods". It is the same if `minAvailable` is
greater than or equal to the number of Pods.

In that case, cluster admins should get in touch with the cluster users. This prevents
fully automated operation (and some automated systems used by cluster admins might
not honor that request).

## PDB - admin side

As cluster admins, we must follow some rules:

- only shut down (or restart) a node when no Pods run on it, except the system Pods
  that belong to DaemonSets;
- to remove the Pods running on a node, use the *eviction API*, which checks the PDBs
  and honors them;
- to keep new Pods off a node, use a *taint*.

`kubectl drain` does all this. It:

- *cordons* the node (this adds the `node.kubernetes.io/unschedulable:NoSchedule`
  taint);
- calls the *eviction API* to remove the Pods, while respecting their PDBs.

## Theory vs practice

`kubectl drain` does not evict Pods that use `emptyDir` volumes, unless the
`--delete-emptydir-data` flag is given too. Make sure that `emptyDir` volumes do not
hold anything important. (They should not, but... who knows!)

Kubernetes has no standard way for users to say: *this `emptyDir` volume can (or
cannot) be deleted safely*.

If a PDB forbids an eviction, people must coordinate by hand.

> [!note]- Extra details
> ## Unhealthy pod eviction policy
>
> By default, unhealthy Pods (running, but not ready) can only be evicted if the PDB
> allows it. In many cases, these Pods do not work anyway, and could be removed.
>
> To allow it, set this field in the PDB manifest:
>
> ```yaml
> spec:
>   unhealthyPodEvictionPolicy: AlwaysAllow
> ```

## Node upgrade

Example: upgrading the kubelet or the Linux kernel on a node.

This is a **voluntary** disruption.

Consequences:

- all the workloads on that node are interrupted for a while, and restarted;
- this might disrupt these workloads.

Mitigation: move the workloads off the node first (as if we were shutting it down).

## Node upgrade notes

Is it necessary to drain a node before an upgrade? From
[the documentation][node-upgrade-docs]:

*Draining nodes before upgrading kubelet ensures that pods are re-admitted and
containers are re-created, which may be necessary to resolve some security issues or
other important bugs.*

It is *probably* safe to upgrade in place for:

- kernel upgrades;
- kubelet patch-level upgrades (1.X.Y → 1.X.Z).

It is *probably* better to drain the node for kubelet minor upgrades (1.X → 1.Y).

When in doubt, test extensively in staging environments!

[node-upgrade-docs]: https://kubernetes.io/docs/tasks/administer-cluster/cluster-upgrade/#manual-deployments

## Manual rescheduling

Example: moving workloads around because of noisy neighbors or other problems (for
example, Pod X does a lot of disk I/O and starves the other Pods).

This is a **voluntary** disruption.

Consequence: the moved workloads are interrupted for a while.

Mitigations:

- set an appropriate number of replicas, and declare PDBs;
- use the [eviction API][eviction-API] to move workloads.

[eviction-API]: https://kubernetes.io/docs/concepts/scheduling-eviction/api-eviction/

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/disruptions.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/disruptions.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; eviction order corrected, default thresholds and pressure
> taints added, typos fixed.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
