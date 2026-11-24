---
title: KubeVirt storage, networking and migration
description: Choosing storage that can migrate, the four network binding modes, multus and SR-IOV, live migration requirements, and hotplug
tags: [virtualization, kubevirt, kubernetes, storage, networking]
type: reference
status: complete
---

# KubeVirt storage, networking and migration

> [!note] Partly tested
> No test cluster runs KubeVirt: the test Mac has no KVM, and KubeVirt on arm64
> cannot use software emulation. The tests check the release URLs, validate every
> manifest against KubeVirt's API schema, and run `virtctl` and the `jq` commands
> offline. How a running cluster behaves is not tested.

## Storage

The choice that constrains everything else. Get it wrong and live migration is
impossible without rebuilding.

| Requirement | Why |
| --- | --- |
| `ReadWriteMany` | Live migration attaches the volume on the destination while the source still holds it |
| `volumeMode: Block` | No filesystem between QEMU and the disk. Faster, and better supported by CSI drivers for VMs |
| Snapshot support | For `VirtualMachineSnapshot`: a CSI driver with `VolumeSnapshot` support |

```yaml
spec:
  dataVolumeTemplates:
    - metadata:
        name: db-01-root
      spec:
        storage:
          accessModes: [ReadWriteMany]
          volumeMode: Block
          resources:
            requests:
              storage: 50Gi
          storageClassName: ceph-rbd
```

Common backends: Ceph RBD via Rook, Portworx, LINSTOR, or an enterprise CSI driver.
For a lab, [hostpath-provisioner](https://github.com/kubevirt/hostpath-provisioner)
works but is `ReadWriteOnce` — so no migration.

> [!warning] `ReadWriteOnce` is the default, and it is a dead end
> Most StorageClasses default to `ReadWriteOnce` with `volumeMode: Filesystem`. VMs on
> them run fine, so the problem is invisible until the first node drain — at which
> point every VM must be shut down rather than migrated, and changing storage mode
> after the fact means copying every disk.
>
> Decide this before the first production VM. See [[kubernetes/storage/pv-pvc-sc]].

### Snapshots

```yaml
apiVersion: snapshot.kubevirt.io/v1beta1
kind: VirtualMachineSnapshot
metadata:
  name: db-01-before-upgrade
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: db-01
```

```bash
kubectl get vmsnapshot
kubectl apply -f restore.yaml    # VirtualMachineRestore
```

`restore.yaml` names the snapshot and the VM to restore into. Stop the VM first:

```yaml
apiVersion: snapshot.kubevirt.io/v1beta1
kind: VirtualMachineRestore
metadata:
  name: db-01-restore
spec:
  target:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: db-01
  virtualMachineSnapshotName: db-01-before-upgrade
```

With the guest agent installed, KubeVirt freezes the filesystem first, giving a
consistent snapshot rather than a crash-consistent one. Install
`qemu-guest-agent` in every guest — see [[virtualization/kvm/qemu]].

### Hotplug

```bash
virtctl addvolume db-01 --volume-name=extra-disk
virtctl removevolume db-01 --volume-name=extra-disk
```

In KubeVirt v1.9, `addvolume` writes the volume into the VM spec, so it stays after
a restart. The old `--persist` flag still parses but does nothing. Volume hotplug is
on by default (the `DeclarativeHotplugVolumes` feature gate is Beta). Older releases
need the `HotplugVolumes` feature gate.

## Networking

Four binding modes, and the choice determines what the VM can do.

| Mode | Behaviour | Use for |
| --- | --- | --- |
| **masquerade** (`masquerade: {}`) | NAT behind the pod IP | Almost everything |
| **bridge** (`bridge: {}`) | The VM takes over the pod interface's IP and MAC address | Secondary networks (Multus), where the VM sits on a LAN |
| **passt** (`passtBinding: {}`) | User-space networking. The guest sees the pod's IP address, with no NAT | Replaces slirp; no extra privileges |
| **SR-IOV** (`sriov: {}`) | A virtual function of a physical NIC, passed through | Very high throughput |

> [!warning] Correction
> An earlier version called `masquerade` the default. It is not: a VM that lists no
> interface gets `bridge`, the default of `spec.configuration.network.defaultNetworkInterface`
> in the `KubeVirt` resource. Set the binding on every interface, as the examples here do.

> [!note] passt changed twice
> The first `passt: {}` binding was removed in KubeVirt v1.3, and passt moved to a
> network binding plugin. v1.8 brought it back into the core as `passtBinding: {}`
> (the `PasstBinding` feature gate, Beta, so on by default). `slirp` was also removed in
> v1.3.

```yaml
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
```

> [!important] `masquerade` keeps the VM a normal Kubernetes citizen
> Because traffic leaves via the pod IP, Services, NetworkPolicies, Ingress and
> service mesh all work with no special cases. `bridge` mode bypasses that — the VM
> has its own MAC and is not represented by the pod IP, so NetworkPolicy no longer
> describes it accurately.
>
> `bridge` mode also **blocks live migration** on the default pod network, unless the
> VM has the `kubevirt.io/allow-pod-bridge-network-live-migration` annotation. Use
> `masquerade` unless something specific forbids it.

### Additional networks with Multus

For a VM that needs a second interface on a real VLAN:

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vlan-100
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "bridge",
      "bridge": "br-vlan100",
      "ipam": {}
    }
```

```yaml
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: vlan100
              bridge: {}
      networks:
        - name: default
          pod: {}
        - name: vlan100
          multus:
            networkName: vlan-100
```

`"ipam": {}` leaves addressing to the guest: it gets its address from the VLAN's DHCP
server, or keeps its static configuration. This is the usual pattern for migrated VMs
that must stay on an existing VLAN while also being reachable through Kubernetes. See
[[linux/networking/virtual-interfaces]] for the host-side bridge.

## Live migration

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: migrate-db-01
spec:
  vmiName: db-01
```

```bash
virtctl migrate db-01
kubectl get vmim
kubectl get vmi db-01 -o jsonpath='{.status.migrationState}' | jq
```

Requirements, all of which must hold:

- `ReadWriteMany` storage
- `masquerade` or SR-IOV networking, not `bridge` on the pod network
- Compatible CPU models across nodes
- No PCI passthrough or other host-pinned device

> [!warning] Correction
> An earlier version also required the `LiveMigration` feature gate. Live migration
> is GA: the gate is always on and cannot be turned off.

```yaml
spec:
  configuration:
    migrations:
      parallelMigrationsPerCluster: 5
      parallelOutboundMigrationsPerNode: 2
      bandwidthPerMigration: 64Mi
      completionTimeoutPerGiB: 800
      allowAutoConverge: true
```

> [!tip] `allowAutoConverge` for VMs that will not converge
> Live migration copies memory while the guest keeps dirtying it. A write-heavy VM can
> dirty pages faster than they can be copied, so migration never completes and
> eventually times out.
>
> Auto-converge throttles the guest's CPU progressively to let the copy catch up. It
> causes a brief performance hit, and it turns "this VM can never be migrated" into
> "this VM migrates with a slowdown", which is usually the better trade during a node
> drain.

Eviction behaviour on drain:

```yaml
spec:
  template:
    spec:
      evictionStrategy: LiveMigrate
```

Without this, `kubectl drain` shuts VMs down rather than migrating them. The
cluster-wide default is `spec.configuration.evictionStrategy` in the `KubeVirt`
resource, and it is `None` unless you set it.

## CPU and memory

```yaml
      domain:
        cpu:
          cores: 4
          sockets: 1
          threads: 1
          model: host-passthrough
          dedicatedCpuPlacement: true
          isolateEmulatorThread: true
        memory:
          guest: 8Gi
          hugepages:
            pageSize: "2Mi"
        resources:
          requests:
            memory: 8Gi
            cpu: 4
```

`dedicatedCpuPlacement` gives exclusive cores, which needs the CPU Manager policy set
to `static` on the kubelet and a guaranteed QoS class.
`isolateEmulatorThread` puts QEMU's own threads elsewhere — the KubeVirt equivalent of
`<emulatorpin>` in [[virtualization/kvm/advanced]].

`model: host-passthrough` maximises performance and restricts migration to identical
hardware. `host-model` is the migratable compromise.

## GPU passthrough

```yaml
spec:
  configuration:
    permittedHostDevices:
      pciHostDevices:
        - pciVendorSelector: "10DE:2204"
          resourceName: "nvidia.com/GA102_GEFORCE_RTX_3090"
```

```yaml
      domain:
        devices:
          gpus:
            - deviceName: nvidia.com/GA102_GEFORCE_RTX_3090
              name: gpu1
```

`10DE:2204` is the PCI vendor and device ID: NVIDIA, GA102 GeForce RTX 3090. Get yours
with `lspci -nn`. An earlier version named this device an RTX 3080 (that is `10DE:2206`).

Needs the IOMMU enabled and devices bound to `vfio-pci` on the node — see
[[virtualization/kvm/advanced]]. A VM with a passed-through device cannot live
migrate.

## Benchmarking

Standard Kubernetes metrics do not describe VM behaviour well — pod readiness is not
the same as a guest OS being reachable, and nothing measures the pause during a live
migration.

[virtbench](https://www.cncf.io/blog/2026/06/08/benchmarking-kubevirt-performance-with-virtbench/)
is a CLI for reproducible stress tests across a KubeVirt cluster, measuring the things
that actually matter operationally:

| Metric | Why it matters |
| --- | --- |
| **Time-to-ready** | Wall clock from API call to the guest answering on the network — not to `Running` |
| **Burst capacity** | What the control plane and storage do when many VMs are created at once |
| **Live migration stun time** | How long the network is interrupted during a migration |

It breaks provisioning into `clone_duration` (the CSI copy), `running_time` (kubelet
container start) and `ping_time` (guest network probe), and outputs JSON, CSV and an
HTML dashboard. Built-in scenarios cover DataSource provisioning, single- and
multi-node boot storms, live migration, chaos, and failure and recovery.

> [!important] `clone_duration` is where a bad StorageClass shows up
> Splitting provisioning into three phases localises the problem immediately. A long
> `clone_duration` with fast `running_time` means storage — a CSI driver copying the
> whole disk instead of taking a snapshot, which is exactly the trap in the
> [[virtualization/kubevirt/advanced#storage|storage section above]].
>
> The boot storm test is the one worth running before going live: a hundred VMs
> starting at once is the load pattern that follows a node failure, and it is a very
> different test from starting a hundred VMs slowly.

Stun time deserves the same attention — a migration that completes successfully but
pauses the guest for eight seconds will have broken every TCP connection it had.

## Where to go next

- [[virtualization/kubevirt/gitops]] — declaring all of this in Git
- [[virtualization/kubevirt/troubleshooting]] — when migration or storage fails
- [[kubernetes/storage/pv-pvc-sc]] — the storage layer underneath
- [[linux/storage/disk-io-performance]] — diagnosing the storage a slow clone points at

<!-- uplink -->
Part of [[virtualization/kubevirt/index|KubeVirt]].
