---
title: "Creating a basic chart"
description: "We are going to show a way to create a very simplified chart"
tags: [kubernetes, helm]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/helm-create-basic-chart.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Creating a basic chart

> [!important] These labs expect the upstream repository
> Commands below reference files by their path in a local clone. Get it with:
>
> ```bash
> git clone https://github.com/jpetazzo/container.training
> ```
>
> The manifests can also be browsed at the pinned commit
> [`56563629`](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2).

- We are going to show a way to create a *very simplified* chart

- In a real chart, *lots of things* would be templatized

  (Resource names, service types, number of replicas...)

> [!example] Hands-on
> - Create a sample chart:
>   ```bash
>   helm create dockercoins
>   ```
>
> - Move away the sample templates and create an empty template directory:
>   ```bash
>   mv dockercoins/templates dockercoins/default-templates
>   mkdir dockercoins/templates
>   ```

## Adding the manifests of our app

- There is a convenient `dockercoins.yaml` in the repo

> [!example] Hands-on
> - Copy the YAML file to the `templates` subdirectory in the chart:
>   ```bash
>   cp ~/container.training/k8s/dockercoins.yaml dockercoins/templates
>   ```

- Note: it is probably easier to have multiple YAML files

  (rather than a single, big file with all the manifests)

- But that works too!

## Testing our Helm chart

- Our Helm chart is now ready

  (as surprising as it might seem!)

> [!example] Hands-on
> - Let's try to install the chart:
>   ```
>   helm install helmcoins dockercoins
>   ```
>   (`helmcoins` is the name of the release; `dockercoins` is the local path of the chart)

- If the application is already deployed, this will fail:

```
Error: INSTALLATION FAILED: unable to continue with install: Service "hasher" in namespace "default" exists and cannot be imported into the current release: invalid ownership metadata; label validation error: missing key "app.kubernetes.io/managed-by": must be set to "Helm"; annotation validation error: missing key "meta.helm.sh/release-name": must be set to "helmcoins"; annotation validation error: missing key "meta.helm.sh/release-namespace": must be set to "default"
```

> [!note] Updated error message
> The original showed Helm 3.0's message (`rendered manifests contain a resource
> that already exists`). Current Helm (tested with 4.3) names the label and the two
> annotations it is missing. If we add them to the existing resources, Helm
> *adopts* those resources into the release instead of failing.

## Switching to another namespace

- If there is already a copy of dockercoins in the current namespace:

  - we can switch with `kubens` or `kubectl config set-context`

  - we can also tell Helm to use a different namespace

> [!example] Hands-on
> - Create a new namespace:
>   ```bash
>   kubectl create namespace helmcoins
>   ```
>
> - Deploy our chart in that namespace:
>   ```bash
>   helm install helmcoins dockercoins --namespace=helmcoins
>   ```

## Helm releases are namespaced

- Let's try to see the release that we just deployed

> [!example] Hands-on
> - List Helm releases:
>   ```bash
>   helm list
>   ```

Our release doesn't show up!

We have to specify its namespace (or switch to that namespace).

## Specifying the namespace

- Try again, with the correct namespace

> [!example] Hands-on
> - List Helm releases in `helmcoins`:
>   ```bash
>   helm list --namespace=helmcoins
>   ```

## Checking our new copy of DockerCoins

- We can check the worker logs, or the web UI

> [!example] Hands-on
> - Retrieve the NodePort number of the web UI:
>   ```bash
>   kubectl get service webui --namespace=helmcoins
>   ```
>
> - Open it in a web browser
>
> - Look at the worker logs:
>   ```bash
>   kubectl logs deploy/worker --tail=10 --follow --namespace=helmcoins
>   ```

Note: it might take a minute or two for the worker to start.

## Discussion, shortcomings

- Helm (and Kubernetes) best practices recommend to add a number of annotations

  (e.g. `app.kubernetes.io/name`, `helm.sh/chart`, `app.kubernetes.io/instance` ...)

- Our basic chart doesn't have any of these

- Our basic chart doesn't use any template tag

- Does it make sense to use Helm in that case?

- *Yes,* because Helm will:

  - track the resources created by the chart

  - save successive revisions, allowing us to rollback

[Helm docs][helm-labels] and [Kubernetes docs][k8s-labels]
have details about recommended annotations and labels.

[helm-labels]: https://helm.sh/docs/chart_best_practices/labels/
[k8s-labels]: https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/

## Cleaning up

- Let's remove that chart before moving on

> [!example] Hands-on
> - Delete the release (don't forget to specify the namespace):
>   ```bash
>   helm delete helmcoins --namespace=helmcoins
>   ```

## Tips when writing charts

- It is not necessary to `helm install`/`upgrade` to test a chart

- If we just want to look at the generated YAML, use `helm template`:
  ```bash
  helm template ./my-chart
  helm template release-name ./my-chart
  ```

- Of course, we can use `--set` and `--values` too

- Note that this won't fully validate the YAML!

  (e.g. if there is `apiVersion: klingon` it won't complain)

- This can be used when trying things out

## Exploring the templating system

Try to put something like this in a file in the `templates` directory:

```yaml
hello: {{ .Values.service.port }}
comment: {{/* something completely.invalid !!!  */}}
type: {{ .Values.service | typeOf | printf }}
### print complex value
{{ .Values.service | toYaml }}
### indent it
indented:
{{ .Values.service | toYaml | indent 2 }}
```

Then run `helm template`.

The result is not a valid YAML manifest, but this is a great debugging tool!

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/helm-create-basic-chart.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/helm-create-basic-chart.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> error message updated for current Helm, commands tested with Helm 4.3.

<!-- uplink -->
Part of [[kubernetes/packaging/index|Packaging with Helm]].
