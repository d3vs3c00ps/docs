---
title: "Configuration and secrets"
description: "Getting configuration and secrets into pods, and the tools for templating manifests."
tags: [configuration]
type: moc
status: complete
---

<!-- generated-moc -->

# Configuration and secrets

Getting configuration and secrets into pods, and the tools for templating manifests.


| Note | | What it covers |
| --- | --- | --- |
| [[kubernetes/configuration/exercise-configmap\|Exercise — ConfigMaps]] | concept | Exercise: serve the static files of the wordsmith app from a ConfigMap, with a solution |
| [[kubernetes/configuration/kustomize\|Kustomize]] | lab | Transform existing Kubernetes YAML with kustomizations: patches, generators, images, transformers and replacements |
| [[kubernetes/configuration/managing-configuration\|Managing configuration]] | lab | Passing configuration to containers: command-line arguments, environment variables, the downward API, and ConfigMaps as files or variables |
| [[kubernetes/configuration/sealed-secrets\|Sealed Secrets]] | lab | Store encrypted Secrets in git with Sealed Secrets: kubeseal, scopes, offline sealing and key rotation |
| [[kubernetes/configuration/secrets\|Managing secrets]] | lab | Kubernetes Secrets: how they differ from ConfigMaps, Secret types, private registry credentials, base64, encryption at rest, immutability |
| [[kubernetes/configuration/templating\|Manifest Templating]] | concept | Ways to adapt Kubernetes manifests between environments: sed, envsubst, jsonnet, CUE, ytt, Helm and Kustomize |
| [[kubernetes/configuration/ytt\|YTT]] | concept | ytt, the YAML Templating Tool from Carvel: Starlark code in YAML comments, data values, libraries and overlays |

> [!info] Derived from container.training
> Pages in this section marked with a `source` in their frontmatter are
> derived from [container.training](https://github.com/jpetazzo/container.training)
> under CC BY 4.0, with changes. See [[attribution]].

Part of [[kubernetes/index|Kubernetes]].
