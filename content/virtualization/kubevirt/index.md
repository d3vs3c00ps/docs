---
title: "KubeVirt"
description: "Virtual machines as Kubernetes resources — one control plane for VMs and containers, and the storage and networking choices that decide whether they can migrate."
tags: [kubevirt]
type: moc
status: complete
---

<!-- generated-moc -->

# KubeVirt

Virtual machines as Kubernetes resources — one control plane for VMs and containers, and the storage and networking choices that decide whether they can migrate.


| Note | | What it covers |
| --- | --- | --- |
| [[virtualization/kubevirt/advanced\|KubeVirt storage, networking and migration]] | reference | Choosing storage that can migrate, the four network binding modes, multus and SR-IOV, live migration requirements, and hotplug |
| [[virtualization/kubevirt/basics\|KubeVirt basics]] | how-to | Installing the operator and CDI, virtctl, defining a first VM from a container disk or a DataVolume, and cloud-init |
| [[virtualization/kubevirt/gitops\|KubeVirt with GitOps]] | how-to | Declaring VMs in Git — what belongs in a repository and what does not, drift on mutable fields, secrets in cloud-init, and templating with Kustomize |
| [[virtualization/kubevirt/introduction\|What KubeVirt is]] | concept | Running virtual machines as Kubernetes resources — the architecture, the VM-in-a-pod model, and when this is a good idea |
| [[virtualization/kubevirt/troubleshooting\|KubeVirt troubleshooting]] | reference | VMIs stuck pending, DataVolume imports that never finish, migration failures, console access problems, and where the logs actually are |

Part of [[virtualization/index|Virtualisation]].
