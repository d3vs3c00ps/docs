---
title: "Declarative vs imperative in Kubernetes"
description: "Kubernetes takes a spec, stores it, and controllers make the cluster match it"
tags: [kubernetes, architecture]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/declarative.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Declarative vs imperative in Kubernetes

## The API takes a spec

With Kubernetes, you cannot say "run this container". You can only write a *spec* and
send it to the API server, by creating a resource such as a Pod or a Deployment.

1. The API server validates the spec. It rejects the spec if it is invalid.
2. It stores the spec in etcd.
3. A *controller* notices the spec and acts on it.

For example, this Pod has no image. The API server rejects it and stores nothing:

```bash
kubectl apply -f- <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: no-image
spec:
  containers:
    - name: app
EOF
```

The error says `spec.containers[0].image: Required value`.

## Reconciling state

Look for the `spec` fields in the YAML files of the next chapters.

- The *spec* describes how you want the thing to be.
- Kubernetes *reconciles* the current state with the spec. A number of *controllers*
  do this work.
- The current state is written in the `status` field of the same object.
- To change a resource, you update its *spec*. Kubernetes then *converges* the resource
  to the new spec.

For example, a Deployment's spec says how many replicas you want. When you change that
number, the Deployment controller (through a ReplicaSet) creates or deletes Pods until
the status matches the spec:

```bash
kubectl create deployment web --image=nginx --replicas=1
kubectl scale deployment web --replicas=3
kubectl get deployment web -o jsonpath='{.spec.replicas} {.status.readyReplicas}'
```

The last command prints `3 1`, then `3 2`, then `3 3` once the state has converged.

[[kubernetes/concepts/architecture]] describes the parts of the control plane that do
this work.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/declarative.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/declarative.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose, with runnable examples of validation and reconciliation added.

<!-- uplink -->
Part of [[kubernetes/concepts/index|Concepts]].
