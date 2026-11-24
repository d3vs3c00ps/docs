---
title: Hiding a disk from the OS
description: Removing a SCSI device at runtime without unplugging it, rescanning to bring it back, and doing the same at the RAID controller
tags: [linux, storage, scsi, hardware, troubleshooting]
type: howto
status: complete
---

# Hiding a disk from the OS

In a lab you sometimes need a disk to *not* be there — an installer that refuses to
proceed with extra disks present, a test of behaviour with fewer devices, or an
array you want the OS to ignore without physically pulling it.

Two approaches: detach the SCSI device in the kernel, or disable the physical drive
at the RAID controller.

> [!note] Not tested locally
> It needs SCSI disks and an HPE Smart Array controller. The Docker VM used for the
> tests has only virtio disks, and loading `scsi_debug` would change its shared kernel.

> [!danger] This is for lab machines
> Deleting a SCSI device removes it from the running system immediately. If anything
> is mounted from it, or it is part of an active LVM volume group or array, you will
> take I/O errors and can lose data. Unmount and deactivate first, and never run this
> against a disk holding anything you care about.

## The kernel way

Identify the devices:

```bash
lsblk | grep -e sda -e sdb
```

```text
sda                               8:0    0   1.8T  0 disk
sdb                               8:16   0   1.8T  0 disk
```

Detach them:

```bash
echo 1 | sudo tee /sys/block/sda/device/delete
echo 1 | sudo tee /sys/block/sdb/device/delete
```

The devices disappear from `lsblk` at once. This does not persist — a reboot brings
them back.

### Bringing them back without rebooting

Find the SCSI hosts:

```bash
ls -l /sys/class/scsi_host/
```

```text
lrwxrwxrwx. 1 root root 0 Aug 13 17:06 host0 -> ../../devices/pci0000:00/0000:00:14.0/usb3/3-4/3-4:1.0/host0/scsi_host/host0
lrwxrwxrwx. 1 root root 0 Aug 13 17:06 host1 -> ../../devices/pci0000:5b/0000:5b:00.0/0000:5c:00.0/host1/scsi_host/host1
```

Rescan each one. The `- - -` means "any channel, any target, any LUN":

```bash
echo "- - -" | sudo tee /sys/class/scsi_host/host0/scan
echo "- - -" | sudo tee /sys/class/scsi_host/host1/scan
```

> [!warning] Device names are not stable across a rescan
> A disk that was `sda` before deletion may come back as `sdc`, because kernel names
> are assigned in discovery order. Anything that must survive this should reference
> the disk by `/dev/disk/by-id/` or by UUID, not by `/dev/sdX`. The same applies to
> `/etc/fstab` — see [[linux/storage/partitioning]].

## The RAID controller way

On an HPE Smart Array controller, disable the physical drive so the OS never sees
it:

```bash
# Disable
/opt/smartstorageadmin/ssacli/bin/ssacli ctrl slot=0 physicaldrive 1I:1:2 modify disablepd

# Re-enable
/opt/smartstorageadmin/ssacli/bin/ssacli ctrl slot=0 physicaldrive 1I:1:2 modify reenable
```

List what the controller can see, to get the slot and drive identifiers:

```bash
/opt/smartstorageadmin/ssacli/bin/ssacli ctrl all show config
```

This survives a reboot, which is the main difference from the kernel approach —
useful when the machine will be reinstalled and you want the disk hidden throughout.

## Which to use

| | Kernel `delete` | Controller `disablepd` |
| --- | --- | --- |
| Survives reboot | No | Yes |
| Needs vendor tooling | No | Yes |
| Reversible without reboot | Yes, by rescanning | Yes |
| Works on any disk | Yes | Only behind that controller |

Use the kernel method for a quick, temporary change, and the controller method when
the disk should stay invisible across an installation.

## Where to go next

- [[linux/storage/partitioning]] — stable device references
- [[linux/storage/lvm]] — deactivating volume groups before detaching
- [[storage/raid-and-alua]] — what the controller is doing underneath

<!-- uplink -->
Part of [[linux/storage/index|Storage]].
