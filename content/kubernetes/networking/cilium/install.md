---
title: Installing Cilium
description: Prerequisites, Helm and cilium-cli installs, the kube-proxy-free bootstrap, RKE2's bundled Cilium, and verifying the result before you trust it
tags: [kubernetes, networking, cilium, cni, helm, rke2]
type: howto
status: complete
---

# Installing Cilium

Cilium 1.20.0 is the current stable release (29 July 2026). It is built against
Kubernetes 1.36 and supports the four maintained Kubernetes minors.

For what the options mean before you set them, read
[[kubernetes/networking/cilium/basics]] first — particularly the routing and IPAM
sections, because those are the two decisions that are painful to change afterwards.

## Prerequisites

**Kernel.** 5.10 or newer for the general feature set. Individual features want more:
WireGuard needs 5.6+ with `CONFIG_WIREGUARD`, and BIG TCP and some XDP paths want
6.x. Check with `uname -r`.

**BPF filesystem.** Cilium pins its maps under `/sys/fs/bpf`. The agent mounts it
itself in most setups, but if it is missing and cannot be created, the agent
crash-loops:

```bash
mount | grep bpf
# bpf on /sys/fs/bpf type bpf (rw,nosuid,nodev,noexec,relatime,mode=700)
```

**No other CNI.** If the cluster already has one, remove it and its CNI
configuration from `/etc/cni/net.d` before installing. Two CNI configs in that
directory means the first in lexicographic order wins, silently.

**kube-proxy.** Decide now whether you are replacing it — see below.

## Installing with Helm

The chart is published to an OCI registry, so no `helm repo add` is needed:

```bash
helm install cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.0 \
  --namespace kube-system \
  --set operator.replicas=1
```

A more typical starting point, with kube-proxy replaced and Hubble on:

```bash
helm install cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.0 \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=10.0.0.1 \
  --set k8sServicePort=6443 \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList='{10.42.0.0/16}' \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
```

> [!danger] `k8sServiceHost` is mandatory when replacing kube-proxy
> Without kube-proxy nothing implements the `kubernetes` Service, so the agent
> cannot reach the API server through it — the very thing it needs in order to
> configure Services. Point it at a real address: a control-plane node IP, or the
> VIP or load balancer in front of them.
>
> Use the load balancer if you have one. A single control-plane node's IP makes
> that node a single point of failure for agent startup.

Keep the values in a file rather than accumulating `--set` flags — you will need
them again on every upgrade:

```bash
helm install cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.0 --namespace kube-system -f cilium-values.yaml
```

## Installing with cilium-cli

`cilium-cli` wraps the chart with sensible detection of your platform. Good for labs
and quick clusters; for anything you have to reproduce, prefer Helm with a values
file.

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
curl -sSL --fail --remote-name-all \
  "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}"
sha256sum --check "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"
sudo tar xzvfC "cilium-linux-${CLI_ARCH}.tar.gz" /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

cilium install --version 1.20.0
cilium status --wait
```

Note the checksum verification — the install snippet is worth keeping intact rather
than trimming to a bare `curl | tar`.

## Removing kube-proxy

If the cluster was built with kubeadm and already has kube-proxy, install Cilium with
`kubeProxyReplacement=true` first, confirm it is healthy, then remove it:

```bash
kubectl -n kube-system delete ds kube-proxy
kubectl -n kube-system delete cm kube-proxy

# on each node, clear the rules it left behind
sudo iptables-save | grep -v KUBE- | sudo iptables-restore
```

For a new kubeadm cluster, skip it from the start with
`kubeadm init --skip-phases=addon/kube-proxy`.

## On RKE2

RKE2 bundles Cilium as a supported CNI, so the install is a config file rather than a
Helm command. This is the path that trips people up, because `helm upgrade` on the
`cilium` release does not survive — RKE2 reconciles it.

Select Cilium in `/etc/rancher/rke2/config.yaml`, **before first start**:

```yaml
cni: cilium
```

Then customise it with a `HelmChartConfig` dropped into RKE2's manifests directory.
RKE2 watches that directory and merges the values into its own chart install:

```yaml
# /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |-
    kubeProxyReplacement: true
    k8sServiceHost: 127.0.0.1
    k8sServicePort: 6443
    hubble:
      enabled: true
      relay:
        enabled: true
      ui:
        enabled: true
```

> [!important] RKE2 specifics worth knowing
> - The release is named **`rke2-cilium`**, not `cilium`, and lives in `kube-system`.
> - `k8sServiceHost: 127.0.0.1` works on RKE2 because it runs a local API server
>   proxy on every node — you do not need a VIP here, unlike a kubeadm cluster.
> - Editing the HelmChartConfig and waiting is the correct workflow. Do **not**
>   `helm upgrade` directly; RKE2's helm-controller will revert it.
> - RKE2 disables kube-proxy for you when Cilium is configured to replace it.
>
> Watch the reconciliation:
>
> ```bash
> kubectl -n kube-system get helmchartconfig
> kubectl -n kube-system logs -l app=helm-controller -f
> ```

See [[kubernetes/my-notes/concepts]] for how this fits the wider RKE2 setup.

## Verifying

Do all four of these. The first three passing and the fourth failing is common.

**1. Agent and operator health**

```bash
cilium status --wait
```

**2. Every node's datapath**

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
```

Check `KubeProxyReplacement`, `Routing`, `IPAM` and `Encryption` say what you
intended, on a node you did not install from.

**3. Real connectivity**

```bash
cilium connectivity test
```

This creates a `cilium-test` namespace, runs several dozen pod-to-pod, pod-to-service
and pod-to-world checks, and cleans up. It takes a few minutes and is the only one of
these that would catch a broken underlay. Run it after any datapath change.

**4. A pod actually gets an address**

```bash
kubectl run probe --image=nicolaka/netshoot --rm -it --restart=Never -- \
  sh -c 'ip -4 addr show eth0; getent hosts kubernetes.default'
```

## Upgrading

Cilium supports upgrading one minor version at a time. Skipping minors is not
tested.

```bash
# always read these first — they are detailed and they matter
# https://docs.cilium.io/en/stable/operations/upgrade/

helm upgrade cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.0 --namespace kube-system \
  --reuse-values

kubectl -n kube-system rollout status ds/cilium
cilium status --wait
```

> [!warning] `--reuse-values` and new chart defaults
> `--reuse-values` keeps your overrides but does **not** pick up new defaults
> introduced by the new chart version. That is usually what you want mid-upgrade and
> occasionally the cause of a subtly wrong config afterwards. Using a values file
> with plain `-f` avoids the ambiguity entirely.

Cilium also ships a pre-flight check that pulls the new images and validates them
before you commit to the rollout — worth running on large clusters.

## Where to go next

- [[kubernetes/networking/cilium/basics]] — what the options above actually change
- [[kubernetes/networking/cilium/hubble]] — turning on observability
- [[kubernetes/networking/cilium/wireguard]] — adding transparent encryption
- [[kubernetes/networking/cilium/troubleshooting]] — when the install does not settle
- [[kubernetes/cluster-setup/index|Cluster setup]] — building the cluster underneath

<!-- uplink -->
Part of [[kubernetes/networking/cilium/index|Cilium]].
