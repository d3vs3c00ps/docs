---
title: "Namespaces"
description: "Namespaces: creating them, switching the active one, DNS between Namespaces, and why they do not isolate workloads"
tags: [kubernetes, kubectl]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/namespaces.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Namespaces

Resources like Pods, Deployments, and Services exist in *Namespaces*. So far, we have
probably used the `default` Namespace. We can create other Namespaces to organize our
resources.

## Use-cases

- A "dev" cluster where each developer has their own Namespace. Each developer has
  access to their own Namespace only, not to the Namespaces of other people.
- A cluster with one `production` and one `staging` Namespace. Similar applications
  run in each of them, but with different sizes.
- A "production" cluster with one Namespace per application, or one Namespace per
  component of a bigger application.
- A "production" cluster with many instances of the same application. For example, a
  SaaS (software as a service) application with one instance per customer.

## Pre-existing Namespaces

A new cluster usually has these four Namespaces:

- `default`: the first Namespace for our applications. It also holds the
  `kubernetes` Service, which points to the API server.
- `kube-system`: for the control plane.
- `kube-public`: readable by everyone, even without authentication. On clusters set up
  with kubeadm, it holds the `cluster-info` ConfigMap, used for cluster discovery.
- `kube-node-lease` (Kubernetes 1.14 and later): holds one Lease object per node. The
  nodes use them to send their heartbeats.

Over time, we will almost certainly create more Namespaces. Some installers add their
own, too: kind adds `local-path-storage`, for its storage provisioner.

> [!warning] Correction
> The original page said that `kube-public` contains one ConfigMap. Since Kubernetes
> 1.21, every Namespace also gets a `kube-root-ca.crt` ConfigMap, with the cluster's
> CA (certificate authority) certificate. So `kube-public` has two ConfigMaps.

## Creating a Namespace

There are two ways to create a Namespace.

> [!example] Hands-on
> - First, with `kubectl create namespace`:
>   ```bash
>   kubectl create namespace blue
>   ```
>
> - Then, with a YAML snippet:
>   ```bash
>   kubectl apply -f- <<EOF
>   apiVersion: v1
>   kind: Namespace
>   metadata:
>     name: green
>   EOF
>   ```

## Using namespaces

Most `kubectl` commands accept a `-n` or `--namespace` flag.

> [!example] Hands-on
> - Create a Deployment in the `blue` Namespace:
>   ```bash
>   kubectl create deployment purple --image jpetazzo/color --namespace blue
>   ```
>
> - Check the Pods that were just created:
>   ```bash
>   kubectl get pods --all-namespaces
>   kubectl get pods --all-namespaces --selector app=purple
>   ```

`-A` is short for `--all-namespaces`.

## Switching the active Namespace

We can change the "active" Namespace. This is useful when we work in one Namespace for
a while:

- it is easier than passing `--namespace ...` all the time;
- it helps to avoid mistakes, like `kubectl delete -f foo.yaml` in the wrong
  Namespace.

There are three ways to switch Namespaces.

## Method 1 (kubens/kns)

To switch to the `blue` Namespace, run:

```bash
kubens blue
```

- `kubens` is sometimes renamed or aliased to `kns`, to type even less.
- `kubens -` switches back to the previous Namespace.
- Pros: probably the easiest method.
- Cons: `kubens` is an extra tool that you need to install.

## Method 2 (edit kubeconfig)

Edit `~/.kube/config`. The context in use should have a `namespace:` field. If we
never changed the Namespace, the field is not there yet: add it, or change the
Namespace once with another method.

When we change that field, `kubectl` uses the new Namespace from then on.

- Pros: quite easy, and needs no extra tools.
- Cons: the file can have several `namespace:` fields (one per context), and it is
  hard to automate.

## Method 3 (kubectl config)

To switch to the `blue` Namespace, run:

```bash
kubectl config set-context --current --namespace blue
```

This command edits the kubeconfig file for us. It is exactly what `kubens` does
behind the scenes.

- Pros: it always works, as long as we have `kubectl`.
- Cons: it is long to type.

To see the active Namespace:

```bash
kubectl config view --minify --output 'jsonpath={..namespace}'
```

> [!note]- Extra details
> ## What are contexts?
>
> A context is a cluster, a user, and a Namespace.
>
> Contexts make it quick to switch between clusters: dev and prod, different
> applications, different customers, and so on.
>
> They also make it quick to switch between identities. For example, a developer
> with "regular" access, and a cluster-admin.
>
> Switch context with `kubectl config use-context`, or with `kubectx` (`kctx`).
>
> You can also switch to another kubeconfig file, with `--kubeconfig` or the
> `KUBECONFIG` environment variable.

> [!note]- Extra details
> ## What's in a context
>
> `kubectl config get-contexts` shows these columns:
>
> - NAME is a string that identifies the context.
> - CLUSTER is a reference to a cluster: the API endpoint URL, and an optional
>   certificate.
> - AUTHINFO is a reference to the credentials to use: a TLS client certificate, a
>   token, or something else.
> - NAMESPACE is the Namespace. An empty string means `default`.

## Namespaces, Services, and DNS

When a Service is created, a record is added to the Kubernetes DNS. For the Service
`auth` in the Namespace `staging`, it is usually:

`auth.staging.svc.cluster.local`

By default, Pods resolve names in the domain of their own Namespace. For example, a
Pod in the Namespace `staging` has this search list in its `/etc/resolv.conf`:

`search staging.svc.cluster.local svc.cluster.local cluster.local`

## Pods connecting to Services

Let's say that we are in the Namespace `staging`, there is a Service named `auth`, and
our code runs in a Pod in that same Namespace. Our code can:

- connect to the Service `auth` in the same Namespace with `http://auth/`;
- connect to the Service `auth` in another Namespace (`prod`, for example) with
  `http://auth.prod`;
- or with `http://auth.prod.svc`, or `http://auth.prod.svc.cluster.local`.

## Deploying multiple instances of a stack

If all the containers of a stack use DNS to find each other, we can deploy that stack
the same way in several Namespaces. Each copy of the stack talks to the Services in
its own Namespace.

For example, we can deploy several copies of DockerCoins, one per Namespace. We do not
change a single line of code in DockerCoins, and not a single line in our YAML
manifests.

Docker Compose does something similar, but each stack gets its own Docker "network"
instead of a Kubernetes Namespace.

## Namespaces and isolation

Namespaces *do not* isolate workloads. By default, Pods in the `prod` and `staging`
Namespaces can talk to each other.

*Network policies* provide actual isolation. They are resources, like Deployments,
Services, or Namespaces. They say which traffic is allowed:

- between Pods;
- from Pods to the outside world;
- and from the outside world to Pods.

See [[kubernetes/networking/netpol|Network policies]].

## `kubens` and `kubectx`

These tools are available from https://github.com/ahmetb/kubectx. They started as
small shell scripts, and are now Go programs.

On the course's training clusters, they were installed as `kns` and `kctx`. The short
names are faster to type, and avoid completion clashes between `kubectx` and
`kubectl`.

## `kube-ps1`

It is easy to lose track of the current cluster, context, and Namespace. `kube-ps1`
helps: it shows them in our shell prompt. It was installed on the course's training
clusters, and it is in [shpod](https://github.com/jpetazzo/shpod).

It gives a prompt like this one:

```
[192.0.2.10] (⎈|kubernetes-admin@kubernetes:default) docker@node1 ~
```

The `(⎈|context:namespace)` part comes from `kube-ps1`. It is highly recommended if
you work with several contexts or Namespaces.

## Installing `kube-ps1`

It is a shell script, available from https://github.com/jonmosco/kube-ps1. Source it
from your shell's profile or rc file, and add `$(kube_ps1)` to your prompt. The
[installation instructions](https://github.com/jonmosco/kube-ps1#installing) depend on
the platform and the shell. For bash:

```bash
source /path/to/kube-ps1.sh
PS1='[\u@\h \W $(kube_ps1)]\$ '
```

Once loaded, it defines the shell functions `kube_ps1`, `kubeon`, and `kubeoff`.
`kubeon` and `kubeoff` turn it on and off when needed.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/namespaces.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/namespaces.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; heredoc example fixed; `kube-public` content corrected;
> commands to show the active Namespace and to set up `kube-ps1` added.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
