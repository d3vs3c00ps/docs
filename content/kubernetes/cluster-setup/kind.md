---
title: "Working with KinD"
description: "One of the many options to run local clusters"
tags: [kubernetes, installation, kind]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kind.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Working with KinD

> [!tip] Hands-on version
> This page is the overview. For the options you need to use kind as a real test
> cluster (pinned images, a local registry, LoadBalancer and Ingress with
> cloud-provider-kind, NetworkPolicy, kubeadm patches), see
> [[kubernetes/cluster-setup/kind-in-practice]].

- Kubernetes-in-Docker

- One of the many options to run local clusters

  (like Colima, Docker Desktop, k3d, Minikube, Podman Desktop...)

- Runs Kubernetes nodes inside Docker containers

  (also works with other container engines)

- Based on kubeadm

## Pros

- Create a cluster in less than 1 minute

- Run multiple clusters side by side

- Clusters can have 1 or multiple nodes

- Select Kubernetes version to use

  (great to test regressions, upgrades...)

- Supports port mapping (more on that later)

- Very close to "upstream Kubernetes"

  (typically runs "normal" Kubernetes binaries)

## Cons

- Requires a container engine

  (Docker, Podman...)

- Port mapping can only be configured at cluster creation time

  (more on that later)

- Releases can lag a bit behind Kubernetes "latest" releases

- Not a lot of pre-installed bells and whistles

  (e.g. no ingress controller, no metrics server...)

## Getting started

- Creating a cluster:
  ```bash
  kind create cluster
  ```

- Cluster will be automatically added to your kubeconfig file

- See it running with `docker ps`

- Deleting a cluster:
  ```bash
  kind delete cluster
  ```

## Customizing the cluster

- This is done with a configuration file

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: kindest/node:v1.34.3
  extraPortMappings:
  - containerPort: 31234
    hostPort: 10000
- role: worker
  image: kindest/node:v1.34.3
```

- And then: `kind create cluster --config XXX.yaml`

## Accessing internal apps

- There are many ways to access apps running in a KinD cluster

- We'll review some of them, with their pros/cons!

## `kubectl port-forward`

- Works everywhere (local or remote, dev or prod...)

- Gated by RBAC with `pod/port-forward` subresource

- Inconvenient when accessing multiple services

- Inconvenient when working in Ingress or Gateway API

## NodePorts

- Use `NodePort` services

- Plan A: access them with the node IP address

  *does not work when the Docker host is a separate VM (e.g. with Docker Desktop)*

- Plan B: configure KinD to map extra ports

  *works everywhere; but needs some prep ahead of time*

## Example, mapping ports 80 and 443

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 80
  - containerPort: 30443
    hostPort: 443
```

- Configure Ingress or Gateway Controllers to use NodePorts 30080 and 30443

- Use a domain like `localtest.me` that resolves to 127.0.0.1

- Create Ingress or HTTPRoute resources using `<something>.localtest.me`

## Variation

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
  - containerPort: 443
    hostPort: 443
```

- Configure Ingress or Gateway Controllers to use `hostNetwork` or `hostPort`

## Example, mapping a range of ports

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        - name: service-node-port-range
          value: "12301-12309"
  extraPortMappings:
  - { containerPort: 12301, hostPort: 12301 }
  - { containerPort: 12302, hostPort: 12302 }
  ...
  - { containerPort: 12308, hostPort: 12308 }
  - { containerPort: 12309, hostPort: 12309 }
```

([`k8s/kind-12300.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/kind-12300.yaml))

> [!note] Two forms of `extraArgs`
> The upstream `kind-12300.yaml` writes `extraArgs` as a map:
> `service-node-port-range: "12301-12309"`. kubeadm's current `v1beta4` configuration
> uses a list of `name` / `value` pairs, as above. kind 0.33 with Kubernetes 1.37
> accepts both forms (tested): the API server gets the flag either way. See also
> [[kubernetes/cluster-setup/kind-in-practice]].

## Other noteworthy features

- [Extra mounts][kind-extra-mounts] to expose local files to pods

- Useful for big data sets (e.g. ML model weights)

- Need to remember that there is a double mapping:

  *host → Kubernetes node in Docker container*

  *Kubernetes node in Docker container → pod*

- Don't hesitate to use `docker exec` to get a shell in the Kubernetes node!

[kind-extra-mounts]: https://kind.sigs.k8s.io/docs/user/configuration/#extra-mounts

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/kind.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kind.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> kubeadm patch updated to `v1beta4`, configs tested with kind on Kubernetes 1.37.

<!-- uplink -->
Part of [[kubernetes/cluster-setup/index|Cluster setup]].
