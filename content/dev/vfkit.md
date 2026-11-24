---
title: vfkit
description: Run Linux VMs from the command line on a Mac with Apple Virtualization - create, network, storage, list, delete, modify, monitor
tags: [dev, macos, virtualization, vfkit]
type: reference
status: draft
---

# vfkit

vfkit is a small command line hypervisor for macOS. It uses Apple's Virtualization
framework, so VMs run at native speed on Apple Silicon. There is no daemon, no GUI
and no VM database. One VM is one `vfkit` process.

Used in [[labs/nixos-homelab/overview|the NixOS home lab]]. The script is
`lab/lab.sh` in the nix-lab repository.

> [!note] Not tested locally
> vfkit runs only on macOS. The test harness runs Linux containers. Commands marked
> "checked" below were run on vfkit 0.6.4, Apple Silicon. Others come from
> `vfkit --help` and the binary, and were not run.

## Install

```bash
brew install vfkit
vfkit --version        # 0.6.4 when checked
```

vfkit runs guests of the **same CPU type** as the Mac: arm64 Linux on Apple Silicon.

## Create a VM

A VM is one command. Minimal version: EFI boot, an ISO, an empty disk, NAT network.

```bash
truncate -s 20G vm1.raw                       # sparse: uses no space until written
vfkit --cpus 2 --memory 2048 \
  --bootloader efi,variable-store=vm1.efi,create \
  --device usb-mass-storage,path=lab.iso,readonly \
  --device virtio-blk,path=vm1.raw \
  --device virtio-net,nat,mac=52:54:00:00:00:01 \
  --device virtio-serial,logFilePath=vm1.log
```

Checked. Install to the disk, then **remove the ISO line** to boot the installed
system. Run it in the background with `nohup ... &` and `--pidfile vm1.pid`.

| Option | Meaning |
| --- | --- |
| `--cpus`, `--memory` | vCPUs and RAM in MiB. Defaults: 1 and 512 |
| `--bootloader efi,variable-store=F,create` | UEFI. `F` keeps boot entries. `create` makes it if missing |
| `--bootloader linux,kernel=K,initrd=I,cmdline="..."` | Direct kernel boot, no firmware. The kernel must not be compressed |
| `--cloud-init user-data,meta-data` | Attach cloud-init files |
| `--nested` | Nested virtualization, if the Mac supports it |
| `--gui` | Open a window. Probably needs a `virtio-gpu` device (not tested) |

> [!warning] A writable disk or ISO can be used by one VM only
> A second VM on the same writable file fails with `The storage device attachment is
> invalid`. Add `,readonly` to a shared ISO. Give each VM its own disk file.

## Networking

`virtio-net,nat` is the simplest choice. macOS gives the VM a private network with DHCP
and NAT to the outside.

> [!warning] VMs on `nat` cannot reach each other
> Checked: two VMs on `nat` both reach the Mac, the gateway and the internet, but ARP
> between them fails (`ip neigh` shows `FAILED`). For a cluster or any multi-VM lab,
> use a shared network: see "Shared network between VMs" below.

```text
--device virtio-net,nat,mac=52:54:00:00:00:01
```

Checked:

- The subnet was `192.168.64.0/24`. The Mac is `.1`, the first lease is `.2`.
- Each VM reaches the Mac and the internet, but not the other VMs (see the warning
  above).
- With a fixed `mac=`, the VM gets the same lease every time. Without it, the
  address may change (not tested).
- A static IP outside the lease range (`.10`, `.20`) also worked.

Read the leases on the Mac:

```bash
cat /var/db/dhcpd_leases
```

> [!note] Leases drop leading zeros
> The MAC `52:54:00:00:00:0a` appears as `52:54:0:0:0:a` in this file. Strip the
> zeros before you search.

### Shared network between VMs

[vmnet-helper](https://github.com/nirs/vmnet-helper) puts all VMs on one vmnet network,
so they can talk to each other. Checked with 4 VMs on macOS 26 (no root needed there;
older macOS needs root).

```bash
brew tap nirs/vmnet-helper && brew install vmnet-helper
"$(brew --prefix vmnet-helper)/libexec/vmnet-run" -- vfkit --cpus 2 --memory 2048 \
  --bootloader efi,variable-store=vm1.efi,create \
  --device virtio-blk,path=vm1.raw \
  --device virtio-net,fd=4,mac=52:54:00:00:00:01
```

- Use `fd=4` exactly: `vmnet-run` passes the network socket on file descriptor 4.
- The VMs stayed on `192.168.64.0/24` with gateway `.1`, so static IPs and DHCP behave
  as with `nat`. The vmnet-helper docs say the range can change when it is taken.
- The process tree is `vmnet-run`, then `vmnet-helper` and `vfkit`. Stop the VM from
  inside (`poweroff`) and all three exit. `ps` shows the `vmnet-run` pid.

Other modes, from the binary and not run:

- `virtio-net,unixSocketPath=/path/net.sock`: connect to a user-space network
  proxy. The path must be short: macOS limits socket paths to about 104 characters.
- `virtio-net,fd=N`: use a socket your own program passes in.
- `nat` and `unixSocketPath` cannot be combined.
- No port forwarding and no bridged mode are built in, as far as the help shows.
  Reach the guest on its NAT address, or use an extra proxy tool.

## Storage

vfkit has no storage pool. **You choose every path** and keep the files yourself.
A good layout is one folder per VM:

```text
lab/state/gitea/
  disk.raw        root disk, raw format
  efi             EFI variable store (boot entries)
  console.log     serial output
  vfkit.pid       pid file
```

| Device | Use |
| --- | --- |
| `virtio-blk,path=disk.raw` | Normal disk. Appears as `/dev/vda` in Linux (checked) |
| `nvme,path=disk.raw` | Same, as an NVMe disk |
| `usb-mass-storage,path=x.iso,readonly` | Installer ISO |
| `virtio-fs,sharedDir=/path,mountTag=share` | Share a Mac folder. In the guest: `mount -t virtiofs share /mnt` |
| `rosetta,mountTag=rosetta` | Run x86-64 binaries in a Linux guest |

Disks are **raw images**. Not `qcow2`.

```bash
truncate -s 40G disk.raw     # grow the file (VM stopped), then grow the partition
                             # and filesystem inside the guest: growpart, resize2fs
cp -c disk.raw backup.raw    # APFS clone: instant, uses no extra space until changed
du -h disk.raw               # real size on disk
ls -lh disk.raw              # size the guest sees
```

There are no snapshots in vfkit. A stopped VM's `cp -c` is a good enough copy. A raw
disk cannot be shrunk.

The EFI variable store matters: it holds the boot entry written by the installer. If
you delete it, the VM may boot the ISO again or drop to the firmware shell.

## List VMs

vfkit keeps no list. A VM exists while its process runs.

```bash
pgrep -fl vfkit                       # all running VMs, with their command line
ps -o pid,etime,pcpu,rss,command -p "$(cat vm1.pid)"
kill -0 "$(cat vm1.pid)" && echo running
```

With one folder per VM, "all VMs" is `ls lab/state/`. Running ones have a live pid in
`vfkit.pid`. A stale pid file after a crash is normal: test it with `kill -0`.

## Delete a VM

Stop the process, then delete the folder. Nothing else exists, as there is no registry.

```bash
kill "$(cat vm1.pid)"        # SIGTERM stops the VM
rm -rf lab/state/gitea
```

The lease stays in `/var/db/dhcpd_leases` until it expires. A new VM with the same MAC
gets the same address.

## Modify a VM

A running VM cannot change. Stop it, change the flags, start it again.

| Change | How |
| --- | --- |
| CPUs, RAM | Change `--cpus`, `--memory`, restart |
| Add or remove a device | Edit the `--device` list, restart |
| Bigger disk | `truncate -s` bigger, then resize inside the guest |
| New MAC or IP | Change `mac=`. The old lease is ignored |
| Reinstall | Delete `disk.raw` and `efi`, start with the ISO |

Keep the command line in a script (see `lab/lab.sh`). It is the VM definition.

## Monitor

| What | How |
| --- | --- |
| Console output | `virtio-serial,logFilePath=console.log`, then `tail -f`. Cannot be combined with `stdio` or `pty` |
| Interactive console | `virtio-serial,stdio` or `virtio-serial,pty` |
| CPU and RAM use | `ps` or `top` on the vfkit pid. This is the VM's share of the Mac |
| Is it up | Ping or `ssh` the guest. Add `systemctl is-system-running` for health |
| vfkit's own log | Redirect stdout and stderr: `... >vfkit.log 2>&1` |
| Stop and inspect | `--restful-uri tcp://127.0.0.1:8123` starts a small HTTP API |

> [!warning] The REST API did not answer in my test
> `--restful-uri` is in the help, and the binary has `/vm/inspect` and a state
> endpoint. A test with `curl localhost:8123/vm/state` on a VM with no OS returned
> nothing. Do not rely on it before you test it with a booted guest.

The lab has a smoke test that checks SSH, hostname, systemd state, DNS and ping
between hosts: `lab/lab.sh smoke`.

## Pitfalls

- Same writable file on two VMs: see the warning above.
- ISO still attached after the install: the VM may boot the installer again.
  Remove the device and restart.
- A VM stops when its vfkit process exits, including when you close the terminal that
  started it without `nohup`.

<!-- uplink -->
Part of [[dev/index|Development]].
