---
title: containerd troubleshooting
description: Disk filling up, image pull failures, pods stuck in ContainerCreating, cgroup driver mismatches, and reading containerd's logs
tags: [containers, containerd, troubleshooting, kubernetes]
type: reference
status: complete
---

# containerd troubleshooting

## Start here

```bash
systemctl status containerd
journalctl -u containerd -n 200 --no-pager
ctr plugins list | grep -v ok        # anything not "ok" is your answer
crictl info | jq '.status'
```

`ctr plugins list` is the highest-yield first command. A plugin in `error` state
explains an entire category of failure, and its message is usually specific.

## `/var/lib/containerd` filling the disk

The most common containerd operational problem, and it presents as node
`DiskPressure` with pods being evicted.

```bash
du -sh /var/lib/containerd/*
sudo ctr --namespace k8s.io snapshots usage
crictl images
```

Reclaim:

```bash
crictl rmi --prune                    # unused images
crictl rm $(crictl ps -a -q --state exited)
```

```toml
[plugins."io.containerd.grpc.v1.cri".containerd]
  discard_unpacked_layers = true
```

> [!important] The kubelet's garbage collection is the real fix
> Manual pruning is firefighting. The kubelet removes unused images automatically at
> `imageGCHighThresholdPercent` (default 85% of the filesystem) down to
> `imageGCLowThresholdPercent` (80%). A node repeatedly filling up usually has an
> image filesystem too small for its workload churn, or GC thresholds that leave too
> little headroom for a large image pull to complete.
>
> Note also that GC only removes images **no container references**. A node running
> many short-lived jobs from many distinct images fills faster than GC can help.

## Image pull failures

```bash
crictl pull registry.example.com/myapp:1.0
journalctl -u containerd -f | grep -i pull
```

| Symptom | Cause |
| --- | --- |
| `x509: certificate signed by unknown authority` | Registry CA not trusted. Add it in `/etc/containerd/certs.d/<registry>/hosts.toml` |
| `401 Unauthorized` | Missing or wrong `imagePullSecret`; for `ctr`, no `--user` |
| `no such host` | DNS from the node, not from a pod. Test with `getent hosts` |
| Mirror ignored entirely | `config_path` set *and* inline `registry.mirrors` present — see [[containers/containerd/advanced]] |
| `ErrImageNeverPull` with the image clearly present | Imported into the wrong containerd namespace |

That last one is worth the reminder:

```bash
sudo ctr --namespace k8s.io images import myapp.tar     # not "default"
```

## Pod stuck in `ContainerCreating`

Work out which half is failing — sandbox creation, or the container itself:

```bash
crictl pods                       # is the sandbox even there?
crictl ps -a
kubectl describe pod <pod>        # events are usually explicit
journalctl -u containerd -f
journalctl -u kubelet -f
```

- **No sandbox** — the pause image cannot be pulled, or CNI failed. Check
  `/etc/cni/net.d/` exists and contains a config, and that the CNI binaries are in
  `/opt/cni/bin`.
- **Sandbox but no container** — an image pull or a mount problem. A missing
  ConfigMap, Secret or PVC shows up here.

```bash
ls /etc/cni/net.d/ /opt/cni/bin/
```

> [!tip] An empty `/etc/cni/net.d/` is a whole class of outage
> containerd reports the node as not ready with `cni plugin not initialized`, and
> every pod hangs creating its sandbox. It happens when the CNI DaemonSet has not run
> yet — a chicken-and-egg on a fresh cluster — or when someone cleaned the directory.
> Host-network pods keep working throughout, which makes the diagnosis confusing.

## Cgroup driver mismatch

```bash
grep SystemdCgroup /etc/containerd/config.toml
grep cgroupDriver /var/lib/kubelet/config.yaml
stat -fc %T /sys/fs/cgroup/            # cgroup2fs on a modern host
```

Both must say systemd. See [[containers/containerd/basics]] — the symptoms are
restarts under load and limits that are not honoured, never a message naming the
cause.

## Containers survive a containerd restart — until they do not

Restarting containerd leaves running containers alone, because each is parented to its
own shim. But:

```bash
ps aux | grep containerd-shim
```

Orphaned shims — whose container exited but whose shim remained — leak memory and
eventually PIDs. They usually indicate a runtime crash. Check for the container in
`crictl ps -a` first; if it is genuinely gone, the shim can be killed.

## `failed to create shim` / `OCI runtime create failed`

The generic wrapper around a `runc` failure. The useful text is further in:

```bash
journalctl -u containerd -n 100 | grep -A5 'failed to create'
```

Common underlying causes: no space left, a bad `runtimeClassName` referring to a
runtime not configured on that node, an unwritable `/run`, or seccomp/AppArmor
refusing the container.

## Node reports the wrong resource usage

PSI and cgroup stats come from the tree containerd writes into. If the driver is
mismatched, or `/sys/fs/cgroup` is mounted oddly in a nested environment such as
kind or Docker-in-Docker, statistics are wrong even though containers run.

```bash
cat /sys/fs/cgroup/cgroup.controllers
systemd-cgls | head -30
```

See [[containers/cgroups-v2]].

## Verbose logging

```toml
[debug]
  level = "debug"
  address = "/run/containerd/debug.sock"
```

```bash
sudo systemctl restart containerd
journalctl -u containerd -f
```

Debug level is extremely noisy on a busy node — turn it on for a reproduction and off
again afterwards.

## A quick node health script

```bash
#!/bin/bash
echo "== service ==";     systemctl is-active containerd
echo "== plugins ==";     ctr plugins list | grep -v ' ok ' || echo "all ok"
echo "== disk ==";        df -h /var/lib/containerd | tail -1
echo "== cgroup ==";      stat -fc %T /sys/fs/cgroup/
echo "== cni ==";         ls /etc/cni/net.d/ 2>/dev/null || echo "MISSING"
echo "== sandboxes ==";   crictl pods 2>/dev/null | wc -l
echo "== recent errors =="; journalctl -u containerd -p err -n 20 --no-pager
```

## Where to go next

- [[containers/containerd/cli]] — the commands used above
- [[containers/containerd/basics]] — configuration and state layout
- [[containers/containerd/advanced]] — registries, snapshotters, runtime classes
- [[kubernetes/observability/logs-cli]] — the layer above, when the node is healthy

<!-- uplink -->
Part of [[containers/containerd/index|containerd]].
