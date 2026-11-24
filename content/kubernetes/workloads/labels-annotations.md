---
title: "Labels and annotations"
description: "Labels and annotations on Kubernetes resources: viewing, setting, selecting, and their size limits"
tags: [kubernetes, kubectl]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/labels-annotations.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Labels and annotations

Most Kubernetes resources can have *labels* and *annotations*. Both are key-value
pairs of strings, with some limits on keys and values, explained at the end of this
page.

You can add, change, and remove labels and annotations at any time. There are many
ways to do it:

- the `kubectl edit` command;
- the `kubectl label` and `kubectl annotate` commands;
- many others: `kubectl apply -f`, `kubectl patch`, and so on.

## Viewing labels and annotations

Let's see what we get when we create a Deployment.

> [!example] Hands-on
> - Create a Deployment:
>   ```bash
>   kubectl create deployment clock --image=jpetazzo/clock
>   ```
>
> - Look at its annotations and labels:
>   ```bash
>   kubectl describe deployment clock
>   ```

## Labels and annotations for our Deployment

We see one label:

```
Labels: app=clock
```

`kubectl create deployment` added it.

We also see one annotation:

```
Annotations: deployment.kubernetes.io/revision: 1
```

The Deployment uses it to keep track of its successive versions during rolling
updates.

## And for the related Pod?

Now let's find the Pod that the Deployment created, and check it too.

> [!example] Hands-on
> - Find the name of the Pod:
>   ```bash
>   kubectl get pods
>   ```
>
> - Display its information:
>   ```bash
>   kubectl describe pod clock-xxxxxxxxxx-yyyyy
>   ```

## Labels and annotations for our Pod

We see two labels:

```
Labels: app=clock
        pod-template-hash=xxxxxxxxxx
```

`app=clock` also comes from `kubectl create deployment`: it is in the Pod template.

The ReplicaSet added `pod-template-hash`. During a rolling update, each set of Pods
gets a different hash.

There are no annotations:

```
Annotations: <none>
```

## Selectors

A *selector* is an expression that matches labels. It limits a command to the
objects that have *at least* all these labels.

> [!example] Hands-on
> - List all the Pods with at least `app=clock`:
>   ```bash
>   kubectl get pods --selector=app=clock
>   ```
>
> - List all the Pods with a label `app`, whatever its value:
>   ```bash
>   kubectl get pods --selector=app
>   ```

## Setting labels and annotations

The easiest way is `kubectl label` and `kubectl annotate`.

> [!example] Hands-on
> - Set a label on the `clock` Deployment:
>   ```bash
>   kubectl label deployment clock color=blue
>   ```
>
> - Check it out:
>   ```bash
>   kubectl describe deployment clock
>   ```

`kubectl annotate` works the same way. A key followed by `-` removes the label or
annotation:

```bash
kubectl annotate deployment clock owner="the clock team"
kubectl label deployment clock color-
```

## Other ways to view labels

`kubectl get` has two useful flags to check labels:

- `kubectl get --show-labels` shows all labels;
- `kubectl get -L xyz` adds a column with the value of label `xyz`.

> [!example] Hands-on
> - List all the labels that we have on Pods:
>   ```bash
>   kubectl get pods --show-labels
>   ```
>
> - List the value of label `app` on these Pods:
>   ```bash
>   kubectl get pods -L app
>   ```

> [!note]- Extra details
> ## More on selectors
>
> A selector with several labels means "match at least all these labels". For
> example: `--selector=app=frontend,release=prod`.
>
> `--selector` can be shortened to `-l` (for **l**abels).
>
> Selectors can also be negative. For example: `--selector=app!=clock`.
>
> Most `kubectl` commands accept a selector: `kubectl delete`, `kubectl label`, and
> others.

## Labels on several kinds of objects

`--show-labels` also works when you list several kinds of objects at once.

> [!example] Hands-on
> - Show labels for Pods, ReplicaSets, Deployments, Services, and Nodes:
>   ```bash
>   kubectl get --show-labels po,rs,deploy,svc,no
>   ```

## Differences between labels and annotations

The *key* of a label or an annotation has an optional prefix, then a name:
`prefix/name`.

- The name must start and end with a letter or a digit.
- In between, it can also have `.`, `-`, and `_`.
- The name is up to 63 characters.
- The prefix is a DNS subdomain (lowercase, like `example.com`), up to 253
  characters. The full key is then up to 253 + `/` + 63 characters.

Label *values* follow the same rules as names: up to 63 characters. They can also be
empty.

Annotation *values* can be any string, even long text or JSON. To store binary data,
encode it first (with base64, for example).

> [!note] Size limit
> All the annotations of one object together are limited to 256 KiB. A few dozen
> kilobytes is fine. A larger annotation is rejected by the API server.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/labels-annotations.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/labels-annotations.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; `kubectl annotate` and label removal examples added; the
> annotation size limit corrected.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
