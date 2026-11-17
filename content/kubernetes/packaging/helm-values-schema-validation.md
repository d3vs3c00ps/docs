---
title: "Helm and invalid values"
description: "helm install ... --set image.tag=v1.0"
tags: [kubernetes, helm]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/helm-values-schema-validation.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Helm and invalid values

- A lot of Helm charts let us specify an image tag like this:
  ```bash
  helm install ... --set image.tag=v1.0
  ```

- What happens if we make a small mistake, like this:
  ```bash
  helm install ... --set imagetag=v1.0
  ```

- Or even, like this:
  ```bash
  helm install ... --set image=v1.0
  ```

🤔

## Making mistakes

- In the first case:

  - we set `imagetag=v1.0` instead of `image.tag=v1.0`

  - Helm will ignore that value (if it's not used anywhere in templates)

  - the chart is deployed with the default value instead

- In the second case:

  - we set `image=v1.0` instead of `image.tag=v1.0`

  - `image` will be a string instead of an object

  - Helm will *probably* fail when trying to evaluate `image.tag`

## Preventing mistakes

- To prevent the first mistake, we need to tell Helm:

  *"let me know if any additional (unknown) value was set!"*

- To prevent the second mistake, we need to tell Helm:

  *"`image` should be an object, and `image.tag` should be a string!"*

- We can do this with *values schema validation*

## Helm values schema validation

- We can write a spec representing the possible values accepted by the chart

- Helm will check the validity of the values before trying to install/upgrade

- If it finds problems, it will stop immediately

- The spec uses [JSON Schema](https://json-schema.org/):

  *JSON Schema is a vocabulary that allows you to annotate and validate JSON documents.*

- JSON Schema is designed for JSON, but can easily work with YAML too

  (or any language with `map|dict|associativearray` and `list|array|sequence|tuple`)

## In practice

- We need to put the JSON Schema spec in a file called `values.schema.json`

  (at the root of our chart; right next to `values.yaml` etc.)

- The file is optional

- We don't need to register or declare it in `Chart.yaml` or anywhere

- Let's write a schema that will verify that ...

  - `image.repository` is an official image (string without slashes or dots)

  - `image.pullPolicy` can only be `Always`, `Never`, `IfNotPresent`

## A chart to try it on

- Let's use a small chart, with only `image` values

> [!example] Hands-on
> Create it:
>
> ```bash
> mkdir -p schematest/templates && cd schematest
> cat > Chart.yaml <<EOF
> apiVersion: v2
> name: schematest
> version: 0.1.0
> EOF
> cat > values.yaml <<EOF
> image:
>   repository: nginx
>   tag: "1.29"
>   pullPolicy: IfNotPresent
> EOF
> cat > templates/pod.yaml <<'EOF'
> apiVersion: v1
> kind: Pod
> metadata:
>   name: {{ .Release.Name }}
> spec:
>   containers:
>     - name: web
>       image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
>       imagePullPolicy: {{ .Values.image.pullPolicy }}
> EOF
> ```
>
> Then write the schema below to `values.schema.json`, in that directory.

## `values.schema.json`

```json
{
  "$schema": "http://json-schema.org/schema#",
  "type": "object",
  "properties": {
    "image": {
      "type": "object",
      "properties": {
        "repository": {
          "type": "string",
          "pattern": "^[a-z0-9-_]+$"
        },
        "pullPolicy": {
          "type": "string",
          "pattern": "^(Always|Never|IfNotPresent)$"
        }
      }
    }
  }
}
```

## Testing our schema

- Let's try to install a couple releases with that schema!

> [!example] Hands-on
> - Try an invalid `pullPolicy`:
>   ```bash
>   helm install broken . --set image.pullPolicy=ShallNotPass
>   ```
>
> - Try an invalid value:
>   ```bash
>   helm install should-break . --set ImAgeTAg=toto
>   ```

> [!warning] Correction
> The original commands had no chart argument (`helm install broken --set ...`).
> Helm then fails with `must either provide a name or specify --generate-name`,
> before it even reads the schema. The `.` is the chart in the current directory.

- The first one fails, but the second one still passes ...

- Why?

## Bailing out on unknown properties

- We told Helm what properties (values) were valid

- We didn't say what to do about additional (unknown) properties!

- We can fix that with `"additionalProperties": false`

> [!example] Hands-on
> - Edit `values.schema.json` to add `"additionalProperties": false`
>   ```json
>   {
>     "$schema": "http://json-schema.org/schema#",
>     "type": "object",
>     "additionalProperties": false,
>     "properties": {
>     ...
>   ```

## Testing with unknown properties

> [!example] Hands-on
> - Try to pass an extra property:
>   ```bash
>   helm install should-break-again . --set ImAgeTAg=toto
>   ```
>   (a new name: the first `should-break` was installed, and Helm refuses to reuse
>   a release name before it looks at the schema)
>
> - Try to pass an extra nested property:
>   ```bash
>   helm install does-it-work . --set image.hello=world
>   ```

The first command should break.

The second will not.

`"additionalProperties": false` needs to be specified at each level.

> [!warning] Every value must then be in the schema
> `additionalProperties` also applies to the chart's own `values.yaml`. Our small
> chart only has `image`, so this works. On a chart made by `helm create`, the same
> top-level `"additionalProperties": false` rejects every install, even with no
> `--set`: `replicaCount`, `service`, `ingress` and the others are not in the
> schema.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/helm-values-schema-validation.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/helm-values-schema-validation.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> a small chart added for the lab, missing chart argument added, tested with
> Helm 4.3.

<!-- uplink -->
Part of [[kubernetes/packaging/index|Packaging with Helm]].
