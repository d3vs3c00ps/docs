---
title: "Recording deployment actions"
description: "The change-cause annotation, the deprecated --record flag, and why the rollout history can show the wrong cause"
tags: [kubernetes, kubectl]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/record.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Recording deployment actions

Some commands that change a Deployment accept an optional `--record` flag. For
example: `kubectl set image deployment worker worker=alpine --record`.

That flag stores the command line in the Deployment, in the annotation
`kubernetes.io/change-cause`. The Deployment controller copies the annotation to the
matching ReplicaSet. So we can keep track of which command created or promoted each
ReplicaSet. `kubectl rollout history` shows this information.

> [!warning] `--record` is deprecated
> `--record` has been deprecated since Kubernetes 1.22. It is hidden from
> `kubectl --help`, and each use prints
> `Flag --record has been deprecated, --record will be removed in the future`.
> It still works with kubectl 1.37, but do not build on it. Set the
> `kubernetes.io/change-cause` annotation yourself instead, as the last section of
> this page shows.
> The pitfalls below apply to that annotation, however you set it.

This page uses the DockerCoins `worker` Deployment from
[[kubernetes/workloads/rollout]].

## Using `--record`

Let's make a couple of changes to a Deployment and record them.

> [!example] Hands-on
> - Roll back `worker` to image version 0.1:
>   ```bash
>   kubectl set image deployment worker worker=dockercoins/worker:v0.1 --record
>   ```
>
> - Promote it to version 0.2 again:
>   ```bash
>   kubectl set image deployment worker worker=dockercoins/worker:v0.2 --record
>   ```
>
> - View the change history:
>   ```bash
>   kubectl rollout history deployment worker
>   ```

## Pitfall #1: forgetting `--record`

What happens if we do not specify `--record`?

> [!example] Hands-on
> - Promote `worker` to image version 0.3:
>   ```bash
>   kubectl set image deployment worker worker=dockercoins/worker:v0.3
>   ```
>
> - View the change history:
>   ```bash
>   kubectl rollout history deployment worker
>   ```

It recorded version 0.2 instead of 0.3! Why?

## How `--record` really works

1. `kubectl` adds the annotation `kubernetes.io/change-cause` to the Deployment.
2. The Deployment controller copies that annotation to the ReplicaSet.
3. `kubectl rollout history` shows the annotations of the ReplicaSets.

Without `--record`, the annotation of the Deployment is not updated. Its previous
value is copied to the new ReplicaSet. So the ReplicaSet annotation does not match
what really happened.

## Pitfall #2: recording `scale` commands

What happens if we use `kubectl scale --record`?

> [!example] Hands-on
> - Check the current history:
>   ```bash
>   kubectl rollout history deployment worker
>   ```
>
> - Scale the deployment:
>   ```bash
>   kubectl scale deployment worker --replicas=3 --record
>   ```
>
> - Check the change history again:
>   ```bash
>   kubectl rollout history deployment worker
>   ```

The `scale` command overwrote the last entry in the history! Why?

## Actions that don't create a new ReplicaSet

The `scale` command updates the Deployment, but it does not create a new ReplicaSet.
The `--record` flag sets the annotation as before, and the controller copies it to
the *current* ReplicaSet. This overwrites the annotation that was there, so we lose
the previous change cause.

## Updating the annotation directly

Let's see what happens if we set the annotation by hand.

> [!example] Hands-on
> - Annotate the Deployment:
>   ```bash
>   kubectl annotate deployment worker kubernetes.io/change-cause="Just for fun"
>   ```
>
> - Check that our annotation shows up in the change history:
>   ```bash
>   kubectl rollout history deployment worker
>   ```

Our annotation shows up, and it replaced the value that was there before.

## Using change cause

Using `--record` sounds like a good idea, but:

*"Incorrect documentation is often worse than no documentation."* (Bertrand Meyer)

If we use `--record` once, we then have to either:

- use it every single time after that;
- or remove the annotation from the Deployment after each `--record`. Later changes
  then show up with a `<none>` change cause.

A safer way is to set the annotation from our tooling.

## Setting the change cause without `--record`

Change the Deployment first, then set the annotation. The new ReplicaSet gets the old
cause for a moment, then the controller copies the new one to it.

```bash
kubectl set image deployment worker worker=dockercoins/worker:v0.1
kubectl annotate deployment worker --overwrite \
        kubernetes.io/change-cause="Back to v0.1, v0.3 does not exist"
kubectl rollout history deployment worker
```

`kubectl annotate` refuses to replace an existing annotation without `--overwrite`,
but it makes an exception for `kubernetes.io/change-cause`. That is why the command
in the previous section worked. `--overwrite` above makes the intent clear.

Do not annotate *before* the change: the controller would copy the new cause to the
current ReplicaSet, and overwrite the cause of the previous change.

With YAML manifests, put the annotation in the Deployment's `metadata.annotations`,
next to the change. One `kubectl apply` then updates both at the same time:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
  annotations:
    kubernetes.io/change-cause: "Image v0.1, applied from git commit abc1234"
```

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/record.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/record.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; the deprecation of `--record` is flagged, and a section on
> setting the change cause without it was added.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
