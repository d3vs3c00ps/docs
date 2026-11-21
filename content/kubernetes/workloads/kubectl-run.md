---
title: "Running our first containers on Kubernetes"
description: "Running a first Pod with kubectl run, reading its logs, and why Deployments and ReplicaSets exist"
tags: [kubernetes, kubectl]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kubectl-run.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Running our first containers on Kubernetes

First things first: we cannot run a container directly. We run a Pod, and in that Pod
there is a single container. In that container, we run a simple `ping` command.

> [!note]- Extra details
> ## If you're running Kubernetes 1.17 (or older)...
>
> This material assumes a recent version of Kubernetes (at least 1.19). Check your
> version with `kubectl version` (look at the server part).
>
> In Kubernetes 1.17 and older, `kubectl run` created a Deployment. Since 1.18, it
> only creates a Pod: its "generators" (`--generator=...`) and the `--replicas` option
> were removed. Use `kubectl create deployment` (below) to create a Deployment.
>
> If you still run such an old version: it is obsolete and no longer maintained.
> Kubernetes 1.17 is [end of life since January 2021][nonactive]. Upgrade now!
>
> [nonactive]: https://kubernetes.io/releases/patch-releases/#non-active-branch-history

## Starting a simple pod with `kubectl run`

`kubectl run` is a quick way to start a single Pod. We must give at least a *name* and
the image to use. We can also give the command to run in the Pod.

> [!example] Hands-on
> - Let's ping the address of `localhost`, the loopback interface:
>   ```bash
>   kubectl run pingpong --image alpine ping 127.0.0.1
>   ```

The output tells us that a Pod was created:
```
pod/pingpong created
```

The words after the Pod name become the container's *arguments*: they replace the
image's `CMD`, and the image's `ENTRYPOINT` (if any) stays. To replace the entrypoint
too, add `--command`. Putting `--` before the command is clearer, and needed when the
command has options that `kubectl` could take for its own:
`kubectl run pingpong --image alpine -- ping -c 3 127.0.0.1`.

## Viewing container output

Let's use the `kubectl logs` command. It takes a Pod name as argument. Unless told
otherwise, it only shows the logs of the first container in the Pod (or of the
container named by the `kubectl.kubernetes.io/default-container` annotation). Good
thing there is only one in ours!

> [!example] Hands-on
> - View the result of our `ping` command:
>   ```bash
>   kubectl logs pingpong
>   ```

## Streaming logs in real time

Like `docker logs`, `kubectl logs` has handy options:

- `-f`/`--follow` streams the logs in real time (like `tail -f`);
- `--tail` says how many lines to show (from the end);
- `--since` only shows the logs newer than a duration (for example `--since=5m`);
  `--since-time` does the same from a timestamp.

> [!warning] Correction
> The original said that `--since` takes a timestamp. It takes a duration (`10s`,
> `5m`, `1h`). The option for a timestamp is `--since-time` (RFC 3339, for example
> `2026-01-01T10:00:00Z`).

> [!example] Hands-on
> - View the latest logs of our `ping` command:
>   ```bash
>   kubectl logs pingpong --tail 1 --follow
>   ```
>
> - Stop it with Ctrl-C.

## Scaling our application

`kubectl` has a simple command to scale a workload:
`kubectl scale TYPE NAME --replicas=HOWMANY`. Let's try it on our Pod, to get more Pods!

> [!example] Hands-on
> - Try to scale the Pod:
>   ```bash
>   kubectl scale pod pingpong --replicas=3
>   ```

We get the following error. What does it mean?

```
Error from server (NotFound): the server could not find the requested resource
```

## Scaling a Pod

We cannot "scale a Pod". (That is not completely true: we could give it more CPU or
RAM.) If we want more Pods, we must create more Pods, for example by running
`kubectl run` several times. There must be a better way! (Spoiler: yes, there is.)

> [!note]- Extra details
> ## `NotFound`
>
> What does this error mean?
> ```
> Error from server (NotFound): the server could not find the requested resource
> ```
>
> When we run `kubectl scale THAT-RESOURCE --replicas=THAT-MANY`, it is like telling
> Kubernetes: *go to THAT-RESOURCE and set the scaling button to position THAT-MANY*.
>
> Pods do not have a "scaling button".
>
> Run the `kubectl scale pod` command again with `-v6`. We see a `PATCH` request to
> `/scale`: that is the "scaling button". Technically, it is a *subresource* of the
> Pod, and Pods do not have it, hence `NotFound`.

## Creating more pods

We are going to create a ReplicaSet: a set of replicas, that is, a set of identical
Pods. In fact, we create a Deployment, which then creates a ReplicaSet. Why so many
layers? We explain it below.

## Creating a Deployment running `ping`

Let's create a Deployment instead of a single Pod.

> [!example] Hands-on
> - Create the Deployment; pay attention to the `--`:
>   ```bash
>   kubectl create deployment pingpong --image=alpine -- ping 127.0.0.1
>   ```

The `--` separates:

- the options of `kubectl create`;
- the command to run in the container.

Unlike `kubectl run`, this command becomes the container's `command` (it replaces the
image's entrypoint).

## What has been created?

> [!example] Hands-on
> - Check the resources that were created:
>   ```bash
>   kubectl get all
>   ```

Note: `kubectl get all` is a lie. It does not show everything (no ConfigMaps, Secrets,
Ingresses...). But it shows many of the "usual suspects", the commonly used resources.

## There's a lot going on here!

```
NAME                            READY   STATUS        RESTARTS   AGE
pod/pingpong                    1/1     Running       0          4m17s
pod/pingpong-6ccbc77f68-kmgfn   1/1     Running       0          11s

NAME                 TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
service/kubernetes   ClusterIP   10.96.0.1    <none>        443/TCP   3h45

NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/pingpong   1/1     1            1           11s

NAME                                  DESIRED   CURRENT   READY   AGE
replicaset.apps/pingpong-6ccbc77f68   1         1         1       11s
```

Our new Pod is not named `pingpong`, but `pingpong-xxxxxxxxxxx-yyyyy`. We have a
Deployment named `pingpong`, and an extra ReplicaSet too. What is going on?

## From Deployment to Pod

We have the following resources:

- `deployment.apps/pingpong`: the Deployment that we just created.
- `replicaset.apps/pingpong-xxxxxxxxxx`: a ReplicaSet created by this Deployment.
- `pod/pingpong-xxxxxxxxxx-yyyyy`: a *Pod* created by the ReplicaSet.

Let's explain what these things are.

## Pod

- A Pod can have one or more containers.
- It runs on a single node. A Pod cannot "straddle" several nodes.
- It cannot be moved (for example, when its node fails).
- It cannot be scaled horizontally (except by creating more Pods by hand).

> [!note]- Extra details
> ## Pod details
>
> A Pod is not a process; it is an environment for containers. It cannot be
> "restarted", and it cannot "crash".
>
> The containers in a Pod can crash. They may or may not be restarted, depending on
> the Pod's restart policy (`restartPolicy`).
>
> - If all containers exit successfully, the Pod ends in the `Succeeded` phase.
> - If some containers fail and are not restarted, the Pod ends in the `Failed` phase.

## Replica Set

- A ReplicaSet is a set of identical (replicated) Pods.
- It is defined by a Pod template and a number of desired replicas.
- If there are not enough Pods, the ReplicaSet creates more (for example when a node
  fails, or when we scale up).
- If there are too many Pods, the ReplicaSet deletes some (for example when a
  disconnected node comes back, or when we scale down).
- We can scale a ReplicaSet up or down: we update its manifest, and then the
  ReplicaSet controller creates or deletes Pods.

## Deployment

ReplicaSets control *identical* Pods. Deployments are used to roll out *different*
Pods (a different image, command, environment variables...).

When we update a Deployment with a new Pod definition:

- a new ReplicaSet is created with the new Pod definition;
- that new ReplicaSet is scaled up, step by step;
- at the same time, the old ReplicaSet(s) are scaled down.

This is a *rolling update*. It keeps application downtime as low as possible.

When we scale a Deployment up or down, it scales its ReplicaSet up or down.

## Can we scale now?

Let's try `kubectl scale` again, but on the Deployment!

> [!example] Hands-on
> - Scale our `pingpong` deployment:
>   ```bash
>   kubectl scale deployment pingpong --replicas 3
>   ```
>
> - Note that we could also write it like this:
>   ```bash
>   kubectl scale deployment/pingpong --replicas 3
>   ```
>
> - Check that we now have several Pods:
>   ```bash
>   kubectl get pods
>   ```

> [!note]- Extra details
> ## Scaling a Replica Set
>
> What if we scale the ReplicaSet instead of the Deployment? The Deployment notices it
> right away, and scales it back to the size the Deployment wants.
>
> The ReplicaSet makes sure that we have the right number of Pods. The Deployment
> makes sure that the ReplicaSet has the right size. Conceptually, the Deployment
> delegates the management of the Pods to the ReplicaSet.
>
> This extra layer may seem odd, but it makes sense when we look at how rolling
> updates work.

## Checking Deployment logs

`kubectl logs` needs a Pod name. But it also accepts a *type/name*, such as
`deployment/pingpong`.

> [!example] Hands-on
> - View the result of our `ping` command:
>   ```bash
>   kubectl logs deploy/pingpong --tail 2
>   ```

It shows the logs of one Pod of the Deployment (and says which one: `Found 3 pods,
using pod/...`). We will see later how to get the logs of *all* the Pods (see
[[kubernetes/workloads/kubectl-logs|kubectl logs]]).

## Resilience

The *Deployment* `pingpong` watches its *ReplicaSet*. The *ReplicaSet* makes sure that
the right number of *Pods* is running. What happens if Pods disappear?

> [!example] Hands-on
> - In a separate window, watch the list of Pods:
>   ```bash
>   watch kubectl get pods
>   ```
>
> - Delete the Pod shown by `kubectl logs`:
>   ```
>   kubectl delete pod pingpong-xxxxxxxxxx-yyyyy
>   ```

## What happened?

`kubectl delete pod` stops the Pod gracefully: it sends the TERM signal, and waits for
the Pod to shut down. As soon as the Pod is in the "Terminating" state, the ReplicaSet
replaces it.

We can still see the output of the "Terminating" Pod in `kubectl logs`. Here, `ping`
runs as PID 1 and ignores the TERM signal, so this lasts until the grace period ends,
30 seconds later. The Pod is then killed, and `kubectl logs` exits.

## Deleting a standalone Pod

What happens if we delete a standalone Pod, like the first `pingpong` Pod that we
created?

> [!example] Hands-on
> - Delete the Pod:
>   ```bash
>   kubectl delete pod pingpong
>   ```

No replacement Pod is created, because no *controller* watches it. That is why we
rarely use standalone Pods in practice, except for one-off debugging or a short task
that we watch ourselves.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/kubectl-run.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kubectl-run.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; `kubectl run` arguments, `--since` and the grace period
> explained for current Kubernetes.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
