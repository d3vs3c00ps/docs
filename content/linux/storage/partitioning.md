---
title: Reference partition layouts
description: Standard btrfs-on-EFI partition and subvolume layout for SUSE-family images
tags: [linux, storage, partitioning, btrfs, suse]
type: reference
status: complete
---

# Reference partition layouts

## SUSE family — btrfs on EFI

Images are built for EFI boot with the layout below. `/var` is its own btrfs
filesystem, so runaway logging cannot fill the root filesystem. `/var/log` and
`/var/log/audit` are subvolumes of it: they are left out of snapshots of `/var` and
can have their own mount options.

> [!warning] Correction
> The original note said the `/var/log` and `/var/log/audit` subvolumes keep audit
> data separate, as the CIS benchmark requires. A subvolume shares the free space of
> its filesystem: full logs in `/var/log` also fill `/var/log/audit` and `/var/tmp`.
> CIS asks for separate partitions. To get close to that with subvolumes, set a
> quota group limit on each one (see below).

| Mount point | Filesystem | Mount options | Size |
| --- | --- | --- | --- |
| `/` | btrfs | `defaults` | 15 GB |
| `/home` | btrfs | `subvol=/@/home` | subvolume |
| `/opt` | btrfs | `subvol=/@/opt` | subvolume |
| `/usr` | btrfs | `subvol=/@/usr` | subvolume |
| `/usr/local` | btrfs | `subvol=/@/usr/local` | subvolume |
| `/srv` | btrfs | `subvol=/@/srv` | subvolume |
| `/var` | btrfs | — | 5 GB |
| `/var/tmp` | btrfs | `subvol=/var@/var/tmp` | subvolume |
| `/var/log` | btrfs | `subvol=/var@/var/log` | subvolume |
| `/var/log/audit` | btrfs | `subvol=/var@/var/log/audit` | subvolume |
| `/boot` | btrfs | — | 512 MB |
| `/boot/grub2/x86_64-efi` | btrfs | `subvol=/boot@/boot/grub2/x86_64-efi` | subvolume |
| `/boot/grub2/i386-pc` | btrfs | `subvol=/boot@/boot/grub2/i386-pc` | subvolume |
| `/boot/efi` | vfat | `utf8` | 64 MB |
| `/tmp` | tmpfs | — | 1 GB |
| `/dev/shm` | tmpfs | — | 512 MB |
| `swap` | swap | — | 1 GB |

> [!note] Subvolumes do not have a fixed size
> btrfs subvolumes share the free space of their parent filesystem, so only the
> genuine partitions and volumes (`/`, `/var`, `/boot`, `/boot/efi`) and the tmpfs
> mounts carry a size. Use btrfs quota groups if you need hard limits per
> subvolume.

> [!warning] Correction from the original layout
> The source version of this table listed `/proc` as a btrfs subvolume. `/proc` is
> always `procfs`, a kernel-provided virtual filesystem, and cannot be a
> subvolume — that row has been removed.

See [[linux/storage/swap]] for swap sizing and priorities, and
[[linux/storage/lvm]] if you use LVM rather than plain partitions.

<!-- uplink -->
Part of [[linux/storage/index|Storage]].
