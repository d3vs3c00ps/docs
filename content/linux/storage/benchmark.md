---
title: Filesystem benchmarking
description: Quick filesystem throughput benchmarking with bonnie++
tags: [linux, storage, performance, benchmark]
type: howto
status: complete
---

# Filesystem benchmarking

`bonnie++` gives a quick read of filesystem throughput, which is enough to tell
whether a mount-option or layout change actually helped.

Set up a dedicated disk for the test — never benchmark against a filesystem
holding data you care about:

```bash
cfdisk /dev/sdb                   # create one partition: /dev/sdb1
mkfs.ext4 /dev/sdb1
mkdir -p /mnt/bench
mount /dev/sdb1 /mnt/bench
zypper install bonnie++
bonnie++ -u 0 -n 256 -d /mnt/bench
```

| Option | Meaning |
| --- | --- |
| `-u` | UID to run as (`0` for root) |
| `-n` | number of files for the file-creation tests, in thousands |
| `-s` | size of the I/O test in MB; by default twice the RAM |
| `-r` | the RAM size in MB that bonnie++ assumes |
| `-d` | directory to test in |

> [!tip] Use a large enough `-s`
> If the test size is not comfortably larger than RAM, you are measuring the page
> cache rather than the disk. bonnie++ enforces this: without `-s` it writes twice
> the RAM, and a smaller `-s` stops with `File size should be double RAM for good
> results`. Lower `-r` as well only for a quick trial, since the numbers then show
> the cache.

> [!note] No `-s` here
> On a machine with more than 512 MB of RAM, bonnie++ refuses `-s 1024` and prints its
> usage. Without `-s`, it picks a size of twice the RAM.

The `-n 256` test creates 262,144 files, so the filesystem needs that many free
inodes. A small test disk can run out of them.

With a much smaller `-n`, the file-creation phase finishes too fast to produce
usable numbers.

> [!warning] reiserfs is gone
> `reiserfs` was removed from the Linux kernel in 6.13, so use `ext4`, `xfs` or `btrfs` instead. See
> [[linux/storage/partitioning]] for a worked btrfs layout.

<!-- uplink -->
Part of [[linux/storage/index|Storage]].
