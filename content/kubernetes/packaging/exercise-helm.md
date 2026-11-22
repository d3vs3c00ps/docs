---
title: "Exercise — Helm charts"
description: "Let's write a Helm chart for wordsmith!"
tags: [kubernetes, helm]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/exercise-helm.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Exercise — Helm charts

Let's write a Helm chart for wordsmith!

We will need the YAML manifests that we wrote earlier.

Level 1: create a chart to deploy wordsmith.

Level 2: make it so that the number of replicas can be set with `--set replicas=X`.

Level 3: change the colors of the lego bricks.

(For level 3, you'll have to build/push your own images.)

See the hints below if you need them!

## Hints

Use `helm create` to create a new chart.

Delete the content of the `templates` directory and put your YAML instead.

Install the resulting chart. Voilà!

Use `{{ .Values.replicas }}` in the YAML manifest for `words`.

Also add `replicas: 5` to `values.yaml` to provide a default value.

## Changing the color

- Create an account on e.g. Docker Hub (e.g. `janedoe`)

- Create an image repository (e.g. `janedoe/web`)

- Change the images and/or CSS in `web/static`

- Build and push

- Trigger a rolling update using the image you just pushed

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/exercise-helm.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/exercise-helm.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> levels 1 and 2 tested with Helm 4.3.

<!-- uplink -->
Part of [[kubernetes/packaging/index|Packaging with Helm]].
