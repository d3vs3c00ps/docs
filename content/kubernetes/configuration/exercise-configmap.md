---
title: "Exercise — ConfigMaps"
description: "Exercise: serve the static files of the wordsmith app from a ConfigMap, with a solution"
tags: [kubernetes, configuration]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/exercise-configmap.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Exercise — ConfigMaps

In this exercise, we use a ConfigMap to store static assets. This can be useful in a
few cases, but in general it is **not** a good idea! ConfigMaps are made for
configuration, and are limited to 1 MiB each.

## Exercise — ConfigMaps

This exercise uses the wordsmith app, from
[[kubernetes/workloads/exercise-wordsmith|the wordsmith exercise]].

We want to store the static files (served by `web`) in a ConfigMap.

1. Turn the `static` directory into a ConfigMap. The directory is in the
   [wordsmith repository](https://github.com/jpetazzo/wordsmith/tree/main/web/static).
2. Find out where that `static` directory is in the `web` container. For example, use
   `kubectl exec` to look around.
3. Update the `web` Deployment to use the ConfigMap. Fonts and images will be broken:
   that's OK.
4. Make a small change in the ConfigMap (change the text color, for example).

> [!warning] amd64 only
> The wordsmith images (`jpetazzo/wordsmith-*`) exist only for `linux/amd64`. An arm64
> node (Apple silicon, Raspberry Pi, Graviton) still pulls them, but it can only run
> them if it emulates amd64. Docker Desktop does, so a kind cluster on a Mac runs them, slowly.
> Without emulation, the containers fail with `exec format error` and the Pods go into
> `CrashLoopBackOff`.

> [!example]- Solution
> Get the files, and create the ConfigMap from the directory:
>
> ```bash
> git clone https://github.com/jpetazzo/wordsmith
> kubectl create configmap static --from-file=wordsmith/web/static/
> ```
>
> `--from-file` with a directory takes only the regular files in it. It skips the
> `fonts` and `images` subdirectories. Binary files, like `favicon.ico`, go under
> `binaryData` instead of `data`.
>
> The `web` image has no working directory set, so it runs in `/` and serves
> `/static`:
>
> ```bash
> kubectl exec deployment/web -- ls /static
> ```
>
> Mount the ConfigMap on `/static`. The mount hides the whole directory of the
> image, `fonts` and `images` included: this is why they break.
>
> ```bash
> kubectl patch deployment web --patch='
> spec:
>   template:
>     spec:
>       volumes:
>       - name: static
>         configMap:
>           name: static
>       containers:
>       - name: wordsmith-web
>         volumeMounts:
>         - name: static
>           mountPath: /static
> '
> ```
>
> Then edit the ConfigMap, for example the color in `style.css`:
>
> ```bash
> kubectl edit configmap static
> ```
>
> The kubelet updates the mounted files after a short delay (up to about a minute),
> without restarting the Pod. This does not happen for files mounted with `subPath`.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/exercise-configmap.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/exercise-configmap.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; a solution and a note on amd64-only images added.

<!-- uplink -->
Part of [[kubernetes/configuration/index|Configuration and secrets]].
