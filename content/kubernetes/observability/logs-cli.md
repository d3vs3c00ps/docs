---
title: "Accessing logs from the CLI"
description: "it cannot stream logs from multiple pods at a time"
tags: [kubernetes, observability, monitoring]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/logs-cli.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Accessing logs from the CLI

- The `kubectl logs` command has limitations:

  - it cannot stream logs from multiple pods at a time

  - when showing logs from multiple pods, it mixes them all together

- We are going to see how to do it better

## Doing it manually

- We *could* (if we were so inclined) write a program or script that would:

  - take a selector as an argument

  - enumerate all pods matching that selector (with `kubectl get -l ...`)

  - fork one `kubectl logs --follow ...` command per container

  - annotate the logs (the output of each `kubectl logs ...` process) with their origin

  - preserve ordering by using `kubectl logs --timestamps ...` and merge the output

- We *could* do it, but thankfully, others did it for us already!

## Stern

[Stern](https://github.com/stern/stern) is an open source project
originally by Wercker (now maintained by the community).

From the README:

*Stern allows you to tail multiple pods on Kubernetes and multiple containers within the pod. Each result is color coded for quicker debugging.*

*The query is a regular expression so the pod name can easily be filtered and you don't need to specify the exact id (for instance omitting the deployment id). If a pod is deleted it gets removed from tail and if a new pod is added it automatically gets tailed.*

Exactly what we need!

## Checking if Stern is installed

- Run `stern` (without arguments) to check if it's installed:

  ```
  $ stern
  Tail multiple pods and containers from Kubernetes

  Usage:
    stern pod-query [flags]
  ```

- If it's missing, let's see how to install it

## Installing Stern

- Stern is written in Go

- Go programs are usually very easy to install

  (no dependencies, extra libraries to install, etc)

- Binary releases are available [on GitHub][stern-releases]

- Stern is also available through most package managers

  (e.g. on macOS, we can `brew install stern` or `sudo port install stern`)

[stern-releases]: https://github.com/stern/stern/releases

## Using Stern

- There are two ways to specify the pods whose logs we want to see:

  - `-l` followed by a selector expression (like with many `kubectl` commands)

  - with a "pod query," i.e. a regex used to match pod names

- These two ways can be combined if necessary

> [!example] Hands-on
> - View the logs for all the pingpong containers:
>   ```bash
>   stern pingpong
>   ```

## Stern convenient options

- The `--tail N` flag shows the last `N` lines for each container

  (Instead of showing the logs since the creation of the container)

- The `-t` / `--timestamps` flag shows timestamps

- The `--all-namespaces` flag is self-explanatory

> [!example] Hands-on
> - View what's up with the `coredns` system containers:
>   ```bash
>   stern --tail 1 --timestamps --all-namespaces coredns
>   ```

## Using Stern with a selector

- When specifying a selector, we can omit the value for a label

- This will match all objects having that label (regardless of the value)

- Everything created with `kubectl run` has a label `run`

- Everything created with `kubectl create deployment` has a label `app`

- We can use that property to view the logs of all the pods created with `kubectl create deployment`

> [!example] Hands-on
> - View the logs for all the things started with `kubectl create deployment`:
>   ```bash
>   stern -l app
>   ```

## Other useful tools

- `kl` (https://github.com/robinovitch61/kl)

  *select containers interactively, navigate/view/search logs*

- `gonzo` (https://github.com/control-theory/gonzo)

  *real-time stream analysis, statistics, etc.*

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/logs-cli.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/logs-cli.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> dead link removed, tested with stern 1.35 on kind.

<!-- uplink -->
Part of [[kubernetes/observability/index|Observability and scaling]].
