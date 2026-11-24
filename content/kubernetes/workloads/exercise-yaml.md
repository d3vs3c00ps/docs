---
title: "Exercise — writing YAML"
description: "Exercise: write YAML manifests for the wordsmith app, and test them in a new namespace"
tags: [kubernetes, kubectl]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/exercise-yaml.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Exercise — writing YAML

Let's write YAML manifests for the wordsmith app, deployed in
[[kubernetes/workloads/exercise-wordsmith]]. It can be a single YAML file, or
several files in a directory.

The sections below explain how to test the YAML, and give hints.

## How to test our YAML

If `XYZ` is that YAML file (or directory with YAML files), we should be able to:

1. Create a new namespace, for example `foo123`.
2. Deploy wordsmith with a single command, for example
   `kubectl apply --namespace foo123 -f XYZ`.
3. Find the connection information for `web`, for example
   `kubectl get service web --namespace foo123`.
4. Connect to it and see the wordsmith app.

## Strategies

There are at least three ways to write our YAML:

1. Dump the YAML of the existing wordsmith Deployments and Services, with
   `kubectl get -o yaml ...`.
2. Adapt existing YAML, from the docs or from DockerCoins. For reference, kubercoins
   is at <https://github.com/jpetazzo/kubercoins> (see
   [[kubernetes/workloads/kubercoins]]).
3. Write it entirely from scratch.

> [!tip] Cleaning up a dump
> A dump has fields that belong to the live object. Remove them before you apply it
> elsewhere:
>
> - `metadata.namespace`: otherwise `kubectl apply --namespace foo123` fails with
>   `the namespace from the provided object ... does not match the namespace "foo123"`;
> - `metadata.uid`, `metadata.resourceVersion`, `metadata.creationTimestamp`, and
>   `status`;
> - in Services, `spec.clusterIP` and `spec.clusterIPs`: otherwise the new Service
>   asks for the same IP address, and fails with `provided IP is already allocated`;
> - in NodePort Services, `nodePort`, for the same reason.
>
> With `jq`, for example:
>
> ```bash
> kubectl get deployment,service db words web -o json |
>   jq '.items[] |= (del(.status, .metadata.namespace, .metadata.uid,
>                        .metadata.resourceVersion, .metadata.creationTimestamp,
>                        .spec.clusterIP, .spec.clusterIPs, .spec.ports[]?.nodePort))' > wordsmith.json
> ```

## Adapting YAML

Read these hints one at a time.

One option is to start with the YAML from kubercoins
(<https://github.com/jpetazzo/kubercoins>).

Adapt the YAML of a Deployment (for example `worker`) to run `web`. We need to
change the name, labels, selectors, and image.

Then adapt the YAML of a Service (for example `webui`). We need to change the name,
labels, selectors, and maybe the port number.

Repeat for the other components.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/exercise-yaml.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/exercise-yaml.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> The step 3 command was fixed, and a tip on cleaning up a dump was added.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
