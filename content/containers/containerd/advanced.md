---
title: containerd advanced configuration
description: Snapshotters, registry mirrors and authentication, runtime classes for gVisor and Kata, lazy pulling, and plugin architecture
tags: [containers, containerd, configuration, kubernetes]
type: reference
status: complete
---

# containerd advanced configuration

## Snapshotters

The snapshotter provides the layered filesystem described in
[[containers/concepts]]. containerd supports several, and the choice has real
performance consequences.

```bash
ctr plugins list | grep snapshot
```

| Snapshotter | Notes |
| --- | --- |
| **overlayfs** | The default. Fast, well understood, works everywhere |
| **native** | Full copy per layer. Slow and space-hungry; a fallback |
| **btrfs** / **zfs** | Uses filesystem-native snapshots. Efficient if you already run them |
| **devmapper** | Block-level, with real per-container quotas |
| **stargz** | **Lazy pulling** — start before the image is fully downloaded |
| **nydus** | Similar goal, different format; strong in large-scale deployments |

```toml
[plugins."io.containerd.grpc.v1.cri".containerd]
  snapshotter = "overlayfs"
```

> [!tip] Lazy-pulling snapshotters attack real startup latency
> Most container start time on a large image is spent downloading layers that are
> never read. `stargz` and `nydus` make images seekable, so a container starts once
> the metadata has arrived and fetches file content on demand. For a 2 GB image where
> the process touches 50 MB, the difference is dramatic.
>
> The cost is that images must be converted to the format, and a registry that
> supports range requests. Worth it for large images and autoscaling; unnecessary for
> a small distroless binary — which is a good argument for
> small images in the first place.

## Registry configuration

The modern layout uses a directory of hosts files rather than inline TOML:

```toml
[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
```

### A pull-through mirror

```toml
# /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://registry-1.docker.io"

[host."https://mirror.example.com/v2"]
  capabilities = ["pull", "resolve"]
  skip_verify = false
```

Requests try the mirror first and fall back to `server`. Omitting `server` makes the
mirror the only option, which is what you want in an air-gapped environment.

### A private registry with a custom CA

```toml
# /etc/containerd/certs.d/registry.example.com/hosts.toml
server = "https://registry.example.com"

[host."https://registry.example.com"]
  capabilities = ["pull", "resolve", "push"]
  ca = "/etc/containerd/certs.d/registry.example.com/ca.crt"
```

See certificate-generation for producing that CA.

### Authentication

containerd itself does not manage credentials for the CRI path — the kubelet passes
them from `imagePullSecrets`. For `ctr` and `nerdctl`:

```bash
sudo ctr images pull --user myuser:mytoken registry.example.com/myapp:1.0
nerdctl login registry.example.com
```

> [!warning] `config_path` and inline `[registry.mirrors]` are mutually exclusive
> Setting `config_path` makes containerd **ignore** any inline `registry.mirrors` and
> `registry.configs` blocks entirely — silently. A mirror configuration that appears
> to be ignored is almost always this. Pick the hosts-file layout; the inline form is
> deprecated.

## Runtime classes

containerd can drive several low-level runtimes, selected per workload:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    SystemdCgroup = true

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor]
  runtime_type = "io.containerd.runsc.v1"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
  runtime_type = "io.containerd.kata.v2"
```

Then expose them to Kubernetes:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: gvisor
---
apiVersion: v1
kind: Pod
metadata:
  name: untrusted-workload
spec:
  runtimeClassName: gvisor
  containers:
    - name: app
      image: myapp:1.0
```

> [!important] This is the answer to the shared-kernel problem
> [[containers/concepts]] notes that the kernel is the boundary, and that a kernel
> vulnerability reachable from an unprivileged process is an escape. Runtime classes
> are how you apply a stronger boundary **selectively** — untrusted or multi-tenant
> workloads on gVisor or Kata, everything else on runc, on the same nodes.
>
> gVisor intercepts syscalls in userspace, at some performance cost and with
> incomplete syscall coverage. Kata gives each pod a lightweight VM — a genuine
> hypervisor boundary, at the cost of memory per pod and slower starts. Test your
> workload; gVisor in particular breaks things that use unusual syscalls.

## crun instead of runc

A C implementation, faster to start and lighter on memory:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.crun]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.crun.options]
    BinaryName = "/usr/bin/crun"
    SystemdCgroup = true
```

It is the default on recent Fedora and RHEL. Drop-in compatible in practice.

## Image decryption and signing

containerd supports encrypted images through the `imgcrypt` plugin, and signature
verification is normally done at admission rather than in the runtime — see
cosign and [[kubernetes/security/kyverno]].

## Plugins

Everything above is a plugin, and the plugin list is the fastest diagnostic:

```bash
ctr plugins list
ctr plugins list --detailed
```

A plugin in `error` state explains an entire class of failure — a CRI plugin that
failed to load means the kubelet cannot use the node at all, and the error string is
usually precise about why.

## Tuning worth knowing

```toml
[plugins."io.containerd.grpc.v1.cri"]
  max_concurrent_downloads = 3        # raise on fast links, lower on slow ones
  disable_apparmor = false
  restrict_oom_score_adj = false

[plugins."io.containerd.grpc.v1.cri".containerd]
  discard_unpacked_layers = true      # reclaims significant disk
```

`discard_unpacked_layers` deletes compressed layer blobs once unpacked. It saves
roughly the compressed size of every image on the node, at the cost of being unable to
push those images back out — which on a Kubernetes node you would never do anyway.

## Where to go next

- [[containers/containerd/hardening]] — the security configuration
- [[containers/containerd/troubleshooting]] — when a plugin or mirror misbehaves
- [[containers/concepts]] — what the runtimes above are actually doing

<!-- uplink -->
Part of [[containers/containerd/index|containerd]].
