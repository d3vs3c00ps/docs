---
title: "Prometheus and Grafana"
description: "What if we want metrics retention, view graphs, trends?"
tags: [kubernetes, observability, monitoring, prometheus, grafana]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/prometheus-stack.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Prometheus and Grafana

- What if we want metrics retention, view graphs, trends?

- A very popular combo is Prometheus+Grafana:

  - Prometheus as the "metrics engine"

  - Grafana to display comprehensive dashboards

- Prometheus also has an alert-manager component to trigger alerts

  (we won't talk about that one)

## Installing Prometheus and Grafana

- A complete metrics stack needs at least:

  - the Prometheus server (collects metrics and stores them efficiently)

  - a collection of *exporters* (exposing metrics to Prometheus)

  - Grafana

  - a collection of Grafana dashboards (building them from scratch is tedious)

- The Helm chart `kube-prometheus-stack` combines all these elements

- ... So we're going to use it to deploy our metrics stack!

## Installing `kube-prometheus-stack`

- Let's install that stack *directly* from its repo

  (without doing `helm repo add` first)

- Let's use the same name for the release, the namespace...:
  ```bash
    helm upgrade --install kube-prometheus-stack kube-prometheus-stack \
      --namespace kube-prometheus-stack --create-namespace \
      --repo https://prometheus-community.github.io/helm-charts --version 92.18.0
  ```

  (`--version` pins the chart; without it, Helm takes the latest)

- This will take a minute...

- Then check what was installed:
  ```bash
  kubectl get all --namespace kube-prometheus-stack
  ```

## Exposing Grafana

- Let's do this only if we have an ingress controller and a domain name!

  (we can also skip this and come back to it later)

- Create an Ingress for Grafana:
  ```bash
    kubectl create ingress --namespace kube-prometheus-stack grafana \
      --rule=grafana.example.com/*=kube-prometheus-stack-grafana:80
  ```

  (replace `example.com` with *your* domain name)

- Connect to Grafana

## Exposing Grafana without Ingress

- What if we don't have an ingress controller?

- We can use a `NodePort` service instead

- Option 1: `kubectl edit` or `kubectl patch` the service

  (it's `kube-prometheus-stack-grafana`)

- Option 2: pass the correct value to `helm upgrade --install`

  (check the [chart values][kps-values] to find the right one!)

- We can also use `kubectl port-forward`, or a `LoadBalancer` service!

> [!note]- Answer: the chart value
> Grafana is a subchart, so its values are under `grafana:`:
> ```bash
> helm upgrade kube-prometheus-stack kube-prometheus-stack \
>   --namespace kube-prometheus-stack --reuse-values \
>   --repo https://prometheus-community.github.io/helm-charts --version 92.18.0 \
>   --set grafana.service.type=NodePort
> ```

[kps-values]: https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack?modal=values

## Grafana credentials

- What could the login and password be?

- Let's look at the Secrets available in the namespace:
  ```bash
  kubectl get secrets --namespace kube-prometheus-stack
  ```

- There is a `kube-prometheus-stack-grafana` that looks promising!

- Decode the Secret:
  ```bash
    kubectl get secret --namespace kube-prometheus-stack \
      kube-prometheus-stack-grafana -o json | jq '.data | map_values(@base64d)'
  ```

- If you don't have the `jq` tool mentioned above, don't worry...

- The login is `admin`; the password is in `admin-password`

> [!warning] Correction
> The original said the login/password is hardcoded to `admin`/`prom-operator`. That
> was true for old chart versions. Chart 92.18.0 generates a random password at
> install time, and `admin`/`prom-operator` is refused. Read it from the Secret, or
> set your own with `--set grafana.adminPassword=...`.

## Grafana dashboards

- Once logged in, open the menu and click on "Dashboards"

  (in old Grafana versions, it was a four-squares icon with a "Manage" entry)

- Then click on "Kubernetes / Compute Resources / Cluster"

- This gives us a breakdown of resource usage by Namespace

- Feel free to explore the other dashboards!

- There won't be much data right now, but there will be more later

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/prometheus-stack.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/prometheus-stack.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> chart version pinned, the Grafana password and menu updated, NodePort answer
> added, tested with chart 92.18.0 on kind.

<!-- uplink -->
Part of [[kubernetes/observability/index|Observability and scaling]].
