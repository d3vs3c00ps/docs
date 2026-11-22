---
title: "Rolling updates"
description: "How a Deployment replaces its Pods progressively, what maxUnavailable and maxSurge do, and how to roll back"
tags: [kubernetes, kubectl]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/rollout.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Rolling updates

How should we update a running application? There are three main strategies:

1. Delete the old version, then deploy the new version. This is simple, but it
   obviously causes downtime.
2. Deploy the new version, then delete the old version. This uses a lot of
   resources, and we still have to shift the traffic from one to the other.
3. Replace the running Pods one at a time. This is a *rolling update*, and
   Kubernetes does it for us.

This page uses the DockerCoins `worker` Deployment, scaled to 10 replicas, as in
[[kubernetes/workloads/ourapponkube]] and [[kubernetes/workloads/kubectlscale]].

## Rolling updates

With rolling updates, a Deployment is updated progressively.

A Deployment controls one or more ReplicaSets. Each ReplicaSet is a group of
identical Pods: same image, same arguments, same parameters.

During a rolling update, there are at least two ReplicaSets:

- the "new" set, for the target version;
- at least one "old" set.

There can be several "old" sets, if we start another update before the first one
is done.

## Update strategy

Two parameters set the pace of the rollout: `maxUnavailable` and `maxSurge`. Each one
is a number of Pods, or a percentage of the `replicas` count. Both are 25% by
default. At any time:

- at least `replicas` - `maxUnavailable` Pods are available;
- there are never more than `replicas` + `maxSurge` Pods in total;
- so up to `maxUnavailable` + `maxSurge` Pods are being updated.

With percentages, `maxUnavailable` is rounded down and `maxSurge` is rounded up.

We can also roll back to the previous version, if the update fails or if we do not
like the result.

## Checking current rollout parameters

We can build a custom report with `kubectl` and `jq`.

> [!example] Hands-on
> - Show the rollout plan for our deployments:
>   ```bash
>     kubectl get deploy -o json |
>             jq ".items[] | {name:.metadata.name} + .spec.strategy.rollingUpdate"
>   ```

## Rolling updates in practice

Since Kubernetes 1.8, rolling updates work with Deployments, DaemonSets and
StatefulSets. When we edit the Pod template of one of these resources, it starts a
rolling update. The `kubectl rollout` subcommand monitors and controls rolling
updates.

## Rolling out the new `worker` service

> [!example] Hands-on
> - Let's monitor what's going on by opening a few terminals, and run:
>   ```bash
>   kubectl get pods -w
>   kubectl get replicasets -w
>   kubectl get deployments -w
>   ```
>
> - Update `worker` either with `kubectl edit`, or by running:
>   ```bash
>   kubectl set image deploy worker worker=dockercoins/worker:v0.2
>   ```

That rollout should be quick. What shows in the web UI?

## Give it some time

At first, nothing seems to happen: the graph stays at the same level.
`kubectl get deploy -w` shows that the Deployment was updated very quickly. But
`kubectl get pods -w` tells a different story: the old Pods are still there, in the
`Terminating` state, for a while. When they are finally gone, the graph drops.

This delay comes from our worker: it does not handle signals. Kubernetes sends a
polite shutdown request (`SIGTERM`), and the worker ignores it. After a grace period,
Kubernetes kills the container (`SIGKILL`). The grace period is 30 seconds by
default. Change it with `terminationGracePeriodSeconds` in the Pod spec (see
[Pod termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination)).

## Rolling out something invalid

What happens if we make a mistake? The image `dockercoins/worker:v0.3` does not
exist: we use it on purpose.

> [!example] Hands-on
> - Update `worker` by specifying a non-existent image:
>   ```bash
>   kubectl set image deploy worker worker=dockercoins/worker:v0.3
>   ```
>
> - Check what's going on:
>   ```bash
>   kubectl rollout status deploy worker
>   ```

Our rollout is stuck. `kubectl rollout status` waits; press Ctrl-C to stop it. If we
let it wait, it fails after the Deployment's `progressDeadlineSeconds` (600 seconds by
default) with the message `exceeded its progress deadline`. The new Pods stay in
`ErrImagePull` or `ImagePullBackOff`.

However, the app is not dead. After a minute, it settles at a speed about 20-25%
lower.

## What's going on with our rollout?

Why is our app a bit slower? Because `maxUnavailable` is 25%. 25% of 10 is 2.5,
rounded down to 2: the rollout stopped 2 of the 10 old replicas.

Why do we see 5 new replicas? Because `maxSurge` is 25% too, rounded up to 3. So the
rollout replaces 2 replicas, and also starts 3 more.

`maxUnavailable` is rounded down to protect availability. In total, up to 25% + 25% =
50% of the Pods can be in the middle of an update.

> [!note]- Extra details
> ## The nitty-gritty details
>
> We start with 10 Pods running for the `worker` Deployment. The settings are
> `maxUnavailable=25%` and `maxSurge=25%`. When the rollout starts:
>
> - two old replicas are stopped (`maxUnavailable` = 2);
> - two new replicas are created to replace them;
> - three more new replicas are created (`maxSurge` = 3).
>
> Now we have 8 old replicas running, and 5 new ones that cannot start. The rollout
> is stuck at this point.

## Checking the dashboard during the bad rollout

If you did not deploy the Kubernetes dashboard earlier (see
[[kubernetes/tooling/dashboard]]), skip this part.

> [!example] Hands-on
> - Connect to the dashboard that we deployed earlier
>
> - Check that we have failures in Deployments, Pods, and Replica Sets
>
> - Can we see the reason for the failure?

## Recovering from a bad rollout

We have two options:

- push a `v0.3` image: the Pods retry their pulls, so they will eventually get it,
  and the rollout will go on;
- roll back by hand.

> [!example] Hands-on
> - Cancel the deployment and wait for the dust to settle:
>   ```bash
>   kubectl rollout undo deploy worker
>   kubectl rollout status deploy worker
>   ```

## Going back two versions

We went back to `v0.2`. But this version still has a performance problem. How can we
get back to the version before it?

## Multiple "undos"

What happens if we run `kubectl rollout undo` again?

> [!example] Hands-on
> - Try it:
>   ```bash
>   kubectl rollout undo deployment worker
>   ```
>
> - Check the web UI, the list of pods ...

That did not work: we are back on the broken `v0.3`.

## Multiple "undos" don't work

Think of the successive versions as a stack. `kubectl rollout undo` does not "pop"
the last element from the stack. It copies the element before last to the top. So
several "undos" just swap back and forth between the last two versions.

> [!example] Hands-on
> - Go back to v0.2 again:
>   ```bash
>   kubectl rollout undo deployment worker
>   ```

## In this specific scenario

Our version numbers are easy to guess. But what if we had used git hashes? And what
if we had changed other parameters in the Pod spec?

## Listing versions

`kubectl rollout history` lists the successive versions (revisions) of a Deployment.

> [!example] Hands-on
> - Look at our successive versions:
>   ```bash
>   kubectl rollout history deployment worker
>   ```

We do not see *all* the revisions. We might see something like 1, 5, 6: it depends on
how many "undos" we did.

## Explaining deployment revisions

Each revision is a ReplicaSet. The revision number is stored in an annotation of the
ReplicaSet, `deployment.kubernetes.io/revision`. When a rollback reuses an old
ReplicaSet, that ReplicaSet gets a new revision number.

> [!example] Hands-on
> - Check the annotations for our replica sets:
>   ```bash
>   kubectl describe replicasets -l app=worker | grep -A3 ^Annotations
>   ```

> [!note]- Extra details
> ## What about the missing revisions?
>
> The missing revision numbers are stored in another annotation of the same
> ReplicaSet, `deployment.kubernetes.io/revision-history` (for example `2,4`).
> `kubectl rollout history` does not show them. A script could rebuild the full
> list, if we wanted to.

## Rolling back to an older version

`kubectl rollout undo` also accepts a revision number.

> [!example] Hands-on
> - Roll back to the "known good" deployment version:
>   ```bash
>   kubectl rollout undo deployment worker --to-revision=1
>   ```
>
> - Check the web UI or the list of pods

> [!note]- Extra details
> ## Changing rollout parameters
>
> We want to:
>
> - go back to `v0.1`;
> - be careful with availability: always keep the desired number of available
>   workers;
> - roll out slowly: update only one Pod at a time;
> - give our workers some time to "warm up" before we start more.
>
> This YAML snippet expresses these changes:
>
> ```yaml
> spec:
>   template:
>     spec:
>       containers:
>       - name: worker
>         image: dockercoins/worker:v0.1
>   strategy:
>     rollingUpdate:
>       maxUnavailable: 0
>       maxSurge: 1
>   minReadySeconds: 10
> ```

> [!note]- Extra details
> ## Applying changes through a YAML patch
>
> We could use `kubectl edit deployment worker`. We can also give the exact YAML
> above to `kubectl patch`, which accepts YAML as well as JSON.
>
> > [!example] Hands-on
> > - Apply all our changes and wait for them to take effect:
> >   ```bash
> >   kubectl patch deployment worker -p "
> >     spec:
> >       template:
> >         spec:
> >           containers:
> >           - name: worker
> >             image: dockercoins/worker:v0.1
> >       strategy:
> >         rollingUpdate:
> >           maxUnavailable: 0
> >           maxSurge: 1
> >       minReadySeconds: 10
> >     "
> >   kubectl rollout status deployment worker
> >   kubectl get deploy -o json worker |
> >           jq "{name:.metadata.name} + .spec.strategy.rollingUpdate"
> >   ```

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/rollout.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/rollout.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; the progress deadline, the rounding of `maxSurge` and the
> revision numbers after several undos were checked and explained.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
