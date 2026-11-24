---
title: KVM troubleshooting
description: Permission denied on images, VMs that will not start, silent TCG fallback, networking failures, and reading libvirt's logs
tags: [virtualization, kvm, libvirt, troubleshooting]
type: reference
status: complete
---

# KVM troubleshooting

> [!note] Things that are easy to get wrong
> - Current distributions run `virtqemud`, not `libvirtd`: the commands below ask
>   for both.
> - systemd-resolved does not block libvirt's dnsmasq: it listens on `127.0.0.53`
>   only. A DNS server bound to `0.0.0.0:53` does.
> - Plain `virsh undefine` does not leave a stale NVRAM file: it refuses a UEFI VM.
>   `--keep-nvram` is what leaves the file behind.
> - `amd_iommu=on` is not a valid kernel option.
> - `qemu-img info` and `check` refuse the image of a running VM without `-U`.
> - After a firewall flush, restart `virtnetworkd`: `net-destroy` and `net-start`
>   fail with the nftables backend.

## Where the logs are

```bash
journalctl -u virtqemud -u libvirtd -n 200 --no-pager
cat /var/log/libvirt/qemu/web-01.log        # per-VM, and the useful one
virsh domstate web-01 --reason
```

Current distributions run `virtqemud` (and `virtnetworkd`, `virtstoraged`) instead
of the single `libvirtd`; see [[virtualization/kvm/basics]]. Ask the journal for both.

The per-VM QEMU log is where the actual error lives. libvirt's own message is usually
a wrapper around it.

## `Permission denied` opening a disk image

The most common first failure, and it is rarely POSIX permissions.

```bash
ls -l /var/lib/libvirt/images/web-01.qcow2
ls -Z /var/lib/libvirt/images/web-01.qcow2      # SELinux label
```

Three possible causes:

**SELinux.** QEMU runs confined as `svirt_t`. When a VM starts, libvirt relabels its
disks `svirt_image_t`, with categories unique to that VM. Images at rest should carry
`virt_image_t`, the default type for `/var/lib/libvirt/images`. An image moved in
from elsewhere keeps its old label, and a directory outside the default paths has no
rule at all:

```bash
sudo restorecon -Rv /var/lib/libvirt/images/
sudo semanage fcontext -a -t virt_image_t "/srv/vms(/.*)?"
sudo restorecon -Rv /srv/vms
```

See [[security/selinux]].

**Ownership.** libvirt runs QEMU as `qemu:qemu` (openSUSE, RHEL) or
`libvirt-qemu:kvm` (Debian, Ubuntu). It normally changes the owner of a disk when the
VM starts (`dynamic_ownership` in `qemu.conf`) and gives it back at stop. Where that
is off, or the file sits on NFS, set it yourself:

```bash
sudo chown qemu:qemu /var/lib/libvirt/images/web-01.qcow2
```

**Traversal.** QEMU needs execute permission on **every** directory in the path. An
image under `/home/alice/vms/` fails because `/home/alice` is mode 700 — and the error
names only the image file, not the directory that actually blocked it.

> [!tip] Keep images in a libvirt-managed pool
> Defining a storage pool makes libvirt handle labelling and ownership for you. Most
> permission problems are images sitting somewhere ad hoc. See
> [[virtualization/kvm/basics]].

## The VM is extremely slow

Almost always no hardware acceleration.

```bash
virsh dumpxml web-01 | head -1
# <domain type='kvm'>    ← good
# <domain type='qemu'>   ← software emulation
```

```bash
ls -l /dev/kvm
grep -cE 'vmx|svm' /proc/cpuinfo
virt-host-validate
```

If `/dev/kvm` is missing: virtualisation is disabled in firmware, or you are inside a
VM without nesting enabled. See [[virtualization/kvm/introduction]].

If it exists but permission is denied, your distribution gives `/dev/kvm` mode
`0660` (the systemd default is `0666`), and you are not in the `kvm` group:

```bash
sudo usermod -aG kvm,libvirt "$USER" && newgrp libvirt
```

Second cause of slowness, once KVM is confirmed: emulated devices instead of virtio.

```bash
virsh domblklist web-01
virsh dumpxml web-01 | grep -E "model type|target dev|bus="
```

`bus='ide'` or `model type='e1000'` should be `virtio`.

## `Failed to connect socket ... No such file or directory`

Or, on recent libvirt, `cannot identify any listening daemon socket path`. The
daemon's socket is not active:

```bash
sudo systemctl status virtqemud.socket
sudo systemctl enable --now virtqemud.socket     # or libvirtd, on older systems
```

If the daemon is running and it still fails, you are connecting to the wrong URI:

```bash
virsh --connect qemu:///system list --all
export LIBVIRT_DEFAULT_URI=qemu:///system
```

A VM invisible to plain `virsh` after being created with `sudo` is this — see
[[virtualization/kvm/basics]].

## The VM starts but has no network

Work outward from the guest.

```bash
virsh domiflist web-01
virsh net-list --all
virsh net-dhcp-leases default
ip link show virbr0
```

**The default network is not started:**

```bash
virsh net-start default && virsh net-autostart default
```

**dnsmasq is not running,** so no DHCP:

```bash
ps aux | grep dnsmasq
journalctl -u libvirtd | grep -i dnsmasq
```

A host-wide DNS server bound to port 53 on all addresses (`0.0.0.0:53`) prevents
libvirt's dnsmasq from starting, and with it the network: `virsh net-start` fails
with `Address already in use`. Bind the host one to specific interfaces (for
dnsmasq, `bind-interfaces` with `interface=` or `listen-address=`).
systemd-resolved listens on `127.0.0.53` only and does not conflict.

**Forwarding is off:**

```bash
sysctl net.ipv4.ip_forward           # must be 1
```

Starting a NAT network sets it to 1; something that resets sysctls later (a
`sysctl --system` with a file that sets 0) turns it off again.

**Firewall.** libvirt inserts its own rules. Since libvirt 10 they live in their own
nftables table, `libvirt_network`; older versions add iptables chains. Anything that
flushes the whole ruleset (`nft flush ruleset`, an iptables restore) removes them:

```bash
sudo systemctl restart virtnetworkd     # libvirtd on older systems
```

That regenerates the rules of every active network.

> [!note] Restart the daemon
> With the nftables backend, after a flush, `virsh net-destroy default && virsh
> net-start default` is not enough: libvirt still believes its table exists, and
> `net-start` fails with `Failed to apply firewall command`. Restarting the network
> daemon rebuilds the table.

See [[networking/nftables]] and [[networking/iptables]].

> [!warning] Bridged networking over Wi-Fi cannot work
> 802.11 will not forward frames whose source MAC is not the associated station, so a
> bridged VM on wireless silently receives nothing. Use NAT on laptops. This is a
> protocol limitation, not a configuration error.

## Boot fails, or the guest drops to a rescue shell

```bash
virsh console web-01
cat /var/log/libvirt/qemu/web-01.log
```

Common causes:

- **Changed machine type or disk bus.** The guest's initramfs has no driver for the
  new controller, or `/etc/fstab` references a device name that moved — `/dev/sda`
  became `/dev/vda` when you switched to virtio. Use UUIDs in `fstab`; see
  [[linux/storage/partitioning]].
- **UEFI VM lost its NVRAM.** The variable store in `/var/lib/libvirt/qemu/nvram/`
  holds the boot entries. Losing it means firmware with nothing to boot.
- **`virsh undefine --keep-nvram`** leaves the store behind. A new VM with the
  same name reuses that file, with the old VM's boot entries. Plain `virsh undefine`
  refuses a UEFI VM; see [[virtualization/kvm/usage]].

## `error: unsupported configuration`

libvirt rejected the XML. The message names the feature, but not always usefully.

```bash
virsh domcapabilities            # what this host actually supports
virsh capabilities
```

Frequent triggers: a machine type the installed QEMU does not have, a CPU model the
host cannot provide, or `host-passthrough` on a migration target with a different CPU.

## PCI passthrough fails

```bash
dmesg | grep -i -e DMAR -e IOMMU
lspci -nnk -d 10de:2204
```

- **No IOMMU messages** — on Intel, `intel_iommu=on` is missing from the kernel
  command line. On AMD, the IOMMU is off in the firmware (BIOS/UEFI) settings.
- **`Kernel driver in use: nvidia`** — the host driver claimed the device before
  `vfio-pci`. Blacklist it and rebuild the initramfs.
- **`group is not viable`** — other devices in the IOMMU group are not bound to
  `vfio-pci`. All of them must be. See [[virtualization/kvm/advanced]].

## The host runs out of memory

```bash
virsh list --all --name | while read -r vm; do
  [ -n "$vm" ] || continue
  echo "$vm: $(virsh dominfo "$vm" | awk '/Max memory/{print $3}') KiB"
done
free -h
grep Huge /proc/meminfo
```

Two usual causes: overcommitted VMs all becoming busy at once, or hugepages reserved
and unused — the host cannot use them for anything else, so `free` shows memory that
is not actually available.

## Disk image grows without bound

```bash
qemu-img info -U /var/lib/libvirt/images/web-01.qcow2
qemu-img check -U /var/lib/libvirt/images/web-01.qcow2
```

QEMU locks the images of a running VM. Without `-U` (`--force-share`), `qemu-img`
refuses them with `Failed to get shared "write" lock`. With `-U` it reads anyway,
and a running VM may change the data while it reads: trust `check` results only on
a stopped VM.

Thin-provisioned qcow2 grows as the guest writes and never shrinks unless TRIM is
passed through:

```xml
<driver name='qemu' type='qcow2' discard='unmap'/>
```

With that set, `fstrim` in the guest reclaims host space. Also check for accumulated
snapshots — `virsh snapshot-list web-01`.

## Health check script

```bash
#!/bin/bash
echo "== libvirt ==";   systemctl is-active virtqemud.socket libvirtd
echo "== kvm ==";       [ -e /dev/kvm ] && echo present || echo "MISSING"
echo "== validate ==";  virt-host-validate 2>&1 | grep -v PASS || echo "all pass"
echo "== domains ==";   virsh list --all
echo "== networks =="; virsh net-list --all
echo "== pools ==";     virsh pool-list --all
echo "== errors ==";    journalctl -u virtqemud -u libvirtd -p err -n 20 --no-pager
```

## Where to go next

- [[virtualization/kvm/basics]] — configuration that avoids most of this
- [[virtualization/kvm/advanced]] — the tuning that causes the rest
- [[security/selinux]] — the labelling behind the permission failures

<!-- uplink -->
Part of [[virtualization/kvm/index|KVM and QEMU]].
