---
title: cgroups v2
description: The unified hierarchy — controllers, the interface files that matter, memory and CPU semantics, and what changed from v1
tags: [containers, linux, cgroups, kernel, performance]
type: concept
status: complete
---

# cgroups v2

**Control groups** limit and account for the resources a set of processes may consume:
CPU, memory, I/O, PIDs. They are the half of [[containers/concepts|containerisation]]
that governs *consumption*, as opposed to namespaces which govern *visibility*.

Version 2 replaced v1's independent per-controller hierarchies with a single unified
tree. It is the default on every current distribution, and the only one systemd
supports fully.

## The unified hierarchy

```bash
mount | grep cgroup2
# cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime)
```

One tree, mounted at `/sys/fs/cgroup`. A process belongs to exactly **one** cgroup,
and every enabled controller applies to it there.

```bash
cat /proc/self/cgroup
# 0::/user.slice/user-1000.slice/session-3.scope
```

The single `0::` line is the giveaway that you are on v2 — v1 printed one line per
controller.

> [!important] "One process, one cgroup" is the whole design change
> Under v1 a process could sit at `/cpu/foo` and `/memory/bar` simultaneously, with
> the hierarchies unrelated. That made it impossible to reason about a group's total
> resource picture, and made delegation to unprivileged users unsafe. v2 trades
> flexibility for coherence, which is what enables rootless containers.

## Controllers

```bash
cat /sys/fs/cgroup/cgroup.controllers
# cpuset cpu io memory hugetlb pids rdma misc
```

A child only gets a controller if its parent enables it:

```bash
cat /sys/fs/cgroup/mygroup/cgroup.subtree_control
echo "+cpu +memory" > /sys/fs/cgroup/mygroup/cgroup.subtree_control
```

### The no-internal-process rule

A cgroup with children may not itself contain processes, except at the root. Attempts
fail with `EBUSY`, which surprises people migrating from v1. Processes live at the
leaves.

## Creating one by hand

Directories are the API:

```bash
sudo mkdir /sys/fs/cgroup/demo
echo "+cpu +memory +pids" | sudo tee /sys/fs/cgroup/cgroup.subtree_control

echo "100M" | sudo tee /sys/fs/cgroup/demo/memory.max
echo "50"   | sudo tee /sys/fs/cgroup/demo/pids.max

echo $$ | sudo tee /sys/fs/cgroup/demo/cgroup.procs   # move this shell in
```

Then watch it:

```bash
cat /sys/fs/cgroup/demo/memory.current
cat /sys/fs/cgroup/demo/memory.events
```

Remove it with `rmdir` once empty.

## Memory

| File | Meaning |
| --- | --- |
| `memory.max` | Hard limit. Exceeding it triggers the OOM killer **within the cgroup** |
| `memory.high` | Soft limit. The kernel throttles reclaim aggressively above it, but does not kill |
| `memory.low` | Reclaim protection — memory below this is reclaimed only under pressure |
| `memory.min` | Hard protection; never reclaimed |
| `memory.current` | Current usage |
| `memory.events` | Counters, including `oom_kill` |
| `memory.pressure` | PSI — how much time is lost stalling on memory |

> [!tip] `memory.high` is the v2 feature worth knowing about
> `memory.max` is a cliff: one byte over and something is killed. `memory.high`
> applies backpressure instead — the workload is slowed and reclaimed from, but stays
> alive. Setting `high` slightly below `max` turns a hard OOM kill into a degradation
> you can alert on, which is usually what you actually want in production.
>
> Kubernetes memory limits map to `memory.max`, so a container at its limit is killed
> rather than throttled. That asymmetry with CPU throttling catches everyone once.

**Pressure stall information** is the other v2 addition worth using:

```bash
cat /sys/fs/cgroup/demo/memory.pressure
# some avg10=0.00 avg60=0.00 avg300=0.00 total=0
# full avg10=0.00 avg60=0.00 avg300=0.00 total=0
```

`some` is time where at least one task stalled; `full` is time where everything did.
It is a far better saturation signal than a usage percentage.

## CPU

| File | Meaning |
| --- | --- |
| `cpu.max` | `$QUOTA $PERIOD` in microseconds. `50000 100000` is half a core |
| `cpu.weight` | Relative share under contention, 1–10000, default 100 |
| `cpu.stat` | Usage, and crucially `nr_throttled` / `throttled_usec` |
| `cpu.pressure` | PSI for CPU |

```bash
echo "50000 100000" | sudo tee /sys/fs/cgroup/demo/cpu.max   # 0.5 CPU
echo "max 100000"   | sudo tee /sys/fs/cgroup/demo/cpu.max   # unlimited
```

> [!warning] CPU limits throttle, and throttling looks like a slow application
> A container at its CPU limit is not killed — it is stopped until the next period.
> With the default 100 ms period, a latency-sensitive service can pause for tens of
> milliseconds at a time while showing CPU usage comfortably below the limit on a
> one-minute average.
>
> `cpu.stat`'s `nr_throttled` is the number to watch, and it is the first thing to
> check when a service is inexplicably slow but not busy:
>
> ```bash
> grep -E 'nr_throttled|throttled_usec' /sys/fs/cgroup/demo/cpu.stat
> ```

## PIDs and I/O

```bash
echo 100 > /sys/fs/cgroup/demo/pids.max        # fork bomb defence
cat /sys/fs/cgroup/demo/pids.current
```

```bash
# major:minor rbps wbps riops wiops
echo "8:0 rbps=1048576 wbps=1048576" > /sys/fs/cgroup/demo/io.max
cat /sys/fs/cgroup/demo/io.stat
```

`io.max` is a hard throttle; `io.weight` gives proportional shares, and — unlike v1 —
works with the default block scheduler.

## systemd is the real interface

On any systemd host, **systemd owns the cgroup tree**. Writing to `/sys/fs/cgroup`
directly for a managed service works until systemd next reloads and reverts it.

```bash
systemd-cgls                    # the tree, as systemd sees it
systemd-cgtop                   # top, per cgroup
systemctl set-property myservice.service MemoryMax=2G CPUQuota=50%
```

Or in a unit file:

```ini
[Service]
MemoryHigh=1800M
MemoryMax=2G
CPUQuota=50%
TasksMax=100
IOWeight=50
```

See systemd. These map directly onto the interface files above.

## What changed from v1

| | v1 | v2 |
| --- | --- | --- |
| Hierarchy | One per controller | Single unified tree |
| Process membership | One cgroup per controller | Exactly one cgroup |
| Delegation | Unsafe | Safe, via `cgroup.subtree_control` |
| Memory accounting | Separate memory and memsw | Unified, with swap accounted separately |
| Soft limits | `soft_limit_in_bytes`, advisory and vague | `memory.high`, actually enforced |
| Pressure metrics | None | PSI on cpu, memory and io |
| rootless containers | Not practical | Supported, through delegation |

Check which you are on:

```bash
stat -fc %T /sys/fs/cgroup/
# cgroup2fs → v2 ;  tmpfs → v1
```

## Delegation, and why rootless works

Safe delegation is what lets an unprivileged user manage a subtree:

```ini
# ~/.config/systemd/user/... or via systemd-run --user
Delegate=yes
```

systemd creates a per-user slice with the controllers delegated, so
[[containers/podman|rootless Podman]] can set limits on its containers without root.
Under v1 there was no way to do this without handing over more than you wanted.

## How Kubernetes lays out the tree

On a node, the kubelet creates a slice hierarchy that mirrors pod QoS classes:

```text
/sys/fs/cgroup/
└── kubepods.slice/
    ├── kubepods-pod<uid>.slice/          ← Guaranteed
    │   └── cri-containerd-<id>.scope
    ├── kubepods-burstable.slice/
    │   └── kubepods-burstable-pod<uid>.slice/
    └── kubepods-besteffort.slice/
```

| QoS class | Requests and limits | Result in the tree |
| --- | --- | --- |
| **Guaranteed** | Equal | `cpu.max` and `memory.max` set; lowest OOM score |
| **Burstable** | Requests < limits | Proportional `cpu.weight`; intermediate OOM score |
| **BestEffort** | Neither | No limits; killed first under pressure |

```bash
systemd-cgls /kubepods.slice | head -30
cat /sys/fs/cgroup/kubepods.slice/.../memory.max
```

This is why the cgroup driver must match between the kubelet and the runtime — both
write into this tree, and disagreement means two managers fighting over it. See
[[containers/containerd/basics]].

> [!note] cgroups v1 is on its way out
> openSUSE Leap 16 supports **only** v2 — there is no v1 fallback — and v2 is the
> default on Fedora 31+, RHEL 9+ and the managed Kubernetes offerings. The v1
> interface is deprecated in Kubernetes 1.35. New kernel
> features target v2 only, so a host still on v1 is accumulating a migration.

## Where to go next

- [[containers/concepts]] — the other mechanisms a container is made of
- [[containers/security]] — resource limits as a denial-of-service control
- [[kubernetes/observability/resource-limits]] — requests and limits, which compile down to these files
- disk-io-performance — reading `io.pressure` alongside the rest
- systemd — the manager that owns the tree

## Sources

- [Rawkode Academy — cgroups: from chaos to control](https://rawkode.academy/read/cgroups-from-chaos-to-control)
  — the v1/v2 comparison and the Kubernetes slice layout above follow this article

<!-- uplink -->
Part of [[containers/index|Containers]].
