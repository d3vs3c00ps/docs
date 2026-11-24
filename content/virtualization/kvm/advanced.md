---
title: KVM performance and passthrough
description: CPU models and pinning, NUMA, hugepages, virtio-blk versus SCSI, and PCI passthrough with VFIO and IOMMU groups
tags: [virtualization, kvm, performance, numa, passthrough]
type: reference
status: complete
---

# KVM performance and passthrough

Default KVM is already fast. This is what to change when it is not fast enough, and
what it costs.

## CPU model

```xml
<cpu mode='host-passthrough' check='none' migratable='on'/>
```

| Mode | Guest sees | Migration |
| --- | --- | --- |
| `host-passthrough` | The host CPU exactly, every feature | Only to identical hardware |
| `host-model` | The closest named model plus available features | Within a similar generation |
| Named, e.g. `Nehalem` | That model only | Anywhere supporting it |
| `qemu64` (default) | A generic, feature-poor model | Anywhere |

> [!important] The default costs real performance
> A hand-written domain XML without `<cpu>` gets QEMU's default model, `qemu64` on
> x86 — no AES-NI, no AVX, none of the instruction set extensions that modern
> software checks for. TLS throughput and anything using vector instructions suffer
> badly. `virt-install` avoids this: it writes `host-passthrough` for a KVM guest,
> and `maximum` (every feature TCG can emulate) for an emulated one.
>
> Use `host-passthrough` for single-host workloads and `host-model` for a fleet you
> may migrate. There is rarely a reason for the default.

## CPU pinning and topology

Pin vCPUs to physical cores so the host scheduler stops moving them between caches:

```xml
<vcpu placement='static'>4</vcpu>
<cputune>
  <vcpupin vcpu='0' cpuset='4'/>
  <vcpupin vcpu='1' cpuset='5'/>
  <vcpupin vcpu='2' cpuset='6'/>
  <vcpupin vcpu='3' cpuset='7'/>
  <emulatorpin cpuset='0-1'/>
</cputune>
<cpu mode='host-passthrough'>
  <topology sockets='1' dies='1' cores='2' threads='2'/>
</cpu>
```

`<topology>` matters for licensing and for guest schedulers — presenting four sockets
of one core each is both unrealistic and expensive for per-socket licensed software.

```bash
lscpu -e                       # core/socket/NUMA layout
virsh vcpupin web-01
virsh emulatorpin web-01
```

> [!tip] Pin the emulator threads too
> QEMU's other threads (the main loop, and the I/O threads unless you pin those) run
> on whatever cores the host chooses, and can land on the same cores as the pinned
> vCPUs — reintroducing exactly the jitter pinning was meant to remove.
> `<emulatorpin>` puts them on separate housekeeping cores; `<iothreadpin>` does the
> same for each I/O thread. Pinning vCPUs without them is a common half-measure.

## NUMA

On a multi-socket host, a VM whose memory is on one node and vCPUs on another pays for
every access.

```bash
numactl --hardware
virsh nodeinfo
```

```xml
<numatune>
  <memory mode='strict' nodeset='0'/>
</numatune>
<cputune>
  <vcpupin vcpu='0' cpuset='0-3'/>
</cputune>
```

Keep the vCPU cpuset and the memory nodeset on the same NUMA node. For a VM larger
than one node, present a matching guest topology with `<numa>` so the guest can make
its own sensible decisions.

## Hugepages

Fewer, larger pages mean fewer TLB misses — worth several percent on memory-heavy
guests, more on databases.

```bash
# 4096 × 2 MB = 8 GB
echo 4096 | sudo tee /proc/sys/vm/nr_hugepages
grep Huge /proc/meminfo
```

Persistently, in `/etc/sysctl.d/`:

```ini
vm.nr_hugepages = 4096
```

```xml
<memoryBacking>
  <hugepages/>
  <locked/>
</memoryBacking>
```

> [!warning] Hugepages are reserved and unavailable to everything else
> Allocated pages leave the general pool permanently, whether or not a VM uses them.
> Over-allocate and the host starts swapping while `free` appears to show plenty
> available. Size them to the VMs that will actually use them, and allocate at boot —
> a fragmented host cannot always satisfy the request later.
>
> KSM does not merge huge pages, and the balloon cannot give them back to the host,
> so you also lose overcommitment for that guest.

## Disk

```xml
<disk type='file' device='disk'>
  <driver name='qemu' type='raw' cache='none' io='native'
          discard='unmap' iothread='1'/>
  <target dev='vda' bus='virtio'/>
</disk>
```

`iothread='1'` names an I/O thread that the domain must declare, at the top level
of `<domain>`. Without it, libvirt refuses the disk:

```xml
<iothreads>2</iothreads>
```

| Choice | When |
| --- | --- |
| `virtio-blk` | Lowest latency. The default choice |
| `virtio-scsi` | Needed for more than ~28 disks, TRIM passthrough on some setups, and SCSI passthrough |
| `raw` over `qcow2` | Measurably faster; loses snapshots and thin provisioning |
| LVM volume instead of a file | Skips the host filesystem entirely |

For maximum throughput, a raw LVM logical volume with `cache='none'` and
`io='native'` gets close to bare metal. See [[linux/storage/lvm]].

## Network

```xml
<interface type='bridge'>
  <source bridge='br0'/>
  <model type='virtio'/>
  <driver name='vhost' queues='4'/>
</interface>
```

`vhost` moves the datapath into the kernel. Multiqueue — `queues` matching vCPU count
— lets several vCPUs process packets in parallel, which matters above roughly a
gigabit. The guest needs it enabled too:

```bash
ethtool -L eth0 combined 4
```

For genuinely high packet rates, SR-IOV or a `vhost-user` DPDK path bypasses more of
the stack, at the cost of losing live migration.

## PCI passthrough

Giving a VM real hardware — a GPU, an HBA, a NIC.

### 1. Enable the IOMMU

On Intel, add `intel_iommu=on` to the kernel command line. On AMD, the IOMMU is on by
default when the firmware enables it: there is nothing to add. `iommu=pt` (both)
keeps host devices out of the IOMMU's translation, for speed.

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX="intel_iommu=on iommu=pt"
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
sudo reboot
```

On RHEL and Fedora, `sudo grubby --update-kernel=ALL --args="intel_iommu=on iommu=pt"`
does the same without editing files.

> [!warning] Correction
> The original said `amd_iommu=on`. The kernel's `amd_iommu=` option takes values
> such as `off` or `force_isolation`; `on` is not one of them.

See [[linux/boot/grub]].

```bash
dmesg | grep -i -e DMAR -e IOMMU
```

### 2. Find the device and its group

```bash
lspci -nn | grep -i nvidia
# 01:00.0 VGA compatible controller [0300]: ... [10de:2204]

for g in /sys/kernel/iommu_groups/*; do
  echo "Group ${g##*/}:"
  for d in "$g"/devices/*; do echo -n "  "; lspci -nns "${d##*/}"; done
done
```

> [!danger] The IOMMU group is the unit of passthrough, not the device
> Everything in a group must be passed through together — the hardware cannot isolate
> them individually. A GPU sharing a group with the host's USB controller means
> passing the USB controller too, and losing your keyboard.
>
> When a group is too coarse, the options are a different physical slot, a different
> motherboard, or the ACS override patch — which **defeats the isolation the IOMMU
> exists to provide** and should not be used where the guest is untrusted.

### 3. Bind to vfio-pci

```bash
# /etc/modprobe.d/vfio.conf
options vfio-pci ids=10de:2204,10de:1aef
softdep nvidia pre: vfio-pci
```

```bash
sudo dracut -f --regenerate-all && sudo reboot
lspci -nnk -d 10de:2204 | grep -i 'kernel driver'
# Kernel driver in use: vfio-pci
```

Binding by vendor:device ID catches **all** identical cards — pin by PCI address in a
driver-override script if the host needs to keep one.

### 4. Attach

```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
  </source>
</hostdev>
```

A passed-through device also **pins the VM's memory**, so ballooning and overcommit
stop working for that guest, and live migration becomes impossible.

## Measuring

```bash
virsh domstats web-01 --cpu-total --balloon --block --interface
virt-top
perf kvm stat live                    # VM exits — the interesting number
```

`perf kvm stat` shows the exit reasons. A guest with a very high exit rate is
spending its time trapping into the hypervisor, and the exit reason names the cause
directly.

## Where to go next

- [[virtualization/kvm/troubleshooting]] — when these changes stop it booting
- [[virtualization/kvm/qemu]] — machine types and disk formats
- [[linux/storage/lvm]] — the storage layer underneath

<!-- uplink -->
Part of [[virtualization/kvm/index|KVM and QEMU]].
