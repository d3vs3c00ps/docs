---
title: "KVM and QEMU"
description: "Turning Linux into a hypervisor: the kernel module, the emulation layer, libvirt, and the tuning that separates adequate from fast."
tags: [kvm]
type: moc
status: complete
---

<!-- generated-moc -->

# KVM and QEMU

Turning Linux into a hypervisor: the kernel module, the emulation layer, libvirt, and the tuning that separates adequate from fast.


| Note | | What it covers |
| --- | --- | --- |
| [[virtualization/kvm/advanced\|KVM performance and passthrough]] | reference | CPU models and pinning, NUMA, hugepages, virtio-blk versus SCSI, and PCI passthrough with VFIO and IOMMU groups |
| [[virtualization/kvm/basics\|KVM basics]] | how-to | Installing the stack, creating a first VM with virt-install, storage pools, the default network, and what a domain XML contains |
| [[virtualization/kvm/introduction\|What KVM is]] | concept | The kernel module, QEMU, and libvirt — three things people call "KVM", and how they fit together |
| [[virtualization/kvm/qemu\|QEMU]] | concept | The emulation layer under KVM — machine types, disk image formats, qemu-img, running QEMU directly, and cross-architecture emulation |
| [[virtualization/kvm/troubleshooting\|KVM troubleshooting]] | reference | Permission denied on images, VMs that will not start, silent TCG fallback, networking failures, and reading libvirt's logs |
| [[virtualization/kvm/usage\|Using virsh day to day]] | reference | Lifecycle, console access, snapshots and their traps, cloning, live migration, and editing a running domain |

Part of [[virtualization/index|Virtualisation]].
