---
title: "Charts using other charts"
description: "Helm charts can have dependencies on other charts"
tags: [kubernetes, helm]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/helm-dependencies.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Charts using other charts

- Helm charts can have *dependencies* on other charts

- These dependencies will help us to share or reuse components

  (so that we write and maintain less manifests, less templates, less code!)

- As an example, we will use a community chart for Redis

- This will help people who write charts, and people who use them

- ... And potentially remove a lot of code! ✌️

## Redis in DockerCoins

- In the DockerCoins demo app, we have 5 components:

  - 2 internal webservices
  - 1 worker
  - 1 public web UI
  - 1 Redis data store

- Every component is running some custom code, except Redis

- Every component is using a custom image, except Redis

  (which is using the official `redis` image)

- Could we use a standard chart for Redis?

- Yes! Dependencies to the rescue!

## Adding our dependency

- First, we will add the dependency to the `Chart.yaml` file

- Then, we will ask Helm to download that dependency

- We will also *lock* the dependency

  (lock it to a specific version, to ensure reproducibility)

## Declaring the dependency

- First, let's edit `Chart.yaml`

> [!example] Hands-on
> - In `Chart.yaml`, fill the `dependencies` section:
>   ```yaml
>   dependencies:
>     - name: redis
>       version: 28.3.12
>       repository: https://charts.bitnami.com/bitnami
>       condition: redis.enabled
>   ```

> [!warning] Correction
> The original used version `11.0.5`. Bitnami keeps only recent versions in its
> chart index, and there is no 11.x left. Use a version that
> `helm search repo bitnami/redis --versions` shows (this page was tested with
> 28.3.12). The chart's default image is `bitnami/redis:latest`.

Where do that `repository` and `version` come from?

We're assuming here that we did our research,
or that our resident Helm expert advised us to
use Bitnami's Redis chart.

## Conditions

- The `condition` field gives us a way to enable/disable the dependency:
  ```yaml
  condition: redis.enabled
  ```

- Here, we can disable Redis with the Helm flag `--set redis.enabled=false`

  (or set that value in a `values.yaml` file)

- Of course, this is mostly useful for *optional* dependencies

  (otherwise, the app ends up being broken since it'll miss a component)

## Lock & Load!

- After adding the dependency, we ask Helm to pin and download it

> [!example] Hands-on
> - Ask Helm:
>   ```bash
>   helm dependency update
>   ```
>
>   (Or `helm dep up`)

- This will create `Chart.lock` and fetch the dependency

## What's `Chart.lock`?

- This is a common pattern with dependencies

  (see also: `Gemfile.lock`, `package-lock.json`, and many others)

- This lets us define loose dependencies in `Chart.yaml`

  (e.g. "version 28.whatever, but below 29")

- But have the exact version used in `Chart.lock`

- This ensures reproducible deployments

- `Chart.lock` can (should!) be added to our source tree

- `Chart.lock` can (should!) regularly be updated

## Loose dependencies

- Here is an example of loose version requirement:
  ```yaml
  dependencies:
    - name: redis
      version: ">=28, <29"
      repository: https://charts.bitnami.com/bitnami
  ```

- This makes sure that we have the most recent version in the 28.x train

- ... But without upgrading to version 29.x

  (because it might be incompatible)

## `build` vs `update`

- Helm actually offers two commands to manage dependencies:

  `helm dependency build` = fetch dependencies listed in `Chart.lock`

  `helm dependency update` = update `Chart.lock` (and run `build`)

- When the dependency gets updated, we can/should:

  - `helm dep up` (update `Chart.lock` and fetch new chart)

  - test!

  - if everything is fine, `git add Chart.lock` and commit

## Where are my dependencies?

- Dependencies are downloaded to the `charts/` subdirectory

- When they're downloaded, they stay in compressed format (`.tgz`)

- Should we commit them to our code repository?

- Pros:

  - more resilient to internet/mirror failures/decommissioning

- Cons:

  - can add a lot of weight to the repo if charts are big or change often

  - this can be solved by extra tools like git-lfs

## Dependency tuning

- DockerCoins expects the `redis` Service to be named `redis`

- Our Redis chart uses a different Service name by default

- Service name is `{{ printf "%s-master" (include "common.names.fullname" .) }}`

- `common.names.fullname` comes from Bitnami's `common` chart (a dependency of the
  Redis chart), and looks like this:
  ```
  {{- define "common.names.fullname" -}}
  {{- if .Values.fullnameOverride -}}
  {{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
  {{- else -}}
  [...]
  {{- end -}}
  {{- end -}}
  ```

- How do we fix this?

## Setting dependency variables

- If we set `fullnameOverride` to `redis`:

  - the `include` will output `redis`

  - the Service name will be `redis-master`

- A parent chart can set values for its dependencies

- For example, in the parent's `values.yaml`:

  ```yaml
  redis:                       # Name of the dependency
    fullnameOverride: redis    # Value passed to redis
    architecture: standalone   # Other values passed to redis
    auth:
      enabled: false
  ```

> [!warning] Correction
> The original set `cluster.enabled: false`, the 11.x name for "no replicas".
> Current versions use `architecture: standalone`. They also enable a password by
> default; DockerCoins' worker connects without one, hence `auth.enabled: false`.

- User can also set variables with `--set=` or with `--values=`

> [!note]- Extra details
> ## Passing templates
>
> - We can even pass template `{{ include "template.name" }}`, but warning:
>
>    - need to be evaluated with the `tpl` function, on the child side
>
>    - evaluated in the context of the child, with no access to parent variables

## Getting rid of the `-master`

- Even if we set that `fullnameOverride`, the Service name will be `redis-master`

- To remove the `-master` suffix, we need to edit the chart itself

- To edit the Redis chart, we need to *embed* it in our own chart

- We need to:

  - decompress the chart

  - adjust `Chart.yaml` accordingly

## Embedding a dependency

> [!example] Hands-on
> - Decompress the chart:
>   ```bash
>   cd charts
>   tar zxf redis-*.tgz
>   rm redis-*.tgz
>   cd ..
>   ```
>
>   > [!warning] Correction
>   > The original kept the archive. Then `charts/` holds two charts named `redis`
>   > (the archive and the folder), and Helm may install the unedited archive: in our
>   > tests, `helm template` used the edited folder but `helm install` did not.
>
> - Edit `Chart.yaml` and update the `dependencies` section:
>   ```yaml
>   dependencies:
>     - name: redis
>       version: '*' # No need to constrain the version: it comes from local files
>   ```
>
> - Run `helm dep update`

## Updating the dependency

- Now we can edit the Service name

  (it is in `charts/redis/templates/master/service.yaml`)

- Then try to deploy the whole chart!

## Embedding a dependency multiple times

- What if we need multiple copies of the same subchart?

  (for instance, if we need two completely different Redis servers)

- We can declare a dependency multiple times, and specify an `alias`:
  ```yaml
  dependencies:
    - name: redis
      version: '*'
      alias: querycache
    - name: redis
      version: '*'
      alias: celeryqueue
  ```

- `.Chart.Name` will be set to the `alias`

> [!note]- Extra details
> ## Determining if we're in a subchart
>
> - `.Chart.IsRoot` indicates if we're in the top-level chart or in a sub-chart
>
> - Useful in charts that are designed to be used standalone or as dependencies
>
> - Example: generic chart
>
>   - when used standalone (`.Chart.IsRoot` is `true`), use `.Release.Name`
>
>   - when used as a subchart e.g. with multiple aliases, use `.Chart.Name`

> [!note]- Extra details
> ## Compatibility with Helm 2
>
> - Chart `apiVersion: v1` is the only version supported by Helm 2
>
> - Chart v1 is also supported by Helm 3
>
> - Use v1 if you want to be compatible with Helm 2
>
> - Instead of `Chart.yaml`, dependencies are defined in `requirements.yaml`
>
>   (and we should commit `requirements.lock` instead of `Chart.lock`)

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/helm-dependencies.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/helm-dependencies.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> Redis chart updated from 11.0.5 to 28.3.12 (version, value names, template
> names and paths), missing `rm` of the unpacked archive added, tested with Helm 4.3.

<!-- uplink -->
Part of [[kubernetes/packaging/index|Packaging with Helm]].
