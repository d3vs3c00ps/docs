---
title: "API server availability"
description: "sometimes for the pod network system (like kube-router)"
tags: [kubernetes, installation]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/apilb.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# API server availability

> [!note] Not tested locally
> This page compares designs and has no commands. A multi-control-plane kind cluster
> shows option 1 in action: kind adds a load balancer container in front of the API
> servers.

- When we set up a node, we need the address of the API server:

  - for kubelet

  - for kube-proxy

  - sometimes for the pod network system (like kube-router)

- How do we ensure the availability of that endpoint?

  (what if the node running the API server goes down?)

## Option 1: external load balancer

- Set up an external load balancer

- Point kubelet (and other components) to that load balancer

- Put the node(s) running the API server behind that load balancer

- Update the load balancer if/when an API server node needs to be replaced

- On cloud infrastructures, some mechanisms provide automation for this

  (e.g. on AWS, an Elastic Load Balancer + Auto Scaling Group)

- Example in older editions of [Kubernetes The Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way)
  (the current edition has a single control plane node and no load balancer)

## Option 2: local load balancer

- Set up a load balancer (like NGINX, HAProxy...) on *each* node

- Configure that load balancer to send traffic to the API server node(s)

- Point kubelet (and other components) to `localhost`

- Update the load balancer configuration when API server nodes are updated

## Updating the local load balancer config

- Distribute the updated configuration (push)

- Or regularly check for updates (pull)

- The latter requires an external, highly available store

  (it could be an object store, an HTTP server, or even DNS...)

- Updates can be facilitated by a DaemonSet

  (but remember that it can't be used when installing a new node!)

## Option 3: DNS records

- Put all the API server nodes behind a round-robin DNS

- Point kubelet (and other components) to that name

- Update the records when needed

- Note: this option is not officially supported

  (but since kubelet supports reconnection anyway, it *should* work)

## Option 4: other mechanisms

- Many managed clusters expose a high-availability API endpoint

  (and you don't have to worry about it)

- You can also use HA mechanisms that you're familiar with

  (e.g. virtual IPs, with keepalived or [kube-vip](https://kube-vip.io/))

- Tunnels are also fine

  (e.g. [k3s](https://k3s.io/) uses a tunnel to allow each node to contact the API server)

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/apilb.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/apilb.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> dead link replaced, kube-vip added, "not tested" notice added.

<!-- uplink -->
Part of [[kubernetes/cluster-setup/index|Cluster setup]].
