---
title: k3s
description: A small, complete Kubernetes distribution in one binary — install, config file, bundled components and how to replace them, HA with embedded etcd, snapshots, upgrades, air-gap, and k3d for local clusters
tags: [kubernetes, cluster-setup, k3s, k3d, etcd]
type: howto
status: complete
---

# k3s

[k3s](https://k3s.io) is a Kubernetes distribution from Rancher (SUSE), now a CNCF
project. It is **certified Kubernetes**: the API is the same as upstream. What changes
is the packaging:

- one binary of 70 to 80 MB holds the API server, scheduler, controller manager,
  kubelet, kube-proxy, containerd and the tools (`kubectl`, `crictl`, `ctr`)
- one process per node
- the parts a real cluster needs are **included and running** after install: a CNI
  (flannel), DNS (CoreDNS), an ingress controller (Traefik), a load balancer
  (ServiceLB), storage (local-path), metrics-server, and a NetworkPolicy controller

It is a good fit for edge devices, small servers, home labs and CI. For a local
test cluster on your laptop, use it through **k3d** (see [below](#k3d-k3s-in-docker)).

## Install a server

The install script downloads the binary, installs a systemd service and starts it. Pin
the version:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.37.0+k3s1 sh -
# the script returns when the service has started, not when the API answers
until sudo k3s kubectl get nodes 2>/dev/null; do sleep 2; done
```

The first `kubectl get nodes` can fail with `connection refused` for about 30 seconds.
Then the node shows up, and becomes `Ready` a few seconds later.

> [!warning] Read the script before you pipe it to a shell
> `curl | sh` runs whatever the server sends. Download `https://get.k3s.io` first,
> read it, then run it. The script is the supported installer, so this is about
> checking, not avoiding it.

What the install creates:

| Path | What |
| --- | --- |
| `/usr/local/bin/k3s` | the binary; `kubectl`, `crictl` and `ctr` are symlinks to it |
| `/etc/systemd/system/k3s.service` | the service (`k3s-agent.service` on agents) |
| `/etc/rancher/k3s/k3s.yaml` | admin kubeconfig, readable by root only |
| `/var/lib/rancher/k3s/` | all state: datastore, certificates, images |
| `/var/lib/rancher/k3s/server/token` | the secret that other nodes use to join |
| `/usr/local/bin/k3s-uninstall.sh` | removes everything |

To use your own `kubectl` as a normal user:

```bash
mkdir -p ~/.kube
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes
```

## Add agents

An agent is a worker node. Give it the server URL and the token:

```bash
# on the server
sudo cat /var/lib/rancher/k3s/server/token

# on each agent
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.37.0+k3s1 \
  K3S_URL=https://server.example.com:6443 K3S_TOKEN=<token> sh -
```

## The config file

Every command-line flag can go in `/etc/rancher/k3s/config.yaml` instead. Write it
**before** the first start: some settings (cluster CIDRs, the datastore) cannot change
after that.

```yaml
# /etc/rancher/k3s/config.yaml
write-kubeconfig-mode: "0640"
tls-san:
  - k3s.example.com
node-label:
  - "site=lab"
disable:
  - traefik
```

Files in `/etc/rancher/k3s/config.yaml.d/*.yaml` are read too, in alphabetical order.
When a key appears in several files, **the last value wins**, lists included. To add to
a list instead of replacing it, end the key with `+`:

```yaml
# /etc/rancher/k3s/config.yaml.d/50-labels.yaml
node-label+:
  - "rack=r12"
```

With the file above, the node has both `site=lab` and `rack=r12`. Without the `+`, it
would have only `rack=r12`.

## Bundled components

After a plain install, `kube-system` contains:

| Component | Shows up as | Replace it with |
| --- | --- | --- |
| Traefik (ingress) | `deployment/traefik` | `disable: [traefik]`, then any controller |
| ServiceLB (LoadBalancer) | `daemonset/svclb-<service>` per LoadBalancer Service | `disable: [servicelb]`, then MetalLB or a cloud provider |
| local-path (storage) | `deployment/local-path-provisioner`, StorageClass `local-path` (default) | `disable: [local-storage]` |
| metrics-server | `deployment/metrics-server` | `disable: [metrics-server]` |
| CoreDNS | `deployment/coredns` | `disable: [coredns]` (rarely a good idea) |
| flannel (CNI) | inside the k3s process, no pod | `flannel-backend: none` |
| NetworkPolicy controller | inside the k3s process, no pod | `disable-network-policy: true` |

ServiceLB has no pool of IP addresses. It opens the Service port **on every node**,
and the external IP of the Service is the node IPs. So two LoadBalancer Services
cannot use the same port. Each node's IP appears when the `svclb` pod on that node
runs, so for a few seconds the list can be shorter than the node list.

To run Cilium instead of flannel and kube-proxy, start k3s with the CNI parts off:

```yaml
flannel-backend: none
disable-network-policy: true
disable-kube-proxy: true
```

Then install Cilium, see [[kubernetes/networking/cilium/install]]. Nodes stay
`NotReady` until a CNI runs.

## Deploy manifests by dropping files

Any manifest in `/var/lib/rancher/k3s/server/manifests/` on a server is applied
automatically, and applied again when the file changes. That is how k3s installs its
own components.

k3s also runs a Helm controller. A `HelmChart` object installs a chart without the
`helm` CLI:

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: podinfo
  namespace: kube-system
spec:
  repo: https://stefanprodan.github.io/podinfo
  chart: podinfo
  version: 6.15.0
  targetNamespace: podinfo
  createNamespace: true
  valuesContent: |-
    replicaCount: 2
```

To change the values of a bundled chart such as Traefik, do not edit its file: k3s
rewrites it. Use a `HelmChartConfig` with the same name instead:

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    accessLog:
      enabled: true
```

> [!warning] Unknown keys are ignored
> Helm does not reject a value the chart does not use. Older Traefik charts used
> `logs.access.enabled`. The chart bundled with k3s 1.37 (Traefik chart 41) reads
> `accessLog.enabled` and ignores the old key without an error. Check the chart's
> `values.yaml` for your k3s version, then check the result:
> `kubectl -n kube-system get deployment traefik -o yaml | grep accesslog`.

## Datastore: SQLite or embedded etcd

A single server stores the cluster state in **SQLite**, through a shim called Kine.
That uses little memory, but you cannot add a second server later.

For high availability, start the **first** server with `cluster-init`. It then runs
embedded etcd. Join the other servers to it. Use an odd number of servers (3 or 5) so
etcd keeps a quorum when one fails.

```bash
# first server
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.37.0+k3s1 sh -s - server --cluster-init

# second and third server
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.37.0+k3s1 K3S_TOKEN=<token> \
  sh -s - server --server https://server1.example.com:6443
```

Put a load balancer or a DNS name in front of the servers, and add it to `tls-san`, so
agents and users do not depend on one server.

### etcd snapshots

With embedded etcd, k3s takes snapshots by itself: every 12 hours, keeping the last 5,
in `/var/lib/rancher/k3s/server/db/snapshots/`. Take one by hand before any risky
change:

```bash
sudo k3s etcd-snapshot save --name before-upgrade
sudo k3s etcd-snapshot ls
```

To restore, stop k3s on **all** servers, then on one server:

```bash
sudo systemctl stop k3s
sudo k3s server --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<file>
sudo systemctl start k3s
```

The other servers must then be wiped (`rm -rf /var/lib/rancher/k3s/server/db`) and
rejoined. SQLite has no snapshot command: back up `/var/lib/rancher/k3s/server/db/`
with k3s stopped.

## Certificates

Certificates are in `/var/lib/rancher/k3s/server/tls/`, not in `/etc/kubernetes/pki`
as on kubeadm clusters. The CAs are `server-ca.crt` (API server), `client-ca.crt`
(client certificates, the one to use in [[kubernetes/security/user-cert]]) and
`request-header-ca.crt`.

The CAs are valid for 10 years. Other certificates are valid for 1 year. k3s renews
them at startup when they expire within 120 days, so a yearly restart (or upgrade) is
enough. The CAs are not renewed. To see the dates, and to force a renewal:

```bash
sudo k3s certificate check --output table
sudo systemctl stop k3s
sudo k3s certificate rotate
sudo systemctl start k3s
```

## Tools built into the binary

```bash
sudo k3s kubectl get pods -A
sudo k3s crictl ps                  # containers, as the kubelet sees them
sudo k3s crictl images
sudo k3s ctr -n k8s.io images ls    # raw containerd view
sudo k3s check-config               # kernel and cgroup requirements
```

## Private registries and mirrors

`/etc/rancher/k3s/registries.yaml` configures containerd on each node. Restart k3s
after a change.

```yaml
mirrors:
  docker.io:
    endpoint:
      - "https://registry-mirror.example.com"
configs:
  "registry.example.com":
    auth:
      username: ci
      password: "<token>"
```

## Upgrades

The simplest way: run the install script again with the new version. It replaces the
binary and restarts the service. Upgrade servers first, one at a time, then agents.
Do not skip minor versions (1.36 → 1.37 → 1.38).

For many clusters, the
[system-upgrade-controller](https://github.com/rancher/system-upgrade-controller)
does the same from inside the cluster, driven by `Plan` objects. It drains, upgrades
and uncordons nodes in order.

## Air-gapped install

1. Download from the k3s release page: the `k3s` binary, the images archive for your
   architecture (`k3s-airgap-images-amd64.tar.zst`), and the `install.sh` script.
2. On the node:

```bash
sudo mkdir -p /var/lib/rancher/k3s/agent/images/
sudo cp k3s-airgap-images-amd64.tar.zst /var/lib/rancher/k3s/agent/images/
sudo install -m 0755 k3s /usr/local/bin/k3s
INSTALL_K3S_SKIP_DOWNLOAD=true ./install.sh
```

k3s imports every archive in the images directory at startup.

## Uninstall

```bash
sudo /usr/local/bin/k3s-uninstall.sh          # server
sudo /usr/local/bin/k3s-agent-uninstall.sh    # agent
```

This removes the service, the binary and `/var/lib/rancher/k3s`. `k3s-killall.sh`
only stops k3s and its containers, and keeps the data.

## k3d: k3s in Docker

[k3d](https://k3d.io) runs k3s nodes as Docker containers, like kind does for kubeadm.
It is the quick way to get a k3s cluster on a laptop or in CI.

```bash
k3d cluster create demo --image rancher/k3s:v1.37.0-k3s1 --agents 2
kubectl get nodes
k3d cluster delete demo
```

The image tag uses `-k3s1` where the k3s version has `+k3s1`: `+` is not allowed in
image tags.

Useful options:

```bash
# publish port 80 of the cluster's load balancer on localhost:8080
k3d cluster create web -p "8080:80@loadbalancer"

# copy a local image into the nodes, like kind load
k3d image import myapp:dev -c demo

# three servers: k3d turns on embedded etcd by itself
k3d cluster create ha --servers 3
```

k3d also starts a small load balancer container (`k3d-<name>-serverlb`) in front of the
servers. That is where `-p ...@loadbalancer` ports go.

> [!warning] `k3d image import` can fail and still say "Successfully imported"
> k3d imports with `ctr image import --all-platforms`. With Docker's containerd image
> store (the default since Docker 29), a *pulled* image keeps its multi-platform index
> but only your platform's layers. The import then fails on the node with
> `content digest ... not found`, and k3d still prints `Successfully imported`.
> Images you built locally import fine. For a pulled image, save one platform first:
>
> ```bash
> docker save --platform linux/amd64 busybox:1.37 -o busybox.tar   # or linux/arm64
> k3d image import busybox.tar -c demo
> ```
>
> Then check that it is there: `docker exec k3d-demo-server-0 crictl images`.

### Disk pressure on a full laptop disk

The kubelet evicts pods and taints the node when the disk is nearly full. Upstream
defaults act at about 10-15% free space. k3s keeps these defaults. kind does not: it
sets every disk threshold to `0%`. So on the same laptop, a kind cluster works and a
k3d cluster schedules nothing:

```text
Warning  FailedScheduling  default-scheduler  0/2 nodes are available: 2 node(s) had untolerated taint(s).
```

Check with `kubectl get nodes -o custom-columns=N:.metadata.name,T:.spec.taints`. If
you see `node.kubernetes.io/disk-pressure`, free some disk, or lower the thresholds
for a throwaway cluster:

```bash
k3d cluster create demo --image rancher/k3s:v1.37.0-k3s1 --agents 1 \
  --k3s-arg '--kubelet-arg=eviction-hard=imagefs.available<1%,nodefs.available<1%@server:*;agent:*'
```

`@server:*;agent:*` passes the flag to every node. Do not do this on a real cluster:
there, eviction is what keeps a full disk from breaking the node.

## kind or k3s?

| | kind | k3s (with k3d locally) |
| --- | --- | --- |
| Built with | kubeadm | its own single binary |
| Looks like | upstream kubeadm: static pods, `/etc/kubernetes/manifests`, `/etc/kubernetes/pki` | k3s layout: `/var/lib/rancher/k3s`, no static pods |
| Included | CNI with NetworkPolicy, local-path storage | also ingress (Traefik), LoadBalancer, metrics-server, Helm controller |
| LoadBalancer / Ingress | add cloud-provider-kind | included |
| Datastore | etcd | SQLite, or embedded etcd |
| Runs on real servers | no, test only | yes, it is a production distribution |
| Best for | testing things that must behave like upstream kubeadm Kubernetes, and the Kubernetes project's own CI | small real clusters, edge, and local clusters where you want ingress and LoadBalancer with no setup |

This site tests its Kubernetes notes on kind, because most of them come from a course
built on kubeadm clusters (see [[kubernetes/cluster-setup/kind-in-practice]]). This
note is tested on k3d.

## See also

- [[kubernetes/cluster-setup/setup-devel]] — other local cluster options
- [[kubernetes/cluster-setup/k0s]] — a similar single-binary distribution
- [[kubernetes/my-notes/vanilla-cluster-lab]] — the same parts, assembled by hand

<!-- uplink -->
Part of [[kubernetes/cluster-setup/index|Cluster setup]].
