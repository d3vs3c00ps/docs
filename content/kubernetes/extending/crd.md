---
title: "Custom Resource Definitions"
description: "CRDs are one of the (many) ways to extend the API"
tags: [kubernetes, api, operators, crd]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/crd.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Custom Resource Definitions

> [!important] These labs expect the upstream repository
> Commands below reference files by their path in a local clone. Get it with:
>
> ```bash
> git clone https://github.com/jpetazzo/container.training
> ```
>
> The manifests can also be browsed at the pinned commit
> [`56563629`](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2).

- CRDs are one of the (many) ways to extend the API

- CRDs can be defined dynamically

  (no need to recompile or reload the API server)

- A CRD is defined with a CustomResourceDefinition resource

  (CustomResourceDefinition is conceptually similar to a *metaclass*)

## Creating a CRD

- We will create a CRD to represent different recipes of pizzas

- We will be able to run `kubectl get pizzas` and it will list the recipes

- Creating/deleting recipes won't do anything else

  (because we won't implement a *controller*)

## A bit of history

Things related to Custom Resource Definitions:

- Kubernetes 1.7: `apiextensions.k8s.io/v1beta1` introduced (replacing ThirdPartyResources)

- Kubernetes 1.16: `apiextensions.k8s.io/v1` introduced

- Kubernetes 1.22: `apiextensions.k8s.io/v1beta1` [removed][changes-in-122]

- Kubernetes 1.25: [CEL validation rules available in beta][crd-validation-rules-beta]

- Kubernetes 1.28: [validation ratcheting][validation-ratcheting] in [alpha][feature-gates]

- Kubernetes 1.29: [CEL validation rules available in GA][cel-validation-rules]

- Kubernetes 1.30: [validation ratcheting][validation-ratcheting] in [beta][feature-gates]; enabled by default

[crd-validation-rules-beta]: https://kubernetes.io/blog/2022/09/23/crd-validation-rules-beta/
[cel-validation-rules]: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules
[validation-ratcheting]: https://github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery/4008-crd-ratcheting
[feature-gates]: https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/#feature-gates-for-alpha-or-beta-features
[changes-in-122]: https://kubernetes.io/blog/2021/07/14/upcoming-changes-in-kubernetes-1-22/

## First slice of pizza

```yaml
apiVersion: apiextensions.k8s.io/v1beta1
kind: CustomResourceDefinition
metadata:
  name: pizzas.container.training
spec:
  group: container.training
  version: v1alpha1
  scope: Namespaced
  names:
    plural: pizzas
    singular: pizza
    kind: Pizza
    shortNames:
    - piz
```
<small>Source: [`k8s/pizza-1.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/pizza-1.yaml)</small>

## The joys of API deprecation

- Unfortunately, the CRD manifest on the previous slide is deprecated!

- It is using `apiextensions.k8s.io/v1beta1`, which is dropped in Kubernetes 1.22

- We need to use `apiextensions.k8s.io/v1`, which is a little bit more complex

  (a few optional things become mandatory, see [this guide](https://kubernetes.io/docs/reference/using-api/deprecation-guide/#customresourcedefinition-v122) for details)

## Second slice of pizza

- The next slide will show file [`k8s/pizza-2.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/pizza-2.yaml)

- Note the `spec.versions` list

  - we need exactly one version with `storage: true`

  - we can have multiple versions with `served: true`

- `spec.versions[].schema.openAPIV3Schema` is required

  (and must be a valid OpenAPI schema; here it's a trivial one)

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: pizzas.container.training
spec:
  group: container.training
  scope: Namespaced
  names:
    plural: pizzas
    singular: pizza
    kind: Pizza
    shortNames:
    - piz
  versions:
  - name: v1alpha1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
```
<small>Source: [`k8s/pizza-2.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/pizza-2.yaml)</small>

## Baking some pizza

- Let's create the Custom Resource Definition for our Pizza resource

> [!example] Hands-on
> - Load the CRD:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/pizza-2.yaml
>   ```
>
> - Confirm that it shows up:
>   ```bash
>   kubectl get crds
>   ```

## Creating custom resources

The YAML below defines a resource using the CRD that we just created:

```yaml
kind: Pizza
apiVersion: container.training/v1alpha1
metadata:
  name: hawaiian
spec:
  toppings: [ cheese, ham, pineapple ]
```

> [!example] Hands-on
> - Try to create a few pizza recipes:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/pizzas.yaml
>   ```

## Type validation

- Recent versions of Kubernetes will issue errors about unknown fields

  (`strict decoding error: unknown field "spec"`: the trivial schema has no fields)

- We need to improve our OpenAPI schema

  (to add e.g. the `spec.toppings` field used by our pizza resources)

## Creating a bland pizza

- Let's try to create a pizza anyway!

> [!example] Hands-on
> - Only provide the most basic YAML manifest:
>   ```bash
>   kubectl create -f- <<EOF
>   kind: Pizza
>   apiVersion: container.training/v1alpha1
>   metadata:
>     name: hawaiian
>   EOF
>   ```

- That should work! (As long as we don't try to add pineapple😁)

## Third slice of pizza

- Let's add a full OpenAPI v3 schema to our Pizza CRD

- We'll require a field `spec.sauce` which will be a string

- And a field `spec.toppings` which will have to be a list of strings

> [!example] Hands-on
> - Update our pizza CRD:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/pizza-3.yaml
>   ```
>
> - Load our pizza recipes:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/pizzas.yaml
>   ```

## Viewing custom resources

- By default, `kubectl get` only shows name and age of custom resources

> [!example] Hands-on
> - View the pizza recipes that we just created:
>   ```bash
>   kubectl get pizzas
>   ```

- Let's see how we can improve that display!

## Additional printer columns

- We can tell Kubernetes which columns to show:
  ```yaml
    additionalPrinterColumns:
    - jsonPath: .spec.sauce
      name: Sauce
      type: string
    - jsonPath: .spec.toppings
      name: Toppings
      type: string
  ```

- There is an updated CRD in [`k8s/pizza-4.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/pizza-4.yaml)

## Using additional printer columns

- Let's update our CRD!

> [!example] Hands-on
> - Update the CRD:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/pizza-4.yaml
>   ```
>
> - Look at our Pizza resources:
>   ```bash
>   kubectl get pizzas
>   ```

Note: we can update a CRD without having to re-create the corresponding resources.

(Good news, right?)

## Validation woes

- Let's check what happens if we try to update our pizzas

> [!example] Hands-on
> - Try to add a label:
>   ```bash
>   kubectl label pizza --all deliciousness=9001
>   ```

- It works for the pizzas that have `sauce` and `toppings`, but not the other one!

- The other one doesn't pass validation, and *can't be modified*

## First, let's fix this!

- Option 1: delete the pizza

  *(deletion isn't subject to validation)*

- Option 2: update the pizza to add `sauce` and `toppings`

  *(writing a pizza that passes validation is fine)*

- Option 3: relax the validation rules

## Next, explain what's happening

- Some of the pizzas that we defined earlier *do not* pass validation

- How is that possible?

- Validation happens at *admission*

  (when resources get written into the database)

- Therefore, we can have "invalid" resources in etcd

  (they are invalid from the CRD perspective, but the CRD can be changed)

🤔 How should we handle that ?

## Versions

- If the data format changes, we can roll out a new version of the CRD

  (e.g. go from `v1alpha1` to `v1alpha2`)

- In a CRD we can specify the versions that exist, that are *served*, and *stored*

  - multiple versions can be *served*

  - only one can be *stored*

- Kubernetes doesn't automatically migrate the content of the database

- However, it can convert between versions when resources are read/written

## Conversion

- When *creating* a new resource, the *stored* version is used

  (if we create it with another version, it gets converted)

- When *getting* or *watching* resources, the *requested* version is used

  (if it is stored with another version, it gets converted)

- By default, "conversion" only changes the `apiVersion` field

- ... But we can register *conversion webhooks*

  (see [that doc page](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/#webhook-conversion) for details)

> [!note]- Extra details
> ## Migrating database content
>
> - We need to *serve* a version as long as we *store* objects in that version
>
>   (=as long as the database has at least one object with that version)
>
> - If we want to "retire" a version, we need to migrate these objects first
>
> - All we have to do is to read and re-write them
>
>   (the [kube-storage-version-migrator](https://github.com/kubernetes-sigs/kube-storage-version-migrator) tool can help)

## Validation ratcheting

- Good news: it's not always necessary to introduce new versions

  (and to write the associated conversion webhooks)

- *Validation ratcheting allows updates to custom resources that fail validation to succeed if the validation errors were on unchanged keypaths*

- In other words: allow changes that don't introduce further validation errors

- This was introduced in Kubernetes 1.28 (alpha), enabled by default in 1.30 (beta)

- The rules are actually a bit more complex

- Another (maybe more accurate) explanation: allow to tighten or loosen some field definitions

## Validation ratcheting example

- Let's change the data schema so that the sauce can only be `red` or `white`

- This will be implemented by [`k8s/pizza-5.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/pizza-5.yaml)

> [!example] Hands-on
> - Update the Pizza CRD:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/pizza-5.yaml
>   ```

## Testing validation ratcheting

- This should work with Kubernetes 1.30 and above

  (but give an error for the `brownie` pizza with previous versions of K8S)

> [!example] Hands-on
> - Add another label:
>   ```bash
>   kubectl label pizzas --all food=definitely
>   ```

## Even better data validation

- If we need more complex data validation, we can use a validating webhook

- Use cases:

  - validating a "version" field for a database engine

  - validating that the number of e.g. coordination nodes is even

  - preventing inconsistent or dangerous changes
    (e.g. major version downgrades)

  - checking a key or certificate format or validity

  - and much more!

## CRDs in the wild

- [gitkube](https://storage.googleapis.com/gitkube/gitkube-setup-stable.yaml)

- [A redis operator](https://github.com/amaizfinance/redis-operator/blob/master/deploy/crds/k8s_v1alpha1_redis_crd.yaml)

- [cert-manager](https://github.com/jetstack/cert-manager/releases/download/v1.0.4/cert-manager.yaml)

*How big are these YAML files?*

*What's the size (e.g. in lines) of each resource?*

## CRDs in practice

- Production-grade CRDs can be extremely verbose

  (because of the openAPI schema validation)

- This can (and usually will) be managed by a framework

## (Ab)using the API server

- If we need to store something "safely" (as in: in etcd), we can use CRDs

- This gives us primitives to read/write/list objects (and optionally validate them)

- The Kubernetes API server can run on its own

  (without the scheduler, controller manager, and kubelets)

- By loading CRDs, we can have it manage totally different objects

  (unrelated to containers, clusters, etc.)

## What's next?

- Creating a basic CRD is relatively straightforward

- But CRDs generally require a *controller* to do anything useful

- The controller will typically *watch* our custom resources

  (and take action when they are created/updated)

- Most serious use-cases will also require *validation web hooks*

- When our CRD data format evolves, we'll also need *conversion web hooks*

- Doing all that work manually is tedious; use a framework!

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/crd.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/crd.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> a heredoc indentation and a field name fixed, tested on kind.

<!-- uplink -->
Part of [[kubernetes/extending/index|Extending Kubernetes]].
