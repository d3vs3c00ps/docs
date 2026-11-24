---
title: KubeVirt troubleshooting
description: VMIs stuck pending, DataVolume imports that never finish, migration failures, console access problems, and where the logs actually are
tags: [virtualization, kubevirt, kubernetes, troubleshooting]
type: reference
status: complete
---

# KubeVirt troubleshooting

> [!note] Partly tested
> No test cluster runs KubeVirt: the test Mac has no KVM, and KubeVirt on arm64
> cannot use software emulation. The tests check the release URLs, validate every
> manifest against KubeVirt's API schema, and run `virtctl` and the `jq` commands
> offline. How a running cluster behaves is not tested.

## Where to look

A KubeVirt problem is a Kubernetes problem, a libvirt problem, or a guest problem, and
the first job is deciding which.

```bash
kubectl get vm,vmi,dv,pvc
kubectl describe vmi <name>
kubectl get pods -l kubevirt.io=virt-launcher

# libvirt and QEMU, inside the launcher pod
kubectl logs virt-launcher-<name>-xxxxx -c compute
kubectl logs -n kubevirt -l kubevirt.io=virt-handler --tail=100
```

`kubectl describe vmi` is the highest-yield command — its conditions and events name
the cause most of the time.

## VMI stuck in `Scheduling` or `Pending`

The launcher pod cannot be scheduled. This is ordinary Kubernetes scheduling, so
diagnose it as such:

```bash
kubectl get pods -l kubevirt.io=virt-launcher
kubectl describe pod virt-launcher-<name>-xxxxx | tail -20
```

| Event | Cause |
| --- | --- |
| `Insufficient devices.kubevirt.io/kvm` | The node has no `/dev/kvm` — virtualisation disabled, or nesting not enabled |
| `Insufficient memory` | The VM requests more than any node can offer. A VM requests its full guest memory plus overhead. Only `memoryOvercommit` in the `KubeVirt` resource lowers that |
| `pod has unbound immediate PersistentVolumeClaims` | The DataVolume has not finished importing |
| `node(s) didn't match Pod's node affinity` | An instance type or preference pinned it somewhere impossible |

Confirm KVM is advertised at all:

```bash
kubectl get nodes -o json | jq '.items[] | {name:.metadata.name, kvm:.status.allocatable["devices.kubevirt.io/kvm"]}'
```

A `null` or `0` here means the node cannot run VMs, and everything else is downstream
of that. See [[virtualization/kubevirt/introduction]].

## DataVolume never completes

```bash
kubectl get dv
kubectl describe dv <name>
kubectl get pods -l app=containerized-data-importer
kubectl logs importer-<dv-name>          # the importer pod itself
```

The importer pod is `importer-<dv-name>`, or `importer-prime-<uid>` when CDI fills the
disk through a volume populator. The label finds it in both cases.

| Phase | Meaning |
| --- | --- |
| `Pending` | No PVC bound — check the StorageClass exists and can provision |
| `WaitForFirstConsumer` | The StorageClass binds on first use. Normal: the import starts when the VM starts |
| `ImportScheduled` | Waiting for the importer pod |
| `ImportInProgress` | Downloading. Large qcow2 files take a while |
| `Failed` | The importer log has the reason |

Common causes: a URL that needs authentication, a certificate the importer does not
trust, insufficient PVC size for the **uncompressed** image, or no egress from the
cluster.

> [!warning] Size the PVC for the uncompressed image plus overhead
> A 2 GB compressed cloud image can expand to 10 GB or more. CDI needs room for the
> expanded image *and* filesystem overhead, and the failure — an importer that gets
> most of the way through and then dies — looks like a network problem rather than a
> disk-space one. CDI's `filesystemOverhead` setting defaults to 6% since CDI v1.64
> (5.5% before).

## VMI `Running` but unreachable

```bash
kubectl get vmi <name> -o jsonpath='{.status.interfaces}' | jq
virtctl console <name>
```

Work outward:

1. **Did the guest get an address?** With `masquerade`, the VM should DHCP an address
   on 10.0.2.0/24 internally and be reachable on the pod IP. No address means
   cloud-init or the guest's network configuration.
2. **Is the Service selector right?** It must match the **VMI** labels, which come
   from `spec.template.metadata.labels` — not the `VirtualMachine`'s own labels. This
   is the most common Service mistake with KubeVirt.
3. **NetworkPolicy.** A default-deny namespace blocks VM traffic exactly as it blocks
   pod traffic. See [[kubernetes/networking/netpol]].

```yaml
  template:
    metadata:
      labels:
        kubevirt.io/domain: web-01    # ← this is what a Service selects on
```

## Live migration fails or never completes

```bash
kubectl get vmim
kubectl describe vmim <name>
kubectl get vmi <name> -o jsonpath='{.status.migrationState}' | jq
```

| Symptom | Cause |
| --- | --- |
| `Cannot migrate VMI, Reason: InterfaceNotLiveMigratable` | `bridge` binding on the pod network |
| `Cannot migrate VMI, Reason: DisksNotLiveMigratable` | A `ReadWriteOnce` PVC: "live migration requires that all PVCs must be shared" |
| `Cannot migrate VMI, Reason: HostDeviceNotLiveMigratable` | A passed-through device |
| Starts, never completes | The guest dirties memory faster than it copies. Enable `allowAutoConverge` |
| CPU model incompatible | `host-passthrough` and non-identical nodes |

KubeVirt refuses a migration it knows cannot work, when you create it. The VMI's
`LiveMigratable` condition says so in advance, with the reason:

```bash
kubectl get vmi <name> -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")]}' | jq
```

> [!note] Refused at once
> With `ReadWriteOnce` storage, KubeVirt refuses the migration at once, with
> `Cannot migrate VMI, Reason: DisksNotLiveMigratable`. It does not stay pending.

See [[virtualization/kubevirt/advanced]] for each of these.

```bash
kubectl get vmi <name> -o jsonpath='{.status.migrationMethod}'
# BlockMigration means storage is NOT shared — much slower, and often the real problem
```

## `virtctl console` hangs

The connection is fine; the guest is not writing to the serial console.

```bash
virtctl console <name>          # Ctrl+] to escape
virtctl vnc <name>              # try the graphical console instead
```

If VNC shows a working login prompt, the guest has no serial getty:

```bash
sudo systemctl enable --now serial-getty@ttyS0.service
```

Add `console=ttyS0` to the guest's kernel command line in the golden image — see
[[virtualization/kvm/usage]]. It is worth doing once, centrally.

## The VM restarts unexpectedly

```bash
kubectl get vmi <name> -o jsonpath='{.status.phase}'
kubectl describe vmi <name> | grep -A20 Events
kubectl get events --field-selector involvedObject.name=<name>
```

Causes worth checking, in order:

- **OOM kill.** The launcher pod exceeded its memory limit. A VM needs its guest
  memory **plus** the overhead of QEMU and libvirt. KubeVirt estimates that overhead and
  adds it to the pod's request and limit, unless the VM sets
  `resources.overcommitGuestOverhead: true`. OOM kills come from that setting, or from
  an estimate that is too low for the workload (many disks, heavy I/O).
- **Node drain without `evictionStrategy: LiveMigrate`**, so it was shut down rather
  than migrated.
- **Argo CD undoing a power change.** With `runStrategy: Always` in Git and self-heal
  on, a `virtctl stop` is reverted and the VM starts again. See
  [[virtualization/kubevirt/gitops]].
- **Liveness probe** on the VMI failing.

> [!note] The overhead is added for you
> KubeVirt adds its QEMU overhead estimate to the pod. You do not need to add it
> yourself.

## Guest agent not connected

```bash
kubectl get vmi <name> -o jsonpath='{.status.conditions}' | jq
# look for AgentConnected
```

Without it you lose reported IP addresses, filesystem freeze for consistent snapshots,
graceful shutdown, and SSH key propagation. Install it in every golden image:

```bash
sudo dnf install -y qemu-guest-agent && sudo systemctl enable --now qemu-guest-agent
# Debian, Ubuntu: sudo apt install qemu-guest-agent
```

## Nothing works after installing

```bash
kubectl get kubevirt -n kubevirt -o jsonpath='{.items[0].status}' | jq
kubectl get pods -n kubevirt
```

All of `virt-api`, `virt-controller`, `virt-handler` and `virt-operator` should be
running. `virt-handler` is a DaemonSet — it must be on every node intended to run VMs,
and a node where it is missing or crash-looping simply never gets VMs scheduled.

## Health check

```bash
#!/bin/bash
echo "== operator ==";  kubectl get pods -n kubevirt --no-headers | grep -v Running || echo "all running"
echo "== kvm nodes =="
kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name): \(.status.allocatable["devices.kubevirt.io/kvm"] // "NONE")"'
echo "== vms ==";       kubectl get vm,vmi -A --no-headers | head -20
echo "== dvs ==";       kubectl get dv -A --no-headers | grep -v Succeeded || echo "all imported"
echo "== migrations =="; kubectl get vmim -A --no-headers | grep -v Succeeded || echo "none pending"
```

## Where to go next

- [[virtualization/kubevirt/basics]] — the configuration behind most of these
- [[virtualization/kubevirt/advanced]] — storage and migration requirements
- [[virtualization/kvm/troubleshooting]] — the hypervisor layer underneath

<!-- uplink -->
Part of [[virtualization/kubevirt/index|KubeVirt]].
