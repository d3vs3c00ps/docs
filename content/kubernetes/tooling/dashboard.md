---
title: "The Kubernetes dashboard"
description: "Kubernetes resources can also be viewed with a web dashboard"
tags: [kubernetes, tooling]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/dashboard.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# The Kubernetes dashboard

> [!warning] The Kubernetes Dashboard is archived
> The project was archived in January 2026 and is no longer maintained
> (it now lives at [kubernetes-retired/dashboard](https://github.com/kubernetes-retired/dashboard)).
> Its README recommends [Headlamp](https://github.com/kubernetes-sigs/headlamp) instead.
> The manifests below pin dashboard v2.7.0, the last manifest-based release.
> They still work on Kubernetes 1.37, but they get no security fixes.

> [!important] These labs expect the upstream repository
> Commands below reference files by their path in a local clone. Get it with:
>
> ```bash
> git clone https://github.com/jpetazzo/container.training
> ```
>
> The manifests can also be browsed at the pinned commit
> [`56563629`](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2).

- Kubernetes resources can also be viewed with a web dashboard

- Dashboard users need to authenticate

  (typically with a token)

- The dashboard should be exposed over HTTPS

  (to prevent interception of the aforementioned token)

- Ideally, this requires obtaining a proper TLS certificate

  (for instance, with Let's Encrypt)

## Three ways to install the dashboard

- Our `k8s` directory has no less than three manifests!

- `dashboard-recommended.yaml`

  (purely internal dashboard; user must be created manually)

- `dashboard-with-token.yaml`

  (dashboard exposed with NodePort; creates an admin user for us)

- `dashboard-insecure.yaml` aka *YOLO*

  (dashboard exposed over HTTP; gives root access to anonymous users)

## `dashboard-insecure.yaml`

- This will allow anyone to deploy anything on your cluster

  (without any authentication whatsoever)

- **Do not** use this, except maybe on a local cluster

  (or a cluster that you will destroy a few minutes later)

- On "normal" clusters, use `dashboard-with-token.yaml` instead!

## What's in the manifest?

- The dashboard itself, serving plain HTTP

  (flags `--enable-insecure-login` and `--enable-skip-login`)

- A ClusterRoleBinding that gives `cluster-admin` to the dashboard's ServiceAccount

> [!example] Hands-on
> - Create all the dashboard resources, with the following command:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/dashboard-insecure.yaml
>   ```

## Connecting to the dashboard

> [!example] Hands-on
> - Check which port the dashboard is on:
>   ```bash
>   kubectl get svc --namespace=kubernetes-dashboard kubernetes-dashboard
>   ```

You'll want the `3xxxx` port.

> [!example] Hands-on
> - Connect to http://oneofournodes:3xxxx/

The dashboard will then ask you which authentication you want to use.

## Dashboard authentication

- We have three authentication options at this point:

  - token (associated with a role that has appropriate permissions)

  - kubeconfig (e.g. using the `~/.kube/config` file from `node1`)

  - "skip" (use the dashboard "service account")

- Let's use "skip": we're logged in!

> [!warning]
> Remember, we just added a backdoor to our Kubernetes cluster!

## Closing the backdoor

- Seriously, don't leave that thing running!

> [!example] Hands-on
> - Remove what we just created:
>   ```bash
>   kubectl delete -f ~/container.training/k8s/dashboard-insecure.yaml
>   ```

## The risks

- The steps that we just showed you are *for educational purposes only!*

- If you do that on your production cluster, people [can and will abuse it](https://redlock.io/blog/cryptojacking-tesla)

- For an in-depth discussion about securing the dashboard,
  <br/>
  check [this excellent post on Heptio's blog](https://blog.heptio.com/on-securing-the-kubernetes-dashboard-16b09b1b7aca)

## `dashboard-with-token.yaml`

- This is a less risky way to deploy the dashboard

- It's not completely secure, either:

  - we're using a self-signed certificate

  - this is subject to eavesdropping attacks

- Using `kubectl port-forward` or `kubectl proxy` is even better

## What's in the manifest?

- The dashboard itself (but exposed with a `NodePort`)

- A ServiceAccount with `cluster-admin` privileges

  (named `kubernetes-dashboard:cluster-admin`)

> [!example] Hands-on
> - Create all the dashboard resources, with the following command:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/dashboard-with-token.yaml
>   ```

## Obtaining the token

- The manifest creates a ServiceAccount

- It also creates a Secret of type `kubernetes.io/service-account-token`,
  named `cluster-admin-token`

- Kubernetes fills that Secret with a token for the ServiceAccount

> [!note] The Secret name
> Since Kubernetes 1.24, a ServiceAccount no longer gets a token Secret
> automatically. The manifest declares the Secret itself, so its name is exactly
> `cluster-admin-token`, with no random `-xxxxx` suffix.

> [!example] Hands-on
> - Display the token:
>   ```bash
>   kubectl --namespace=kubernetes-dashboard \
>     describe secret cluster-admin-token
>   ```

The token should start with `eyJ...` (it's a JSON Web Token).

## Connecting to the dashboard

> [!example] Hands-on
> - Check which port the dashboard is on:
>   ```bash
>   kubectl get svc --namespace=kubernetes-dashboard
>   ```

You'll want the `3xxxx` port.

> [!example] Hands-on
> - Connect to https://oneofournodes:3xxxx/

The certificate is self-signed, so the browser will warn. Plain HTTP on that port
does not work.

## Dashboard authentication

- Select "token" authentication

- Copy paste the token (starting with `eyJ...`) obtained earlier

- We're logged in!

## Other dashboards

- [Kube Web View](https://codeberg.org/hjacobs/kube-web-view)

  - read-only dashboard

  - optimized for "troubleshooting and incident response"

  - see [vision and goals](https://kube-web-view.readthedocs.io/en/latest/vision.html#vision) for details

- [Kube Ops View](https://codeberg.org/hjacobs/kube-ops-view)

  - "provides a common operational picture for multiple Kubernetes clusters"

# Security implications of `kubectl apply`

- When we do `kubectl apply -f <URL>`, we create arbitrary resources

- Resources can be evil; imagine a `deployment` that ...

  - starts bitcoin miners on the whole cluster

  - hides in a non-default namespace

  - bind-mounts our nodes' filesystem

  - inserts SSH keys in the root account (on the node)

  - encrypts our data and ransoms it

  - ☠️☠️☠️

## `kubectl apply` is the new `curl | sh`

- `curl | sh` is convenient

- It's safe if you use HTTPS URLs from trusted sources

- `kubectl apply -f` is convenient

- It's safe if you use HTTPS URLs from trusted sources

- Example: the official setup instructions for most pod networks

- It introduces new failure modes

  (for instance, if you try to apply YAML from a link that's no longer valid)

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/dashboard.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/dashboard.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> commands and claims corrected against the pinned manifests on Kubernetes 1.37,
> archive notice added.

<!-- uplink -->
Part of [[kubernetes/tooling/index|Tooling]].
