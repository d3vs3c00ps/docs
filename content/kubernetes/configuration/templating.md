---
title: "Manifest Templating"
description: "Ways to adapt Kubernetes manifests between environments: sed, envsubst, jsonnet, CUE, ytt, Helm and Kustomize"
tags: [kubernetes, configuration, templating]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/templating.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Manifest Templating

In the Kubernetes ecosystem, we often use tools like Helm or Kustomize. CD (continuous
delivery) solutions like Flux or Argo CD support them out of the box. This page answers
three questions:

- What do Helm and Kustomize do?
- When do we need to learn them?
- What is the difference between them?

## A typical Kubernetes learning curve

1. Create resources with one-line commands (`kubectl run`, `kubectl create deployment`,
   `kubectl expose`...).
2. Write YAML manifests to describe these resources.
3. Create resources with `kubectl apply -f`, `kubectl create -f`...
4. Combine several resources in a single YAML file. This makes it easy to deploy whole
   stacks.
5. Change these YAML manifests to adapt them to dev, prod, and so on: number of replicas,
   image version, features to enable...

This page is about step 5.

## How can we tweak YAML manifests?

- With standard UNIX tools, like `sed` or `envsubst`. After all, YAML manifests are just
  text.
- With tools that evaluate text templates, like [gomplate].
- With tools that work on structured data like JSON or YAML, like [jsonnet], [CUE] or
  [ytt].
- With tools made for Kubernetes manifests, like Helm or Kustomize.

[gomplate]: https://github.com/hairyhenderson/gomplate
[jsonnet]: https://jsonnet.org/
[CUE]: https://github.com/cue-labs/cue-by-example/tree/main/003_kubernetes_tutorial
[ytt]: https://carvel.dev/ytt/

## Standard UNIX tools - `sed`

Write YAML files with placeholders, for example `ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: front
spec:
  rules:
  - host: HOSTNAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: front
            port:
              number: 80
```

Then replace the placeholders:

```bash
sed 's/HOSTNAME/www.example.com/g' < ingress.yaml | kubectl apply -f-
```

Placeholders can have delimiters, to avoid ambiguity: for example `@@HOSTNAME@@`.

## Standard UNIX tools - `envsubst`

Write YAML files with environment variables, for example `ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: front
spec:
  rules:
  - host: ${HOSTNAME}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: front
            port:
              number: 80
```

Then replace the variables with their values:

```bash
HOSTNAME=www.example.com envsubst < ingress.yaml | kubectl apply -f-
```

This is very handy in CI/CD pipelines, where our variables are already in the
environment.

`envsubst` comes with GNU gettext (package `gettext-base` on Debian and Ubuntu,
`gettext` on most other distributions). It replaces *every* `$VAR` and `${VAR}` in the
input, and an unset variable becomes an empty string. To replace only some variables,
list them:

```bash
HOSTNAME=www.example.com envsubst '${HOSTNAME}' < ingress.yaml
```

## Text templating tools

- They are very rarely used with Kubernetes, because Helm already has a text templating
  engine.
- Other engines are usually very similar to Helm's, so they would not add much value.
- Helm also has many useful Kubernetes-specific features.
- So if we want text templating, we will probably use Helm.

## Tools like jsonnet, CUE, ytt

- Jsonnet is a generic tool to manipulate JSON data structures. It was popular in the
  early days of Kubernetes, before Helm and Kustomize became common.
- CUE is a generic engine for data validation, templating, configuration... It is
  powerful, but harder to learn.
- ytt is the YAML Templating Tool. It is useful for all YAML files, not just Kubernetes
  manifests. See [[kubernetes/configuration/ytt]].

Some teams use these tools; feel free to have a look at them.

## Helm

Helm combines several things:

- A text templating engine, based on Go's [text/template], [Sprig], and some
  Kubernetes-specific functions.
- Templates can use "values": input parameters, that we can give in a structured YAML
  file, for example.
- Helm manages the application lifecycle, like a package manager: it applies manifests,
  keeps track of what is installed, and can uninstall or roll back a release.
- A huge library of Helm "charts" is available through the [Artifact Hub].

See [[kubernetes/packaging/helm-intro]].

[text/template]: https://pkg.go.dev/text/template
[Sprig]: https://masterminds.github.io/sprig/
[Artifact Hub]: https://artifacthub.io/

## Kustomize

- "Kubernetes native configuration management".
- It applies transformations to existing resources. The YAML manifests stay as they are,
  instead of being turned into templates.
- It works on data structures, not on the YAML text.
- It is built into `kubectl` (with `kubectl ... -k`).

See [[kubernetes/configuration/kustomize]].

## Helm vs Kustomize

Installing Helm charts:

- there is a huge library on the Artifact Hub;
- it is quite easy to get started;
- charts are hard to tweak beyond their values.

Writing Helm charts:

- we manipulate YAML as text, which is painful (indentation, quoting...);
- but (almost) everything is possible;
- complex setups can take a lot of work.

Kustomize:

- is easy to get started with;
- does not require us to rewrite YAML manifests;
- can apply (almost) any patch to resources.

## Which one is best?

Both have their use cases.

- Plain YAML is great for simple cases, when there is nothing to configure or tweak.
- Helm is great for complex cases: many settings, or settings with deep changes across
  many resources.
- Kustomize is great when we can't or won't use a Helm chart: third-party software with
  no Helm chart, or when we don't want to write one.

## Do we need to learn both?

*Personal recommendations:*

- Learn how to *install* Helm charts: a lot of Kubernetes software is available that way.
- Learn how to do basic things with Kustomize, for example simple patches or replacements
  on existing YAML.
- If you want to distribute software for Kubernetes, you should probably learn to *write*
  charts. Many people will expect to install and configure your software with Helm.
- For internal use, pick either Helm or Kustomize and learn it well. Check which one
  works best for your use case.

> [!note]- Extra details
> ## What about Terraform, Ansible...?
>
> Can we use "classic" tooling with Kubernetes? Yes.
>
> - For example, Terraform and OpenTofu have "providers" for Kubernetes
>   ([opentofu/kubernetes], [opentofu/helm]).
> - We then write HCL instead of YAML.
> - Kubernetes resources can work nicely with other Terraform resources.
> - This is great if we already use Terraform a lot.
> - It is also handy if we already manage secrets, for example, with Terraform.
> - Ansible and other tools are in a similar situation.
>
> [opentofu/kubernetes]: https://search.opentofu.org/provider/opentofu/kubernetes/latest
> [opentofu/helm]: https://search.opentofu.org/provider/opentofu/helm/latest

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/templating.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/templating.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; the Ingress examples were completed, and an `envsubst` tip added.

<!-- uplink -->
Part of [[kubernetes/configuration/index|Configuration and secrets]].
