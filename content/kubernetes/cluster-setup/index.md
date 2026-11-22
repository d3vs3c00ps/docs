---
title: "Cluster setup"
description: "Building clusters: from first principles, with installers, as a managed service, and locally. Plus upgrades and backups."
tags: [cluster-setup]
type: moc
status: complete
---

<!-- generated-moc -->

# Cluster setup

Building clusters: from first principles, with installers, as a managed service, and locally. Plus upgrades and backups.


| Note | | What it covers |
| --- | --- | --- |
| [[kubernetes/cluster-setup/access-eks-cluster\|Accessing our EKS cluster]] | lab | We also have a shared EKS cluster |
| [[kubernetes/cluster-setup/apilb\|API server availability]] | concept | sometimes for the pod network system (like kube-router) |
| [[kubernetes/cluster-setup/aws-eks\|Amazon EKS]] | concept | Elastic Kubernetes Service |
| [[kubernetes/cluster-setup/cloud-controller-manager\|The Cloud Controller Manager]] | concept | Kubernetes has many features that are cloud-specific |
| [[kubernetes/cluster-setup/cluster-backup\|Backing up clusters]] | lab | disaster recovery (servers or storage are destroyed or unreachable) |
| [[kubernetes/cluster-setup/cluster-upgrade\|Upgrading clusters]] | lab | It's recommended to run consistent versions across a cluster |
| [[kubernetes/cluster-setup/dmuc-easy\|Building our own cluster (easy)]] | lab | Let's build our own cluster! |
| [[kubernetes/cluster-setup/dmuc-hard\|Building our own cluster (hard)]] | lab | This section assumes that you already went through |
| [[kubernetes/cluster-setup/dmuc-medium\|Building our own cluster (medium)]] | lab | This section assumes that you already went through |
| [[kubernetes/cluster-setup/interco\|Interconnecting clusters]] | lab | We assigned different Cluster CIDRs to each cluster |
| [[kubernetes/cluster-setup/k0s\|K01 - Setting up a cluster with k0s]] | lab | Running a Kubernetes cluster in the cloud can be relatively straightforward |
| [[kubernetes/cluster-setup/k3s\|k3s]] | how-to | A small, complete Kubernetes distribution in one binary — install, config file, bundled components and how to replace them, HA with embedded etcd, snapshots, upgrades, air-gap, and k3d for local clusters |
| [[kubernetes/cluster-setup/kind-in-practice\|kind in practice]] | how-to | Using kind as a local and CI test cluster — pinned versions, multi-node configs, loading images, a local registry, LoadBalancer and Ingress with cloud-provider-kind, NetworkPolicy, kubeadm patches |
| [[kubernetes/cluster-setup/kind\|Working with KinD]] | concept | One of the many options to run local clusters |
| [[kubernetes/cluster-setup/localkubeconfig\|Controlling a Kubernetes cluster remotely]] | lab | kubectl can be used either on cluster instances or outside the cluster |
| [[kubernetes/cluster-setup/multinode\|Adding nodes to the cluster]] | lab | So far, our cluster has only 1 node |
| [[kubernetes/cluster-setup/setup-devel\|Running a local development cluster]] | concept | Let's review some options to run Kubernetes locally |
| [[kubernetes/cluster-setup/setup-managed\|Deploying a managed cluster]] | concept | *'The easiest way to install Kubernetes is to get someone |
| [[kubernetes/cluster-setup/setup-overview\|Setting up Kubernetes]] | concept | Kubernetes is made of many components that require careful configuration |
| [[kubernetes/cluster-setup/setup-selfhosted\|Kubernetes distributions and installers]] | concept | Sometimes, we need to run Kubernetes ourselves |
| [[kubernetes/cluster-setup/staticpods\|Static pods]] | concept | Question: can we host the control plane of a cluster on the cluster itself? |

> [!info] Derived from container.training
> Pages in this section marked with a `source` in their frontmatter are
> derived from [container.training](https://github.com/jpetazzo/container.training)
> under CC BY 4.0, with changes. See [[attribution]].

Part of [[kubernetes/index|Kubernetes]].
