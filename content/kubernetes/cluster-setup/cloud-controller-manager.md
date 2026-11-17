---
title: "The Cloud Controller Manager"
description: "Kubernetes has many features that are cloud-specific"
tags: [kubernetes, installation]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/cloud-controller-manager.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# The Cloud Controller Manager

> [!note] Not tested locally
> A Cloud Controller Manager talks to a cloud API, and the tests run on kind. The
> closest local example is cloud-provider-kind, which gives LoadBalancer Services an
> address; it is used in [[kubernetes/cluster-setup/kind-in-practice]].

- Kubernetes has many features that are cloud-specific

  (e.g. providing cloud load balancers when a Service of type LoadBalancer is created)

- These features were initially implemented in API server and controller manager

- Since Kubernetes 1.6, these features are available through a separate process:

  the *Cloud Controller Manager*

- The CCM is optional, but if we run in a cloud, we probably want it!

## Cloud Controller Manager duties

- Creating and updating cloud load balancers

- Configuring routing tables in the cloud network (specific to GCE)

- Updating node labels to indicate region, zone, instance type...

- Obtain node name, internal and external addresses from cloud metadata service

- Deleting nodes from Kubernetes when they're deleted in the cloud

- Managing *some* volumes (e.g. EBS volumes, AzureDisks...)

  (Today, volumes are managed by Container Storage Interface drivers)

## In-tree vs. out-of-tree

- A number of cloud providers are supported "in-tree"

  (in the main kubernetes/kubernetes repository on GitHub)

- More cloud providers are supported "out-of-tree"

  (with code in different repositories)

- There is an [ongoing effort](https://github.com/kubernetes/kubernetes/tree/master/pkg/cloudprovider) to move everything to out-of-tree providers

## In-tree providers

> [!warning] Removed in Kubernetes 1.31
> The move to out-of-tree providers is finished: Kubernetes 1.31 removed the last
> in-tree cloud providers. Every cloud now needs its external Cloud Controller
> Manager (and CSI drivers for its volumes). The lists below are historical.

The following providers were actively maintained:

- Amazon Web Services
- Azure
- Google Compute Engine
- IBM Cloud
- OpenStack
- VMware vSphere

These ones are less actively maintained:

- Apache CloudStack
- oVirt
- VMware Photon

## Out-of-tree providers

The list includes the following providers:

- DigitalOcean

- keepalived (not exactly a cloud; provides VIPs for load balancers)

- Linode

- Oracle Cloud Infrastructure

(And possibly others; there is no central registry for these.)

## Audience questions

- What kind of clouds are you using/planning to use?

- What kind of details would you like to see in this section?

- Would you appreciate details on clouds that you don't / won't use?

## Cloud Controller Manager in practice

- Write a configuration file

  (typically `/etc/kubernetes/cloud.conf`)

- Run the CCM process

  (on self-hosted clusters, this can be a DaemonSet selecting the control plane nodes)

- Start kubelet with `--cloud-provider=external`

- When using managed clusters, this is done automatically

- There is very little documentation on writing the configuration file

  (except for OpenStack)

## Bootstrapping challenges

- When a node joins the cluster, it needs to obtain a signed TLS certificate

- That certificate must contain the node's addresses

- These addresses are provided by the Cloud Controller Manager

  (at least the external address)

- To get these addresses, the node needs to communicate with the control plane

- ...Which means joining the cluster

(The problem didn't occur when cloud-specific code was running in kubelet: kubelet could obtain the required information directly from the cloud provider's metadata service.)

## More information about CCM

- CCM configuration and operation is highly specific to each cloud provider

  (which is why this section remains very generic)

- The Kubernetes documentation has *some* information:

  - [architecture and diagrams](https://kubernetes.io/docs/concepts/architecture/cloud-controller/)

  - [configuration](https://kubernetes.io/docs/concepts/cluster-administration/cloud-providers/) (mainly for OpenStack)

  - [deployment](https://kubernetes.io/docs/tasks/administer-cluster/running-cloud-controller/)

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/cloud-controller-manager.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/cloud-controller-manager.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> in-tree removal noted, ELB/EBS mix-up fixed, "not tested" notice added.

<!-- uplink -->
Part of [[kubernetes/cluster-setup/index|Cluster setup]].
