---
title: "My own Kubernetes notes"
description: "Original material rather than derived from the course: a hard-way cluster build, and notes on the parts I wanted to understand more deeply than the slides went."
tags: [my-notes]
type: moc
status: complete
---

<!-- generated-moc -->

# My own Kubernetes notes

Original material rather than derived from the course: a hard-way cluster build, and notes on the parts I wanted to understand more deeply than the slides went.


| Note | | What it covers |
| --- | --- | --- |
| [[kubernetes/my-notes/architecture\|Kubernetes architecture and the API]] | lab | What runs on a node and in the control plane, the communication protocols, and how the declarative API works — with GVK and watch semantics |
| [[kubernetes/my-notes/cni\|CNI plugin internals]] | concept | How the container runtime invokes CNI plugins — the environment-variable contract, conf versus conflist, and plugin chaining |
| [[kubernetes/my-notes/concepts\|Kubernetes concepts (RKE2 and Cilium)]] | concept | What Kubernetes does, its architecture, and the specific choices made in an RKE2 with Cilium deployment |
| [[kubernetes/my-notes/vanilla-cluster-lab\|Building a vanilla Kubernetes cluster]] | lab | Building a minimal Kubernetes cluster by hand from the official binaries: certificates, kubeconfigs, etcd, control plane and workers on three openSUSE nodes |

Part of [[kubernetes/index|Kubernetes]].
