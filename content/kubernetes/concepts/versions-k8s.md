---
title: "Kubernetes versions and release cycle"
description: "Checking versions, the Kubernetes release cadence and support window, and the kubectl version skew policy"
tags: [kubernetes, architecture]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/versions-k8s.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Kubernetes versions and release cycle

## Versions installed

Check the versions of the tools you use:

> [!example] Hands-on
> - Check all installed versions:
>   ```bash
>   kubectl version
>   docker version
>   docker compose version
>   ```

`kubectl version` shows two versions: the `Client Version` (`kubectl` itself) and the
`Server Version` (the API server of your cluster).

> [!note] Tested versions
> This page was last tested with Kubernetes 1.37.0 (a kind cluster) and `kubectl`
> 1.37.1. Docker Compose v1 (`docker-compose -v`) reached its end of life in 2023.
> Compose v2 is a Docker CLI plugin: use `docker compose version`.

> [!note]- Extra details
> ## Kubernetes and Docker compatibility
>
> This section is history. It explains a question that was common before 2022.
>
> - Kubernetes 1.17 validated Docker Engine versions [up to 19.03](https://github.com/kubernetes/kubernetes/pull/84476).
> - Kubernetes 1.15 validated Docker Engine versions [up to 18.09](https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.15.md#dependencies),
>   the latest version when Kubernetes 1.14 came out.
> - Kubernetes 1.13 only validated Docker Engine versions [up to 18.06](https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.13.md#external-dependencies).
>
> Was it a problem to use Kubernetes with a "too recent" Docker Engine? No.
>
> - "Validated" means that continuous integration ran very extensive (and expensive)
>   tests with that version.
> - The Docker API is versioned, and it is strongly backward compatible. If a client
>   uses API v1.25, for example, the Docker Engine keeps behaving the same way.
>
> > [!warning] No more dockershim
> > Kubernetes 1.24 removed *dockershim*, the code that let the kubelet drive Docker
> > Engine. The kubelet now talks to a container runtime through the CRI (Container
> > Runtime Interface): usually containerd or CRI-O. To use Docker Engine, you need the
> > separate [cri-dockerd](https://github.com/Mirantis/cri-dockerd) adapter. Check the
> > runtime of your nodes with:
> > ```bash
> > kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.containerRuntimeVersion}'
> > ```

## Kubernetes versioning and cadence

- Kubernetes versions use *semantic versioning*: MAJOR.MINOR.PATCH.
- A new *patch* release comes out when needed, usually about once a month. When a
  critical bug or vulnerability is found, a patch release follows as fast as possible.
  See the [patch release schedule](https://kubernetes.io/releases/patch-releases/).
- A new *minor* release comes out about every four months, three times a year.
- At any time, the three latest *minor* releases are maintained. Each *minor* release
  gets patches for about 14 months: 12 months of support, then 2 months to upgrade.

> [!note] Release cadence
> Since Kubernetes 1.22 there are three minor releases per year, each supported for
> about 14 months. See [Releases](https://kubernetes.io/releases/).

## Kubernetes version compatibility

*Must my version of `kubectl` match my cluster version exactly?*

- No. `kubectl` can be one minor version older or newer than the cluster. If the
  cluster runs 1.36.X, `kubectl` can be 1.35.Y, 1.36.Y or 1.37.Y.
- Things *might* work with larger differences, but they will probably fail at random.
  Be careful.
- `kubectl version` warns you when the difference is too large:
  ```
  Warning: version difference between client (1.35) and server (1.37) exceeds the supported minor version skew of +/-1
  ```
- Older `kubectl` versions failed with errors like this one instead:
  ```
  error: SchemaError(io.k8s.api.autoscaling.v2beta1.ExternalMetricStatus):
  invalid object doesn't have additional properties
  ```
- Read [the version skew policy](https://kubernetes.io/releases/version-skew-policy/#kubectl)
  for the whole story. It also covers the other components: for example, a kubelet can
  be up to three minor versions older than the API server, but never newer.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/versions-k8s.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/versions-k8s.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Versions, release cadence and Docker support brought up to date, with corrections.

<!-- uplink -->
Part of [[kubernetes/concepts/index|Concepts]].
