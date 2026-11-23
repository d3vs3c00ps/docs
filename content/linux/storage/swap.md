---
title: Managing swap
description: Inspecting swap usage, tuning swappiness and setting per-device swap priorities
tags: [linux, storage, memory, performance, tuning]
type: howto
status: complete
---

# Managing swap on Linux

If a system feels like it is swapping when it shouldn't, these are the things to
look at.

## Identifying swap usage

```bash
free -m
swapon -s
```

`free -m` reports used, free and cached memory in megabytes, with a separate line
for swap. `swapon -s` lists the active swap devices with their size, current
usage and priority. `swapon --show` is the newer form of the same list, with
sizes in human units.

## Swappiness

`vm.swappiness` is a tunable from `0` to `200` that controls how aggressively the
kernel reclaims memory by swapping out anonymous pages, *relative to* dropping
page cache. The default on most distributions is `60`.

> [!warning] Correction
> The original note gave the range as `0` to `100`. Since Linux 5.8 the maximum
> is `200`. Values above `100` make the kernel prefer swapping over dropping page
> cache, which helps when swap is fast (zram, a fast NVMe drive).

> [!warning] It is not a usage threshold
> A swappiness of `60` does **not** mean "start swapping once 60% of RAM is
> used". It is a relative weighting between two reclaim strategies, and the
> kernel can swap well before memory is full. Lowering it biases the kernel
> toward evicting page cache instead; `0` does not disable swap entirely, it only
> makes swapping a last resort.

Read the current value:

```console
$ cat /proc/sys/vm/swappiness
60
```

Set it for the running system:

```bash
sysctl -w vm.swappiness=15
```

Make it persistent with a drop-in file:

```bash
echo 'vm.swappiness = 15' > /etc/sysctl.d/99-swappiness.conf
sysctl --system
```

## Swap priorities

If you have several disks — especially one small fast one — you can put swap on
more than one of them and control the order in which they are used.

Show the current priorities:

```console
$ swapon -s
Filename                        Type            Size    Used    Priority
/dev/dm-1                       partition       2097148 0       -2
/dev/dm-2                       partition       3905528 0       -1
```

Set them in `/etc/fstab` with the `pri=` mount option:

```text
/dev/mapper/rhel-root                       /       xfs     defaults        0 0
UUID=703f76ae-ec89-4213-9215-33c7f2bb060f   /boot   xfs     defaults        0 0
/dev/mapper/rhel-swap1                      swap    swap    sw,pri=1        0 0
/dev/mapper/rhel-swap2                      swap    swap    sw,pri=2        0 0
```

The names are `/dev/mapper/<VG>-<LV>`: here the logical volumes `swap1` and `swap2`
in the volume group `rhel`. A hyphen inside a name is doubled in this path, so an
LV called `swap-1` would be `/dev/mapper/rhel-swap--1`. `/dev/rhel/swap-1` avoids
the problem.

> [!note]
> The original example used `/dev/mapper/rhel-swap-1`, which is the LV `1` in a VG
> called `rhel-swap`. The names were changed so that they match the text.

> [!important] Higher number means higher priority
> The kernel fills the highest-priority swap area first. Devices sharing the same
> priority are striped across, which is what you want for two equally fast disks.

<!-- uplink -->
Part of [[linux/storage/index|Storage]].
