---
title: "Static pods"
description: "Question: can we host the control plane of a cluster on the cluster itself?"
tags: [kubernetes, installation]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/staticpods.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Static pods

Question: can we host the control plane of a cluster *on the cluster itself?*

- To create a Pod, we need to communicate with the API server

- The API server needs etcd to be up

- Then the Pod needs to be bound to a node by the scheduler

- So... all these things need to be running already!

- Even if the Pod already exists, we still need API server and etcd

  (so that kubelet can connect to the API server and "know" about the Pod)

## Static pods

Solution: run (parts of) the control plane in *static pods!*

- Normally, kubelet queries the API server to know what pods to run

- Additionally, we can tell kubelet to run pods:

  - by storing manifests in a directory (`--pod-manifest-path`)

  - by retrieving manifests from an HTTP server (`--manifest-url`)

  (these flags are deprecated: today they are the `staticPodPath` and `staticPodURL`
  fields of the kubelet configuration file; kubeadm sets
  `staticPodPath: /etc/kubernetes/manifests`)

- These manifests should be normal pod manifests

  (make sure to include the namespace in the metadata block!)

- kubelet will append the node name after the pod name

## How and when kubelet runs static pods

- kubelet runs static pods "no matter what"

  (even if it can't connect to the API server, or if no API server is configured)

- When there is no API server configuration, that's called "standalone mode"

- Almost nothing can prevent kubelet from running these pods

  (e.g. admission controllers, pod security settings... won't apply)

- kubelet monitors the manifest path (and/or the manifest URL)

- If manifests are deleted: their pods are destroyed

- If manifests are modified: their pods are destroyed and recreated

## Mirror pods

- Static pods remain running even after API server connection is up

- Once the API server is up, kubelet will create *mirror pods*

- Mirror pods represent the static pods that are running

> [!warning]
> Deleting a mirror pod has no effect on the static pod!

- kubelet will immediately recreate the mirror pod if it is deleted

> [!warning]
> Admission control can block the mirror pod, but not the static pod!

- Since kubelet runs the static pod even if there is no connection to the API server

## Example

- `kubeadm` leverages static pods to run the control plane

  (etcd, API server, controller manager, scheduler)

- It "renders" a number of YAML manifests to `/etc/kubernetes/manifests`

- This is the cluster boot sequence:

  - machine boots

  - kubelet is started (typically by systemd)

  - kubelet reads static pod manifests and run them

  - control plane is up, yay!

> [!note]- Extra details
> ## Pod checkpointer
>
> - This pattern isn't used anymore, but perhaps it can provide inspiration
>
> - The pod checkpointer automatically generates manifests of running pods
>
>   (if they have specific labels/annotations)
>
> - The manifests are used to restart these pods if API contact is lost
>
> - This pattern is implemented in [openshift/pod-checkpointer-operator] and [bootkube checkpointer]
>
> - Unfortunately, as of 2021, both seem abandoned / unmaintained 😢
>
> [openshift/pod-checkpointer-operator]: https://github.com/openshift/pod-checkpointer-operator
> [bootkube checkpointer]: https://github.com/kubernetes-retired/bootkube/blob/master/cmd/checkpoint/README.md

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/staticpods.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/staticpods.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> kubelet configuration fields added, claims tested on kind with Kubernetes 1.37.

<!-- uplink -->
Part of [[kubernetes/cluster-setup/index|Cluster setup]].
