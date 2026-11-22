---
title: containerd command line tools
description: ctr, crictl and nerdctl — which to reach for, the namespace flag everyone forgets, and the commands worth knowing on a node
tags: [containers, containerd, cli, kubernetes, troubleshooting]
type: reference
status: complete
---

# containerd command line tools

Three CLIs, doing three different jobs. Picking the wrong one is why containerd feels
awkward at first.

| Tool | Ships with | Use it for |
| --- | --- | --- |
| **`ctr`** | containerd itself | Low-level debugging. Unstable interface, no compatibility promise |
| **`crictl`** | cri-tools | Anything Kubernetes-related on a node. Speaks the CRI |
| **`nerdctl`** | separate | A Docker-compatible experience — `nerdctl run` behaves like `docker run` |

The short version: **`crictl` on a Kubernetes node, `nerdctl` for day-to-day work,
`ctr` when the other two cannot see what you need.**

## The namespace flag

Every `ctr` command operates in a containerd namespace, and the default is `default`
— which is not where anything you care about lives.

```bash
ctr namespaces list
sudo ctr --namespace k8s.io containers list     # Kubernetes
sudo ctr --namespace moby containers list       # Docker
```

```bash
export CONTAINERD_NAMESPACE=k8s.io
```

`crictl` needs no such flag — it always uses `k8s.io`, because that is what the CRI
means.

## crictl

The tool for a Kubernetes node. It shows exactly what the kubelet sees.

```bash
crictl ps                     # running containers
crictl ps -a                  # including exited
crictl pods                   # pod sandboxes
crictl images                 # images
crictl logs <container-id>
crictl logs -f --tail=100 <container-id>
crictl exec -it <container-id> sh
crictl inspect <container-id>
crictl stats
```

Pulling and cleaning up:

```bash
crictl pull registry.k8s.io/pause:3.9
crictl rmi --prune            # remove unused images
```

Configuration, if it cannot find the socket:

```yaml
# /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
```

> [!tip] `crictl ps` when `kubectl` cannot help
> When the API server is unreachable, or a pod is stuck in `ContainerCreating` with an
> unhelpful event, `crictl` on the node is the ground truth. `crictl pods` shows
> whether the sandbox was even created — which distinguishes a CNI problem from an
> image pull problem immediately.

> [!warning] `crictl rm` on a Kubernetes container achieves nothing lasting
> The kubelet's job is to make reality match the pod spec, so a container you remove
> is recreated within seconds. Use `kubectl delete pod` to make a change stick;
> `crictl` is for observing, not for repairing.

## nerdctl

Docker-compatible, and the pleasant one to use:

```bash
nerdctl run -d --name web -p 8080:80 nginx:alpine
nerdctl ps
nerdctl logs -f web
nerdctl exec -it web sh
nerdctl images
nerdctl build -t myapp:1.0 .
nerdctl compose up -d
```

It also exposes things Docker cannot, because containerd supports them:

```bash
nerdctl run --snapshotter stargz ...        # lazy-pulling snapshotter
nerdctl image encrypt ...                   # encrypted images
nerdctl run --isolation ...                 # alternative runtimes
```

Namespaces work the same way:

```bash
sudo nerdctl --namespace k8s.io ps
```

## ctr

Low-level, unstable, and occasionally the only thing that will do.

```bash
sudo ctr images list
sudo ctr images pull docker.io/library/alpine:latest
sudo ctr images import alpine.tar
sudo ctr images export alpine.tar docker.io/library/alpine:latest
sudo ctr images remove docker.io/library/alpine:latest

sudo ctr containers list
sudo ctr tasks list                    # tasks are the running processes
sudo ctr run --rm -t docker.io/library/alpine:latest tmp sh
sudo ctr tasks exec --exec-id dbg -t <container-id> sh
sudo ctr tasks kill <container-id>

sudo ctr snapshots list
sudo ctr snapshots usage               # where the disk went
sudo ctr content list
sudo ctr plugins list                  # which plugins loaded, and which failed
```

> [!note] `ctr` distinguishes containers from tasks
> A **container** in containerd is metadata — the spec, the snapshot, the config. A
> **task** is the running process. `ctr containers list` can show entries with no
> corresponding task, which is a container that exists but is not running. Docker and
> Kubernetes hide this distinction; containerd does not.

`ctr plugins list` is genuinely useful when something is inexplicably missing: a CRI
plugin in `error` state explains a node the kubelet cannot use, and the error text is
usually specific.

## Importing images without a registry

For air-gapped nodes:

```bash
docker save myapp:1.0 -o myapp.tar
sudo ctr --namespace k8s.io images import myapp.tar
sudo crictl images | grep myapp
```

The namespace matters: importing into `default` leaves Kubernetes unable to see it,
which produces `ErrImageNeverPull` on a node where the image is demonstrably present.

## Quick comparison

| Task | crictl | nerdctl | ctr |
| --- | --- | --- | --- |
| List running containers | `crictl ps` | `nerdctl ps` | `ctr tasks list` |
| Logs | `crictl logs` | `nerdctl logs` | not really |
| Exec | `crictl exec` | `nerdctl exec` | `ctr tasks exec` |
| Pull | `crictl pull` | `nerdctl pull` | `ctr images pull` |
| Build | no | `nerdctl build` | no |
| Compose | no | `nerdctl compose` | no |
| Prune images | `crictl rmi --prune` | `nerdctl image prune` | manual |

## Where to go next

- [[containers/containerd/troubleshooting]] — using these to diagnose a node
- [[containers/containerd/basics]] — configuration behind them
- [[kubernetes/tooling/k9s]] — the layer above, when the cluster is healthy

<!-- uplink -->
Part of [[containers/containerd/index|containerd]].
