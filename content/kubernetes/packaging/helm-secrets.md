---
title: "Helm secrets"
description: "to previously installed charts"
tags: [kubernetes, helm, secrets]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/helm-secrets.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Helm secrets

- Helm can do *rollbacks*:

  - to previously installed charts

  - to previous sets of values

- How and where does it store the data needed to do that?

- Let's investigate!

## We need a release

- We need to install something with Helm

- Let's use the OWASP Juice Shop chart as an example

> [!example] Hands-on
> - Install a release called `orange` with the `juice-shop` chart:
>   ```bash
>   helm upgrade orange oci://ghcr.io/securecodebox/helm/juice-shop --install
>   ```
>
> - Let's upgrade that release, and change a value:
>   ```bash
>   helm upgrade orange oci://ghcr.io/securecodebox/helm/juice-shop --set ingress.enabled=true
>   ```

## Release history

- Helm stores successive revisions of each release

> [!example] Hands-on
> - View the history for that release:
>   ```bash
>   helm history orange
>   ```

Where does that come from?

## Investigate

- Possible options:

  - local filesystem (no, because history is visible from other machines)

  - persistent volumes (no, Helm works even without them)

  - ConfigMaps, Secrets?

> [!example] Hands-on
> - Look for ConfigMaps and Secrets:
>   ```bash
>   kubectl get configmaps,secrets
>   ```

We should see a number of secrets with TYPE `helm.sh/release.v1`.

## Unpacking a secret

- Let's find out what is in these Helm secrets

> [!example] Hands-on
> - Examine the secret corresponding to the second release of `orange`:
>   ```bash
>   kubectl describe secret sh.helm.release.v1.orange.v2
>   ```
>   (`v1` is the secret format; `v2` means revision 2 of the `orange` release)

There is a key named `release`.

## Unpacking the release data

- Let's see what's in this `release` thing!

> [!example] Hands-on
> - Dump the secret:
>   ```bash
>   kubectl get secret sh.helm.release.v1.orange.v2 \
>       -o go-template='{{ .data.release }}'
>   ```

Secrets are encoded in base64. We need to decode that!

## Decoding base64

- We can pipe the output through `base64 -d` or use go-template's `base64decode`

> [!example] Hands-on
> - Decode the secret:
>   ```bash
>   kubectl get secret sh.helm.release.v1.orange.v2 \
>       -o go-template='{{ .data.release | base64decode }}'
>   ```

... Wait, this *still* looks like base64. What's going on?

Let's try one more round of decoding!

## Decoding harder

- Just add one more base64 decode filter

> [!example] Hands-on
> - Decode it twice:
>   ```bash
>   kubectl get secret sh.helm.release.v1.orange.v2 \
>       -o go-template='{{ .data.release | base64decode | base64decode }}'
>   ```

... OK, that was *a lot* of binary data. What should we do with it?

## Guessing data type

- We could use `file` to figure out the data type

> [!example] Hands-on
> - Pipe the decoded release through `file -`:
>   ```bash
>   kubectl get secret sh.helm.release.v1.orange.v2 \
>       -o go-template='{{ .data.release | base64decode | base64decode }}' \
>       | file -
>   ```

Gzipped data! It can be decoded with `gunzip -c`.

## Uncompressing the data

- Let's uncompress the data and save it to a file

> [!example] Hands-on
> - Rerun the previous command, but with `| gunzip -c > release-info` :
>   ```bash
>   kubectl get secret sh.helm.release.v1.orange.v2 \
>       -o go-template='{{ .data.release | base64decode | base64decode }}' \
>       | gunzip -c > release-info
>   ```
>
> - Look at `release-info`:
>   ```bash
>   cat release-info
>   ```

It's a bundle of ~~YAML~~ JSON.

## Looking at the JSON

If we inspect that JSON (e.g. with `jq keys release-info`), we see:

- `apply_method` (Helm 4: `ssa`, for server-side apply)
- `chart` (contains the entire chart used for that release)
- `config` (contains the values that we've set)
- `hooks` (Helm 4: the hooks defined in the chart, such as its tests)
- `info` (date of deployment, status messages)
- `manifest` (YAML generated from the templates)
- `name` (name of the release, so `orange`)
- `namespace` (namespace where we deployed the release)
- `version` (revision number within that release; starts at 1)

The chart is in a structured format, but it's entirely captured in this JSON.

## Conclusions

- Helm stores each release information in a Secret in the namespace of the release

- The secret is a JSON object (gzipped and encoded in base64)

- It contains the manifests generated for that release

- ... And everything needed to rebuild these manifests

  (including the full source of the chart, and the values used)

- This allows arbitrary rollbacks, as well as tweaking values even without having access to the source of the chart (or the chart repo) used for deployment

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/helm-secrets.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/helm-secrets.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> chart repository moved to its OCI registry, release keys updated for Helm 4.

<!-- uplink -->
Part of [[kubernetes/packaging/index|Packaging with Helm]].
