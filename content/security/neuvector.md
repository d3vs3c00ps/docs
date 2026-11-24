---
title: NeuVector
description: Deploying NeuVector for container runtime security on Kubernetes — what it does, installing it with Helm, and reaching the console
tags: [security, kubernetes, containers, runtime-security, observability]
type: howto
status: complete
---

# NeuVector

NeuVector is a container security platform for Kubernetes, open-sourced by SUSE
under Apache 2.0. Where [[security/secure-container-images]] covers what goes *into*
an image and [[kubernetes/security/pod-security-admission]] covers what a pod is
*allowed* to request, NeuVector watches what containers actually do once running.

It covers roughly four things:

- **Runtime protection** — process and file-access monitoring inside containers,
  with a learning mode that builds an allow-list of normal behaviour before it starts
  blocking.
- **Network inspection** — a layer-7 firewall between pods, which is a genuinely
  different thing from a [[kubernetes/networking/netpol|NetworkPolicy]]: it inspects
  protocol payloads rather than filtering on labels and ports.
- **Vulnerability and compliance scanning** — images in registries, running
  containers, and the host itself, plus CIS benchmark runs.
- **Admission control** — refusing deployments that fail policy.

> [!note] Where it sits against the alternatives
> NeuVector's distinguishing feature is the layer-7 network firewall and its
> behavioural learning mode. [Falco](https://falco.org/) is the lighter-weight,
> CNCF-graduated option if you only want syscall-level runtime detection, and
> Tetragon is the eBPF-native equivalent. NeuVector is considerably heavier: it runs
> a privileged DaemonSet on every node.

## Prerequisites

NeuVector's enforcer needs privileged access to the host — it inspects network
traffic and process activity from inside a DaemonSet. That means the namespace has
to permit it under Pod Security Admission.

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
```

If a host firewall sits between nodes, the cluster's own traffic and NeuVector's
inter-component ports must be allowed through before deployment. Sort that out
first — a partially reachable enforcer set is confusing to debug.

## Installation

```bash
helm repo add neuvector https://neuvector.github.io/neuvector-helm/
helm repo update

kubectl create namespace neuvector
kubectl label namespace neuvector \
  "pod-security.kubernetes.io/enforce=privileged"

helm install neuvector neuvector/core \
  --namespace neuvector
```

> [!warning] That label is a real exemption
> `pod-security.kubernetes.io/enforce=privileged` disables Pod Security Admission for
> the whole namespace. It is required here — the enforcer cannot work without host
> access — but it means the namespace is now the least protected part of the cluster,
> and anything that can create a pod in it can take over the node. Keep NeuVector's
> namespace to NeuVector, and restrict who can write to it with RBAC.

## Reaching the console

The chart creates the web UI service, `neuvector-service-webui`, as a `ClusterIP`
service on port 8443. Forward it to your workstation:

```bash
kubectl port-forward --namespace neuvector \
  service/neuvector-service-webui 8443:8443
```

To reach it on a NodePort instead, install with `--set manager.svc.type=NodePort`,
then find the port:

```bash
NODE_PORT=$(kubectl get --namespace neuvector \
  -o jsonpath="{.spec.ports[0].nodePort}" services neuvector-service-webui)
NODE_IP=$(kubectl get nodes \
  -o jsonpath="{.items[0].status.addresses[0].address}")

echo "https://$NODE_IP:$NODE_PORT"
```

> [!note] `ClusterIP` by default
> With the chart's defaults (core 2.11), the web UI service is `ClusterIP`, not
> `NodePort`.

Then open `https://localhost:8443`. The console uses a self-signed certificate, so
expect a browser warning on first connection.

> [!warning] Change the default credentials immediately
> NeuVector ships with `admin` / `admin`. The console is a full cluster-security
> control plane — change the password before exposing it anywhere, and prefer an
> Ingress with real TLS and SSO over a long-lived `port-forward`.
>
> Binding the forward to `0.0.0.0` publishes it on every interface of your
> workstation. Leave it on the default localhost binding unless you specifically
> intend otherwise.

## First steps after install

1. Leave the enforcer in **Discover** mode long enough to learn normal behaviour
   across a full workload cycle — including batch jobs and backups, which are exactly
   what a short learning window misses.
2. Move to **Monitor** to see what *would* be blocked, without blocking it.
3. Only then switch to **Protect**.

Skipping from Discover straight to Protect is the usual way to take down a
production namespace with a security tool.

## Where to go next

- [[security/secure-container-images]] — build-time controls, upstream of this
- [[kubernetes/security/pod-security-admission]] — the admission layer NeuVector opts out of
- [[kubernetes/networking/netpol]] — label-based network policy, the layer-3/4 counterpart

<!-- uplink -->
Part of [[security/index|Security]].
