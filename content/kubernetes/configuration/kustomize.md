---
title: "Kustomize"
description: "Transform existing Kubernetes YAML with kustomizations: patches, generators, images, transformers and replacements"
tags: [kubernetes, configuration, kustomize]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kustomize.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Kustomize

Kustomize transforms Kubernetes resources: *YAML + kustomize → new YAML*.

- The starting point is valid resource files: something that we could load with
  `kubectl apply -f`.
- The recipe is a *kustomization* file. It describes how to transform the resources.
- The result is new resource files, that we can also load with `kubectl apply -f`.

See [[kubernetes/configuration/templating]] for how Kustomize compares with Helm and
other tools.

## Pros and cons

Pros:

- It is easy to get started: we just need some existing YAML files.
- It is easy to reuse existing "upstream" YAML files, or other *kustomizations*.
- It is built into `kubectl`.

Cons:

- There is no central index like the Artifact Hub (but is there a need for one?).
- *Some* changes are hard to make.
- It is 100% file-based. It does not read command-line flags or environment variables.

## Kustomize in a nutshell

1. Get some valid YAML: our "resources".
2. Write a *kustomization*. Technically, it is a file named `kustomization.yaml`. It can:
   - reference our resources;
   - reference other kustomizations;
   - add *patches* and other *transformations*;
   - and more.
3. Use that kustomization with `kustomize build` or `kubectl apply -k`.
4. Write new kustomizations that reference the first one, to handle small differences
   (for example between staging and production).

## A simple kustomization

This one has a Deployment, a Service and an Ingress, in separate files. It also has two
patches: one changes the number of replicas, the other changes the hostname of the
Ingress.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
- service.yaml
- ingress.yaml
patches:
- path: scale-deployment.yaml
- path: ingress-hostname.yaml
```

A patch file is a partial resource. Kustomize finds the resource with the same kind and
name, and merges the patch into it. For example, `scale-deployment.yaml` could be:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
```

## A more complex Kustomization

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
commonAnnotations:
  last-commit-message: "Bump libfoo to version 1.2.3"
labels:
- pairs:
    last-commit-hash: "39bc2d"
resources:
- github.com/example/front?ref=tag-or-branch
- github.com/example/api?ref=tag-or-branch
- db/
- workers/
- ingress.yaml
- rbac.yaml
configMapGenerator:
- name: appconfig
  files:
  - global.conf
  - local.conf=prod.conf
patches:
- path: healthchecks.yaml
- path: resources-requests-and-limits.yaml
```

- The two `github.com/...` lines are remote kustomizations, at a given tag or branch.
- `db/` and `workers/` are local directories that contain their own `kustomization.yaml`.
- `configMapGenerator` creates a ConfigMap named `appconfig-<hash>`. It has two keys:
  `global.conf`, and `local.conf` with the content of the file `prod.conf`.

## Architecture

Internally, Kustomize has three phases:

1. *Generators* produce a set of YAML documents, for example by reading manifest files.
2. *Transformers* transform or patch that YAML in various ways.
3. *Validators* can stop the process if something is wrong.

In the examples above:

- `resources` and `configMapGenerator` are generators;
- `commonAnnotations`, `labels` and `patches` are transformers.

## Glossary

- A *base* is a kustomization that other kustomizations refer to.
- An *overlay* is a kustomization that refers to other kustomizations.
- A kustomization can be a base and an overlay at the same time: a kustomization can
  refer to another one, which can refer to a third one.
- A *variant* is the final result of applying bases and overlays.

See the [kustomize glossary][glossary] for more definitions.

[glossary]: https://kubectl.docs.kubernetes.io/references/kustomize/glossary/

## Kustomize workflows

The Kustomize documentation describes two workflows:

- *Bespoke configuration*: the same team manages the base and the overlays.
- *Off-the-shelf configuration* (OTS): different teams manage the base and the overlays.
  - "Upstream" (for example a vendor) updates the base regularly.
  - Our overlays and patches should (hopefully) still apply cleanly.
  - We may update our copy of the base regularly, or use a remote base.

There is no technical difference between the two. They are just different use cases.

## Managing `kustomization.yaml`

There are many ways to manage `kustomization.yaml` files, including:

- the `kustomize` CLI;
- our favorite text editor;
- ~~web wizards like [Replicated Ship](https://www.replicated.com/ship/)~~ (deprecated).

Let's see these in action.

## Working with the `kustomize` CLI

General workflow:

1. `kustomize create` generates an empty `kustomization.yaml` file.
2. `kustomize edit add resource` adds Kubernetes YAML files to it.
3. `kustomize edit add patch` adds patches for these resources.
4. `kustomize edit add ...` or `kustomize edit set ...` do the rest (there are many options).
5. `kustomize build | kubectl apply -f-` or `kubectl apply -k .` applies the result.
6. Repeat steps 4 and 5 as many times as needed.

## Why work with the CLI?

- Editing by hand can introduce errors and typos.
- With the CLI, we don't need to remember the names of all the options and parameters.
  Add `--help` after any command to see its options.
- Install the shell completion (`kustomize completion bash`, for example) and try
  `kustomize edit add [TAB][TAB]`.

## `kustomize create`

> [!example] Hands-on
> - Change to a new directory:
>   ```bash
>   mkdir ~/kustomcoins
>   cd ~/kustomcoins
>   ```
>
> - Run `kustomize create` with the `kustomize` branch of the kubercoins repository:
>   ```bash
>   kustomize create --resources 'https://github.com/jpetazzo/kubercoins?ref=kustomize'
>   ```
>
> - Build the kustomization and apply it:
>   ```bash
>   kustomize build | kubectl apply -f-
>   ```

> [!warning] Correction
> The original used `https://github.com/jpetazzo/kubercoins`, without `?ref=`. The
> default branch of that repository has no `kustomization.yaml`, so `kustomize build`
> fails with `unable to find one of 'kustomization.yaml' ... in directory`. The
> `kustomize` branch has one.

## `kubectl` integration

Kustomize is built into `kubectl` since Kubernetes 1.14:

- `kubectl kustomize` does the same as `kustomize build`;
- commands that take `-f` also take `-k` (`kubectl apply`, `kubectl delete`, ...).

We still need the `kustomize` tool for `create`, `edit`, and so on.

The Kustomize version inside `kubectl` changed over time:

- Kubernetes 1.14 to 1.20 use Kustomize 2.0.3.
- Kubernetes 1.21 jumps to Kustomize 4.1.2.
- Kubernetes 1.37 uses Kustomize 5.8. `kubectl version` shows it, on the
  `Kustomize Version` line.

Kustomize is now officially part of [sig-cli]. `kubectl` usually follows recent versions
of Kustomize, but it can lag a bit behind, so some features may be missing.

[sig-cli]: https://github.com/kubernetes/community/blob/master/sig-cli/README.md

## Kustomize features

- A good starting point is
  [the Kustomization File reference](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/).
- The Kustomize documentation is far from perfect.
- Some features are not documented.
- Some features are deprecated or replaced by others, and the documentation does not
  always say so (for example `commonLabels`).
- Some features are documented before they are released. For example, regex selectors in
  `replacements` were documented in 2025 but only released in Kustomize 5.8.

## Kustomization basics

- `resources` includes YAML manifests. `bases` did the same, and is deprecated.
- `buildMetadata` generates useful labels or annotations automatically.
- `commonAnnotations`, `labels` and `commonLabels` add custom labels or annotations to
  all resources. `commonLabels` is deprecated: use `labels`.
- `configMapGenerator`, `secretGenerator` and `generatorOptions` generate ConfigMaps and
  Secrets. By default, a hash of the content is added to their name. When the content
  changes, the name changes, and the Pods that use it are updated.

`kustomize build` prints a warning for each deprecated field. `kustomize edit fix` rewrites
the kustomization with the new fields.

## Transforming resources

`patches` (and the deprecated `patchesJson6902` and `patchesStrategicMerge`):

- make (almost) any change to resources;
- can remove fields, or even whole resources;
- can be in separate files, or inline in the kustomization file;
- can apply to one resource, or to a selection of resources.

`images`, `namePrefix`, `namespace`, `nameSuffix` and `replicas` are helpers for simple
changes. They are short and easy to use, but limited.

## More transformations

`replacements`:

- update single fields (a bit like patches);
- can also update part of a field (for example, the registry of an image);
- can copy a field from one place to another (for example, a whole container spec);
- can apply to one resource or to a selection of resources;
- can also *exclude* resources from the replacement.

## Teach Kustomize new tricks

- `crds` makes Kustomize aware of fields in CRDs, for example a ConfigMap reference.
- `openapi` gives Kustomize a schema, to teach it about merge keys and more.
- `sortOptions` outputs resources in a given order.
- `helmCharts` renders a Helm chart template. It needs the `--enable-helm` flag; it is not
  standard / GA yet.
- `vars` defines variables to reuse elsewhere. It only works in some fields, and it is
  deprecated already: use `replacements`.
- `components` is similar to an "include": it points to a "component" and runs all its
  generators and transformers.

## Remote bases

Kustomize can also use bases that are remote git repositories. For example:

```bash
kustomize build 'https://github.com/kubernetes-sigs/kustomize//examples/multibases/?ref=v3.3.1'
```

See [remoteBuild.md](https://github.com/kubernetes-sigs/kustomize/blob/master/examples/remoteBuild.md)
for the URL format of remote targets.

A git URL must point to a kustomization: the repository or directory must contain a
`kustomization.yaml` file. A plain HTTP(S) URL to a single YAML file (for example a
`raw.githubusercontent.com` link) also works as a resource.

## What Kustomize *cannot* do

By design, Kustomize won't do some things. For example:

- use command-line arguments or environment variables to generate a variant;
- let overlays *remove* resources: overlays can only *add* them.[^remove]

See the full list of [eschewed features](https://kubectl.docs.kubernetes.io/faq/kustomize/eschewedfeatures/)
for more details.

[^remove]: That is actually not true: a patch with `$patch: delete` removes a resource.

## Changing image references

We will see a few ways to change image references.

- Our app uses several images: `redis`, `dockercoins/hasher`, `dockercoins/worker`...
- We want the `dockercoins/*` images to come from a registry mirror, for example
  `ghcr.io/dockercoins/*`.
- We don't want to change the other images.

## Changing images with the CLI

We can use the following command:

```bash
kustomize edit set image name=[newName][:newTag][@digest]
```

- `[]` marks optional parts.
- `:` and `@` separate the fields.

Examples:

```bash
kustomize edit set image dockercoins/worker=ghcr.io/dockercoins/worker
kustomize edit set image dockercoins/worker=ghcr.io/dockercoins/worker:v0.2
kustomize edit set image dockercoins/worker=:v0.2
```

This adds entries to the `images:` section of the kustomization. Each command replaces
the entry for that image: after the last one, `newName` is gone and only `newTag: v0.2`
is left.

## Changing images with `images:`

Here are a few examples of the `images:` directive:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- app.yaml
images:
- name: postgres
  newName: harbor.example.com/my-postgres
- name: dockercoins/worker
  newTag: v0.2
- name: dockercoins/hasher
  newName: registry.example.com/hasher
  newTag: v0.2
- name: alpine
  digest: sha256:24a0c4b4a4c0eb97a1aabb8e29f18e917d05abfe1b7a7c07857230879ce7d3d3
```

## `images:` in practice

This is what we would need for our app:

```yaml
- name: dockercoins/hasher
  newName: ghcr.io/dockercoins/hasher
- name: dockercoins/rng
  newName: ghcr.io/dockercoins/rng
- name: dockercoins/webui
  newName: ghcr.io/dockercoins/webui
- name: dockercoins/worker
  newName: ghcr.io/dockercoins/worker
```

It works, but it needs two lines per image. Can we do better?

## `images:`, pros and cons

Pros:

- very handy when the same image appears many times;
- very handy to set tags (or pin digests) outside of the main YAML.

Cons:

- no wildcards or generic substitutions:
  - it cannot "replace `dockercoins/*` with `ghcr.io/dockercoins/*`";
  - it cannot "tag all `dockercoins/*` with `v0.2`";
- it only changes "well-known" image fields (it won't work with CRDs that reference
  images);
- if our app uses 4 images, we need 4 entries in the `images:` section.

## `PrefixSuffixTransformer`

- Internally, the `namePrefix` directive uses a `PrefixSuffixTransformer`.
- By default, that transformer acts on `metadata.name`.
- We can call it by hand and configure it to act on other fields, for example
  `spec.template.spec.containers.image` in a Deployment manifest.

## `PrefixSuffixTransformer` in action

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- microservices.yaml
transformers:
- |
  apiVersion: builtin
  kind: PrefixSuffixTransformer
  metadata:
    name: use-ghcr-io
  prefix: ghcr.io/
  fieldSpecs:
  - path: spec/template/spec/containers/image
```
<small>Source: [`k8s/kustomize-examples/registry-with-prefix-transformer/microservices/kustomization.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/kustomize-examples/registry-with-prefix-transformer/microservices/kustomization.yaml)</small>

However, this transforms **all** Deployments. More exactly, it transforms all resources
that have a `spec.template.spec.containers.image` field: the `redis` Deployment gets
`ghcr.io/redis` too.

## Limiting `PrefixSuffixTransformer`

A `PrefixSuffixTransformer` applies to *all* resources that have the field. A `fieldSpec`
can add a `kind` (and `group`, `version`) to act on one kind only, but as of Kustomize 5.8
there is no way to select resources by name or label.

One workaround:

- split the app into several kustomizations;
- put the components that need the change in one kustomization;
- put the other components in another one.

This is not great when several transformations apply to different resources.

## `replacements`

- A replacement can replace a whole field.
- It can also replace *part* of a field, using a delimiter (for example `/` for images).
- It can apply to *selected* resources.

Let's see an example.

## `replacements` in action

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- dockercoins.yaml
replacements:
- sourceValue: ghcr.io/dockercoins
  targets:
  - select:
      kind: Deployment
      labelSelector: "app in (hasher,rng,webui,worker)"
    fieldPaths:
    - spec.template.spec.containers.*.image
    options:
      delimiter: "/"
      index: 0
```

Note that `fieldPaths` use a different format from the transformer's `fieldSpecs` above.

`dockercoins/hasher:v0.1` is split on `/`, and part `0` (`dockercoins`) is replaced, which
gives `ghcr.io/dockercoins/hasher:v0.1`. `redis` does not match the selector and does not
change.

Since Kustomize 5.8, `name` in a selector is a regular expression, so
`name: hasher|rng|webui|worker` can replace the `labelSelector` line. A `reject:` list
can also exclude resources, for example the `redis` Deployment.

## Discussion

- There are several ways to rewrite image references to use a registry mirror.
- They all have pros and cons.
- The main problem: we must list the resources that we want to change, or move them to a
  separate kustomization.
- There is no (easy) way to say: "Replace all images that start with `dockercoins/` with
  `ghcr.io/dockercoins/`".

## Inconsistencies

- Sometimes we can filter or select resources, sometimes not.
- When we can, it is not always done the same way.
- Field paths have different formats in different places:
  - `/spec/template/spec/containers/0/image` in JSON patches;
  - `spec.template.spec.containers.0.image` in replacements' `fieldPaths`;
  - `spec/template/spec/containers/image` in transformers' `fieldSpecs`;
  - `.spec.template.spec.containers[].image` with tools like `jq`.
- `fieldPaths` also have useful extensions, like
  `spec.template.spec.containers.[name=hello].image`.

## Conclusions

- Kustomize can do a lot of transformations.
- In complex cases, it can quickly become a maintenance nightmare.
- One possible strategy:
  - keep each kustomization as simple as possible;
  - compose several kustomizations together.
- See [this kustomization][ollama-with-sidecar] for a creative example with sidecars and
  more.
- See [that kustomization][flux-kustomization] for an example that adds command-line flags
  to controllers.

[ollama-with-sidecar]: https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/kustomize-examples/ollama-with-sidecar
[flux-kustomization]: https://github.com/fluxcd/flux2-multi-tenancy/blob/main/clusters/production/flux-system/kustomization.yaml

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/kustomize.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kustomize.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; the kubercoins hands-on, the deprecated fields, regex selectors,
> remote file resources and the sidecar example link were updated for Kustomize 5.8.

<!-- uplink -->
Part of [[kubernetes/configuration/index|Configuration and secrets]].
