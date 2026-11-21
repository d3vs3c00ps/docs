---
title: "YTT"
description: "ytt, the YAML Templating Tool from Carvel: Starlark code in YAML comments, data values, libraries and overlays"
tags: [kubernetes, configuration, templating]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/ytt.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# YTT

ytt is the YAML Templating Tool. It is part of [Carvel], a set of tools to build,
configure and deploy applications on Kubernetes. It works with any YAML: Kubernetes
manifests, Compose files, CI pipelines... See [[kubernetes/configuration/templating]] for
how it compares with Helm and Kustomize.

[Carvel]: https://carvel.dev/

## Features

- It works on data structures, not on text (unlike Helm).
- Its execution is deterministic and hermetic: no network, no clock, no random values.
- We can define variables, blocks and functions.
- We write code in Starlark, a dialect of Python.
- We can define and override values, like with Helm.
- We can patch resources in any way, like with Kustomize.

## Getting started

1. Install `ytt` ([binary download][download]).
2. Start with one or more Kubernetes YAML files.
3. Run `ytt -f one.yaml -f two.yaml | kubectl apply -f-`,
   or `ytt -f. | kubectl apply -f-` for a whole directory.

> [!warning] Correction
> The original said the YAML files must have no comments: "no `#` allowed". Old ytt
> versions failed on plain `#` comments. ytt v0.55 accepts them and removes them from
> the output. Still, use `#!` for comments in templates (see below), so a comment is never
> mistaken for code.

[download]: https://github.com/carvel-dev/ytt/releases/latest

## No comments?!?

- Write comments with `#!` instead of `#`.
- `#@` is for ytt code. It is a kind of template tag. For example:

```yaml
#! This is a comment
#@ a = 42
#@ b = "*"
a: #@ a
b: #@ b
operation: multiply
result: #@ a*b
```

- `#@` at the beginning of a line is an instruction.
- `#@` after a key is a value.

Here `b` is a string, so `a*b` repeats it: `result` is a string of 42 `*`.

## Building strings

Concatenation:

```yaml
#@ repository = "dockercoins"
#@ tag = "v0.1"
containers:
- name: worker
  image: #@ repository + "/worker:" + tag
```

Formatting:

```yaml
#@ repository = "dockercoins"
#@ tag = "v0.1"
containers:
- name: worker
  image: #@ "{}/worker:{}".format(repository, tag)
```

## Defining functions

We can write reusable functions in Starlark (a dialect of Python). Blocks (`def`, `if`,
`for`...) must end with `#@ end`. For example:

```yaml
#@ def image(component, repository="dockercoins", tag="v0.1"):
#@   return "{}/{}:{}".format(repository, component, tag)
#@ end
containers:
- name: worker
  image: #@ image("worker")
- name: hasher
  image: #@ image("hasher")
```

## Structured data

Functions can return complex types. For example, a common set of labels:

```yaml
#@ name = "worker"
#@ def labels(component):
#@   return {
#@     "app": component,
#@     "container.training/generated-by": "ytt",
#@   }
#@ end
kind: Pod
apiVersion: v1
metadata:
  name: #@ name
  labels: #@ labels(name)
```

## YAML functions

A function body can also be plain YAML:

```yaml
#@ name = "worker"

#@ def labels(component):
app: #@ component
container.training/generated-by: ytt
#@ end

kind: Pod
apiVersion: v1
metadata:
  name: #@ name
  labels: #@ labels(name)
```

The function then returns a [YAML fragment][fragment].

[fragment]: https://carvel.dev/ytt/docs/latest/lang-ref-yaml-fragment/

## More YAML functions

We can load library functions:

```yaml
#@ load("@ytt:sha256", "sha256")
```

This is (sort of) like `from ytt.sha256 import sha256` in Python.

Functions can mix code and YAML fragments:

```yaml
#@ load("@ytt:sha256", "sha256")

#@ def annotations():
#@ author = "Jérôme Petazzoni"
author: #@ author
author_hash: #@ sha256.sum(author)[:8]
#@ end

annotations: #@ annotations()
```

## Data values

We can define a *schema* in a separate file:

```yaml
#@data/values-schema
--- #! there must be a "---" here!
repository: dockercoins
tag: v0.1
```

- This defines the data values (the parameters that users can change), with their
  *types* and *default values*.
- Technically, `#@data/values-schema` is an annotation. It applies to a YAML document,
  so the next element must be a YAML document: hence the `---`.
- This is similar to Helm's *values* file, with type checks as a bonus: giving a string
  where the schema has an integer is an error.

## Using data values

We load `@ytt:data`. The values are then in `data.values`. For example:

```yaml
#@ load("@ytt:data", "data")
#@ def image(component):
#@   return "{}/{}:{}".format(data.values.repository, component, data.values.tag)
#@ end
#@ name = "worker"
containers:
- name: #@ name
  image: #@ image(name)
```

## Overriding data values

There are many ways to set and override data values:

- plain YAML files;
- data value overlays;
- environment variables;
- command-line flags.

The [docs][data-values-merge-order] define which one wins.

[data-values-merge-order]: https://carvel.dev/ytt/docs/latest/ytt-data-values/#data-values-merge-order

## Values in plain YAML files

Content of `values.yaml`:

```yaml
tag: latest
```

The values are merged with `--data-values-file`:

```bash
ytt -f config/ --data-values-file values.yaml
```

We can give several files. These files can also be URLs.

## Data value overlay

Content of `values.yaml`:

```yaml
#@data/values
--- #! must have --- here
tag: latest
```

The values are merged when we give the file like a "normal" file:

```bash
ytt -f config/ -f values.yaml
```

We can give several files.

## Set a value with a flag

Set a string value:

```bash
ytt -f config/ --data-value tag=latest
```

Set a YAML value, to read it as an integer, a boolean...:

```bash
ytt -f config/ --data-value-yaml replicas=10
```

Read a string value from a file:

```bash
ytt -f config/ --data-value-file ca_cert=cert.pem
```

Each value must exist in the schema (`replicas` and `ca_cert` here), or ytt fails.

## Set values from environment variables

Set environment variables with a prefix:

```bash
export VAL_tag=latest
export VAL_repository=ghcr.io/dockercoins
```

Use the variables as strings:

```bash
ytt -f config/ --data-values-env VAL
```

Or parse them as YAML:

```bash
ytt -f config/ --data-values-env-yaml VAL
```

## Lines starting with `#@`

This generates an empty document:

```yaml
#@ def hello():
hello: world
#@ end

#@ hello()
```

Do this instead:

```yaml
#@ def hello():
hello: world
#@ end

--- #@ hello()
```

## Generating multiple documents, take 1

This won't work:

```yaml
#@ def app():
kind: Deployment
apiVersion: apps/v1
--- #! separate from next document
kind: Service
apiVersion: v1
#@ end

--- #@ app()
```

ytt fails with a confusing internal error (`expected to find node tag ... when unwinding`):
the `---` inside the function body is not allowed there.

## Generating multiple documents, take 2

This won't work either:

```yaml
#@ def app():
--- #! the initial separator indicates "this is a Document Set"
kind: Deployment
apiVersion: apps/v1
--- #! separate from next document
kind: Service
apiVersion: v1
#@ end

--- #@ app()
```

ytt fails too, with `documents can only contain arrays, maps, or scalars; this is a
document set`: the function returns several documents, but `--- #@` expects one value.

## Generating multiple documents, take 3

We must use the `template` module:

```yaml
#@ load("@ytt:template", "template")

#@ def app():
--- #! the initial separator indicates "this is a Document Set"
kind: Deployment
apiVersion: apps/v1
--- #! separate from next document
kind: Service
apiVersion: v1
#@ end

--- #@ template.replace(app())
```

`template.replace(...)` is the only way (as far as we know) to replace one element with
many.

## Libraries

We can turn a reusable ytt configuration into a library. Put it in a subdirectory named
`_ytt_lib/whatever`, then:

```yaml
#@ load("@ytt:library", "library")
#@ load("@ytt:template", "template")
#@ whatever = library.get("whatever")
#@ my_values = {"tag": "latest", "registry": "..."}
#@ output = whatever.with_data_values(my_values).eval()
--- #@ template.replace(output)
```

The `with_data_values()` step is optional, but useful to "configure" the library. Note
the whole combination:

```yaml
template.replace(library.get("...").with_data_values(...).eval())
```

## Overlays

Overlays are powerful, but complex. But powerful!

They define transformations that ytt applies after it generates the whole document set.
The general idea:

- select the YAML nodes to transform with an `#@overlay/match` annotation;
- write a YAML snippet with the changes to apply (a bit like a strategic merge patch).

## Example

```yaml
#@ load("@ytt:overlay", "overlay")

#@ selector = {"kind": "Deployment", "metadata": {"name": "worker"}}
#@overlay/match by=overlay.subset(selector)
---
spec:
  replicas: 10
```

- By default, `#@overlay/match` must find *exactly* one match. `expects=...`,
  `missing_ok=True`... change that; see the [docs][docs-ytt-overlaymatch].
- By default, the fields in the snippet (here, `spec.replicas`) must exist. Annotating
  the optional fields changes that too.

[docs-ytt-overlaymatch]: https://carvel.dev/ytt/docs/latest/lang-ref-ytt-overlay/#overlaymatch

## Matching using a YAML document

```yaml
#@ load("@ytt:overlay", "overlay")

#@ def match():
kind: Deployment
metadata:
  name: worker
#@ end

#@overlay/match by=overlay.subset(match())
---
spec:
  replicas: 10
```

This is the same as the subset match of the previous example. It finds the YAML nodes
that have all the listed fields.

## Removing a field

```yaml
#@ load("@ytt:overlay", "overlay")

#@ def match():
kind: Deployment
metadata:
  name: worker
#@ end

#@overlay/match by=overlay.subset(match())
---
spec:
  #@overlay/remove
  replicas:
```

This removes the `replicas:` field from the spec of one Deployment. We could use it when
we enable autoscaling, for example.

## Selecting multiple nodes

```yaml
#@ load("@ytt:overlay", "overlay")

#@ def match():
kind: Deployment
#@ end

#@overlay/match by=overlay.subset(match()), expects="1+"
---
spec:
  #@overlay/remove
  replicas:
```

This matches all Deployments, as long as *at least one* exists. It removes the
`replicas:` field from their spec. The field must exist.

## Adding a field

```yaml
#@ load("@ytt:overlay", "overlay")

#@overlay/match by=overlay.all, expects="1+"
---
metadata:
  #@overlay/match missing_ok=True
  annotations:
    #@overlay/match expects=0
    rainbow: 🌈
```

- `#@overlay/match missing_ok=True` matches whether our resources already have
  annotations or not.
- `#@overlay/match expects=0` only matches if the `rainbow` annotation does not exist.
  This makes sure that we don't replace an existing annotation: if one exists, ytt
  fails.

## Overlays vs data values

The documentation has a [detailed discussion][data-values-vs-overlays] about this
question. In short:

- values are for parameters that we expose to the user;
- overlays are for any other changes.

Values are easier to use: use them when you can. Fall back to overlays when the values
don't expose what you need. Keep in mind that overlays are harder to write, understand
and maintain.

[data-values-vs-overlays]: https://carvel.dev/ytt/docs/latest/data-values-vs-overlays/

## Gotchas

Reminder: put your `#@` at the right place.

```yaml
#! This will generate "hello, world!"
--- #@ "{}, {}!".format("hello", "world")
```

```yaml
#! But this will generate an empty document
---
#@ "{}, {}!".format("hello", "world")
```

Also, don't use YAML anchors (`*foo` and `&foo`): they don't mix well with ytt.

Remember to use `template.replace(...)` when you generate several nodes from one, for
example to add items to a list or array without replacing it.

> [!warning] Correction
> The original said `template.render(...)`. The `@ytt:template` module has no `render`
> function: it is `template.replace(...)`, as in "Generating multiple documents, take 3".

## Next steps with ytt

- Read this documentation page about [injecting secrets][secrets].
- Read the [FAQ]: it shows what is possible with ytt.
- Exercise idea: write an overlay that finds all ConfigMaps mounted in Pods, and
  annotates each Pod with a hash of its ConfigMap.

[FAQ]: https://carvel.dev/ytt/docs/latest/faq/
[secrets]: https://carvel.dev/ytt/docs/latest/injecting-secrets/

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/ytt.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/ytt.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; updated for ytt v0.55 (comments, `template.replace`, links).

<!-- uplink -->
Part of [[kubernetes/configuration/index|Configuration and secrets]].
