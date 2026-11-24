---
title: "Revisiting `kubectl logs`"
description: "Reading the logs of several Pods at once with kubectl logs, and its limits"
tags: [kubernetes, kubectl]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kubectl-logs.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Revisiting `kubectl logs`

In this section, we have a Deployment with several Pods: for example `pingpong`, from
[[kubernetes/workloads/kubectl-run]], scaled to at least 3 Pods. We will look at some
limits of `kubectl logs`.

## Streaming logs of multiple pods

By default, `kubectl logs` shows the output of a single Pod.

> [!example] Hands-on
> - Try to check the output of the Pods related to a Deployment:
>   ```bash
>   kubectl logs deploy/pingpong --tail 1 --follow
>   ```

`kubectl logs` only shows the logs of one of the Pods. It says which one first, for
example `Found 3 pods, using pod/pingpong-6ccbc77f68-kmgfn`.

> [!tip] `--all-pods`
> Recent versions of `kubectl` have `--all-pods`: `kubectl logs deploy/pingpong
> --all-pods` shows the logs of every Pod of the Deployment, each line prefixed with
> the Pod and container name.

## Viewing logs of multiple pods

When we give a Deployment name, `kubectl logs` shows the logs of one Pod only. To see
the logs of several Pods, we give a *selector* instead.

The Pods created by the Deployment all have the label `app=pingpong`.
`kubectl create deployment` adds this label by default.

> [!example] Hands-on
> - View the last line of log from all pods with the `app=pingpong` label:
>   ```bash
>   kubectl logs -l app=pingpong --tail 1
>   ```

## Streaming logs of all pingpong pods

Can we stream the logs of all our `pingpong` Pods?

> [!example] Hands-on
> - Combine `-l` and `-f` flags:
>   ```bash
>   kubectl logs -l app=pingpong --tail 1 -f
>   ```

Combining `-l` and `-f` is possible since Kubernetes 1.14. Let's see why it took so
long.

> [!note]- Extra details
> ## Streaming logs of many pods
>
> Let's see what happens if we try to stream the logs of more than 5 Pods.
>
> > [!example] Hands-on
> > - Scale up our deployment:
> >   ```bash
> >   kubectl scale deployment pingpong --replicas=8
> >   ```
> >
> > - Stream the logs:
> >   ```bash
> >   kubectl logs -l app=pingpong --tail 1 -f
> >   ```
>
> We see a message like this one:
> ```
> error: you are attempting to follow 8 log streams, but maximum allowed concurrency is 5, use --max-log-requests to increase the limit
> ```

> [!note]- Extra details
> ## Why can't we stream the logs of many pods?
>
> `kubectl` opens one connection to the API server per Pod. For each Pod, the API
> server opens one more connection to the kubelet of that Pod's node. With 1000 Pods
> in our Deployment, that is 1000 inbound and 1000 outbound connections on the API
> server. This could put a lot of stress on the API server.
>
> Before Kubernetes 1.14, it was decided to *not* allow multiple connections. Since
> Kubernetes 1.14, it is allowed, but limited to 5 connections by default. Change the
> limit with `--max-log-requests`.
>
> For the reasons behind this choice, see
> [PR #67573](https://github.com/kubernetes/kubernetes/pull/67573).

## Shortcomings of `kubectl logs`

- We don't see which Pod sent which log line, unless we add `--prefix`.
- If Pods are restarted or replaced, the log stream stops.
- If new Pods are added, we don't see their logs.
- To stream the logs of several Pods, we need to write a selector.

External tools address these shortcomings, for example
[Stern](https://github.com/stern/stern).

> [!tip] Which Pod sent which line
> Since Kubernetes 1.17, `kubectl logs --prefix` adds `[pod/<name>/<container>]` in
> front of each line. `--all-pods` turns it on by default.

> [!note]- Extra details
> ## `kubectl logs -l ... --tail N`
>
> This is history. With Kubernetes 1.12, `--tail` used together with
> `-l`/`--selector` showed the last 10 lines of each container, instead of the
> number of lines given on the command line. It was fixed in Kubernetes 1.13.
> Today, `kubectl logs -l app=pingpong --tail 1` shows one line per Pod.
>
> *See [#70554](https://github.com/kubernetes/kubernetes/issues/70554) for details.*

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/kubectl-logs.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kubectl-logs.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; `--prefix` and `--all-pods` added, and the exact error message
> for too many log streams updated.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
