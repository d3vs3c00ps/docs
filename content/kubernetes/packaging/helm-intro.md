---
title: "Managing stacks with Helm"
description: "Helm is a (kind of!) package manager for Kubernetes"
tags: [kubernetes, helm]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/helm-intro.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Managing stacks with Helm

- Helm is a (kind of!) package manager for Kubernetes

- We can use it to:

  - find existing packages (called "charts") created by other folks

  - install these packages, configuring them for our particular setup

  - package our own things (for distribution or for internal use)

  - manage the lifecycle of these installs (rollback to previous version etc.)

- It's a "CNCF graduate project", indicating a certain level of maturity

  (more on that later)

## Helm features

- With Helm, we create "charts"

- These charts can be used internally or distributed publicly

- Public charts can be indexed through the [Artifact Hub](https://artifacthub.io/)

- This gives us a way to find and install other folks' charts

- Helm also gives us ways to manage the lifecycle of what we install:

  - keep track of what we have installed

  - upgrade versions, change parameters, roll back, uninstall

- Furthermore, even if it's not "the" standard, it's definitely "a" standard!

## CNCF graduation status

- On April 30th 2020, Helm was the 10th project to *graduate* within the CNCF

  (alongside Containerd, Prometheus, and Kubernetes itself)

- This is an acknowledgement by the CNCF for projects that

  *demonstrate thriving adoption, an open governance process,
  <br/>
  and a strong commitment to community, sustainability, and inclusivity.*

- See [CNCF announcement](https://www.cncf.io/announcement/2020/04/30/cloud-native-computing-foundation-announces-helm-graduation/)
  and [Helm announcement](https://helm.sh/blog/celebrating-helms-cncf-graduation/)

- In other words: Helm is here to stay

## Helm concepts

- `helm` is a CLI tool

- It is used to find, install, upgrade *charts*

- A chart is an archive containing templatized YAML bundles

- Charts are versioned

- Charts can be stored on private or public repositories

## Differences between charts and packages

- A package (deb, rpm...) contains binaries, libraries, etc.

- A chart contains YAML manifests

  (the binaries, libraries, etc. are in the images referenced by the chart)

- On most distributions, a package can only be installed once

  (installing another version replaces the installed one)

- A chart can be installed multiple times

- Each installation is called a *release*

- This allows to install e.g. 10 instances of MongoDB

  (with potentially different versions and configurations)

> [!note]- Extra details
> ## Wait a minute ...
>
> *But, on my openSUSE system, I have several versions of Python.
> <br/>
> Also, I have multiple versions of the Postgres database engine!*
>
> Yes!
>
> But they have different package names:
>
> - `python311`, `python313`
>
> - `postgresql16`, `postgresql17`
>
> Good to know: the Postgres packages on openSUSE include
> provisions to deploy multiple Postgres servers on the
> same system, but it's an exception (and it's a lot of
> work done by the package maintainer, not by the `rpm`
> or `zypper` tools).

## Helm 2 vs Helm 3

- Helm 3 was released [November 13, 2019](https://helm.sh/blog/helm-3-released/)

- Charts remain compatible between Helm 2 and Helm 3

- The CLI is very similar (with minor changes to some commands)

- The main difference is that Helm 2 uses `tiller`, a server-side component

- Helm 3 doesn't use `tiller` at all, making it simpler (yay!)

- If you see references to `tiller` in a tutorial, documentation... that doc is obsolete!

> [!note] Helm 4
> Helm 4 is the current major version. Charts written for Helm 3 still work, and
> the commands on this page are the same. They were tested with Helm 4.3.

> [!note]- Extra details
> ## What was the problem with `tiller`?
>
> - With Helm 3:
>
>   - the `helm` CLI communicates directly with the Kubernetes API
>
>   - it creates resources (deployments, services...) with our credentials
>
> - With Helm 2:
>
>   - the `helm` CLI communicates with `tiller`, telling `tiller` what to do
>
>   - `tiller` then communicates with the Kubernetes API, using its own credentials
>
> - This indirect model caused significant permissions headaches
>
> - It also made it more complicated to embed Helm in other tools

## Installing Helm

- If the `helm` CLI is not installed in your environment, install it

> [!example] Hands-on
> - Check if `helm` is installed:
>   ```bash
>   helm
>   ```
>
> - If it's not installed, run the following command:
>   ```bash
>   curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 \
>   | bash
>   ```

> [!note] `get-helm-4`
> `get-helm-3` installs Helm 3. The old `get` script installs Helm 2, which has had no
> support since 2020, and its `tiller`.

## Charts and repositories

- A *repository* (or repo in short) is a collection of charts

- It's just a bunch of files

  (they can be hosted by a static HTTP server, or on a local directory)

- We can add "repos" to Helm, giving them a nickname

- The nickname is used when referring to charts on that repo

  (for instance, if we try to install `hello/world`, that
  means the chart `world` on the repo `hello`; and that repo
  `hello` might be something like https://blahblah.hello.io/charts/)

## How to find charts

- Go to the [Artifact Hub](https://artifacthub.io/packages/search?kind=0) (https://artifacthub.io)

- Or use `helm search hub ...` from the CLI

- Let's try to find a Helm chart for something called "OWASP Juice Shop"!

  (it is a famous demo app used in security challenges)

## Finding charts from the CLI

- We can use `helm search hub <keyword>`

> [!example] Hands-on
> - Look for the OWASP Juice Shop app:
>   ```bash
>   helm search hub owasp juice
>   ```
>
> - Since the URLs are truncated, try with the YAML output:
>   ```bash
>   helm search hub owasp juice -o yaml
>   ```

Then go to → https://artifacthub.io/packages/helm/juice-shop/juice-shop

## Finding charts on the web

- We can also use the Artifact Hub search feature

> [!example] Hands-on
> - Go to https://artifacthub.io/
>
> - In the search box on top, enter "owasp juice"
>
> - Click on the "juice-shop" result (not "multi-juicer" or "juicy-ctf")

## Installing the chart

- Click on the "Install" button, it will show instructions

> [!example] Hands-on
> - Install the chart:
>   ```bash
>   helm install my-juice-shop oci://ghcr.io/securecodebox/helm/juice-shop
>   ```

> [!note] OCI charts need no `helm repo add`
> The chart is published in an OCI registry: an `oci://` reference needs no
> `helm repo add`.

Note: with a classic (HTTP) chart repository, it is also possible to install a
chart directly, with `--repo https://...`

## Charts and releases

- "Installing a chart" means creating a *release*

- In the previous example, the release was named "my-juice-shop"

- We can also use `--generate-name` to ask Helm to generate a name for us

> [!example] Hands-on
> - List the releases:
>   ```bash
>   helm list
>   ```
>
> - Check that we have a `my-juice-shop-...` Pod up and running:
>   ```bash
>   kubectl get pods
>   ```

## Viewing resources of a release

- This specific chart labels all its resources with an `app.kubernetes.io/instance` label

- We can use a selector to see these resources

> [!example] Hands-on
> - List all the resources created by this release:
>   ```bash
>   kubectl get all --selector=app.kubernetes.io/instance=my-juice-shop
>   ```

Note: this label wasn't added automatically by Helm.
<br/>
It is defined in that chart. In other words, not all charts will provide this label.

## Configuring a release

- By default, the `juice-shop` chart creates a service of type `ClusterIP`

- We would like to change that to a `NodePort`

- We could use `kubectl edit service my-juice-shop`, but ...

  ... our changes would get overwritten next time we update that chart!

- Instead, we are going to *set a value*

- Values are parameters that the chart can use to change its behavior

- Values have default values

- Each chart is free to define its own values and their defaults

## Checking possible values

- We can inspect a chart with `helm show` or `helm inspect`

> [!example] Hands-on
> - Look at the README for the app:
>   ```bash
>   helm show readme oci://ghcr.io/securecodebox/helm/juice-shop
>   ```
>
> - Look at the values and their defaults:
>   ```bash
>   helm show values oci://ghcr.io/securecodebox/helm/juice-shop
>   ```

The `values` may or may not have useful comments.

The `readme` may or may not have (accurate) explanations for the values.

(If we're unlucky, there won't be any indication about how to use the values!)

## Setting values

- Values can be set when installing a chart, or when upgrading it

- We are going to update `my-juice-shop` to change the type of the service

> [!example] Hands-on
> - Update `my-juice-shop`:
>   ```bash
>   helm upgrade my-juice-shop oci://ghcr.io/securecodebox/helm/juice-shop \
>     --set service.type=NodePort
>   ```

Note that we have to specify the chart that we use (the `oci://` reference),
even if we just want to update some values.

We can set multiple values. If we want to set many values, we can use `-f`/`--values` and pass a YAML file with all the values.

All unspecified values will take the default values defined in the chart.

## Connecting to the Juice Shop

- Let's check the app that we just installed

> [!example] Hands-on
> - Check the node port allocated to the service:
>   ```bash
>   kubectl get service my-juice-shop
>   PORT=$(kubectl get service my-juice-shop -o jsonpath={..nodePort})
>   ```
>
> - Connect to it, from one of the nodes:
>   ```bash
>   curl localhost:$PORT/
>   ```

On a [[kubernetes/cluster-setup/kind|kind]] cluster, the nodes are containers: run
the `curl` inside one, for instance with `docker exec kind-control-plane curl ...`.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/helm-intro.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/helm-intro.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> chart repository moved to its OCI registry, install script updated to Helm 4,
> commands tested with Helm 4.3 on Kubernetes 1.37.

<!-- uplink -->
Part of [[kubernetes/packaging/index|Packaging with Helm]].
