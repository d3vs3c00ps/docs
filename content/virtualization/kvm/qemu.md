---
title: QEMU
description: The emulation layer under KVM — machine types, disk image formats, qemu-img, running QEMU directly, and cross-architecture emulation
tags: [virtualization, qemu, kvm, storage]
type: concept
status: complete
---

# QEMU

[QEMU](https://www.qemu.org/) is a machine emulator. Under KVM it does everything that
is **not** the CPU: disks, network cards, USB controllers, graphics, firmware. One
QEMU process per running VM.

```bash
ps aux | grep qemu-system-x86_64
```

That command on a virtualisation host is illuminating — every VM libvirt manages is a
long `qemu-system-x86_64` command line, and libvirt is essentially a program that
builds those command lines from XML.

## QEMU with and without KVM

QEMU can run entirely in software, translating guest instructions with **TCG**:

```bash
qemu-system-x86_64 -m 2048 -hda disk.qcow2                  # TCG — slow
qemu-system-x86_64 -enable-kvm -m 2048 -hda disk.qcow2      # accelerated
qemu-system-x86_64 -accel kvm -cpu host -m 2048 ...         # modern spelling
```

TCG is many times slower. It is what you fall back to without `/dev/kvm`,
and the reason a VM in a non-nested cloud instance crawls — see
[[virtualization/kvm/introduction]].

Its legitimate use is **cross-architecture** emulation, where there is no hardware
acceleration to be had:

```bash
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2048 ...
```

That is also what powers multi-architecture container builds:

```bash
docker run --privileged --rm tonistiigi/binfmt --install all
docker buildx build --platform linux/amd64,linux/arm64 -t myapp:1.0 .
```

`binfmt_misc` hands ARM binaries to QEMU's user-mode emulator (`qemu-aarch64`)
transparently. That is TCG too, for one process instead of a whole machine. Slow,
but it means one machine can build for everything.

## Machine types

The virtual motherboard. It pins the set and layout of emulated devices:

```bash
qemu-system-x86_64 -machine help
```

| Type | Notes |
| --- | --- |
| `pc-i440fx-*` | The legacy PCI chipset. Wide compatibility, no native PCIe |
| `pc-q35-*` | Modern PCIe chipset. The right default, and required for sensible passthrough |
| `virt` | For ARM and RISC-V. No legacy hardware at all |
| `microvm` | Minimal, for very fast boots — the Firecracker-style use case |

> [!important] Machine types are versioned, and that is deliberate
> `pc-q35-8.0` freezes the exact hardware layout of QEMU 8.0. A guest sees identical
> hardware after a QEMU upgrade, which is what makes **live migration** and stable
> Windows licensing possible.
>
> The corollary: never run a long-lived VM on the bare alias `q35`. It resolves to
> whatever the installed QEMU considers current, so an upgrade silently changes the
> guest's virtual hardware — which can strand a Windows activation or confuse a
> guest's device naming. This bites with hand-written `qemu-system-*` command lines.
> libvirt replaces the alias with the versioned name (`pc-q35-10.0`, say) when you
> define the domain; keep that value when you edit the XML.

Changing machine type on an existing VM is a hardware transplant. Expect the guest to
re-detect devices, and Windows to want reactivating.

## Disk image formats

```bash
qemu-img info disk.qcow2
```

| Format | Notes |
| --- | --- |
| **qcow2** | The default. Thin provisioning, snapshots, compression, backing files |
| **raw** | A plain block image. Fastest, no features, easy to mount |
| **vmdk**, **vdi**, **vhdx** | VMware, VirtualBox, Hyper-V — for conversion |

```bash
qemu-img create -f qcow2 disk.qcow2 20G
qemu-img convert -O qcow2 disk.vmdk disk.qcow2
qemu-img resize disk.qcow2 +10G
qemu-img check disk.qcow2
```

`resize` grows the **disk**, not the filesystem — the guest still needs `growpart` and
`resize2fs` or `xfs_growfs`. See [[linux/storage/partitioning]].

### Backing files

A thin copy-on-write overlay over a shared base image:

```bash
qemu-img create -f qcow2 -F qcow2 -b base.qcow2 vm1.qcow2 20G
```

Twenty VMs from one golden image, each storing only its differences. This is how lab
environments get built quickly.

> [!danger] Modifying a backing file corrupts every overlay on top of it
> The overlays store only differences and assume the base never changes. Booting the
> base image "just to check something" writes to it and silently corrupts every child.
>
> Make it read-only and treat it as immutable:
>
> ```bash
> chmod 444 base.qcow2
> ```
>
> `qemu-img rebase` is the supported way to change what an overlay points at.

Flatten an overlay into a standalone image when you want to move it:

```bash
qemu-img convert -O qcow2 vm1.qcow2 vm1-standalone.qcow2
```

## Performance-relevant disk options

In the domain XML:

```xml
<driver name='qemu' type='qcow2' cache='none' io='native' discard='unmap'/>
```

| Option | Effect |
| --- | --- |
| `cache='none'` | Bypass the host page cache. Correct for most workloads — avoids double caching |
| `cache='writeback'` | Fast, but a host crash can lose guest writes |
| `io='native'` | Linux AIO. Needs `cache='none'` or `directsync`: libvirt refuses it with a host cache |
| `io='threads'` | Thread pool; better with `cache='writeback'` |
| `discard='unmap'` | Guest TRIM propagates, so deleting files actually reclaims host space |

`discard='unmap'` is the one people forget, and it is why a thin-provisioned qcow2
grows forever and never shrinks.

## Guest agent

```bash
# in the guest
sudo dnf install qemu-guest-agent && sudo systemctl enable --now qemu-guest-agent
```

```xml
<channel type='unix'>
  <target type='virtio' name='org.qemu.guest_agent.0'/>
</channel>
```

`virt-install` adds this channel for you. Add it by hand only to a domain written
without it.

It enables filesystem freeze for consistent snapshots, graceful shutdown that actually
works, and reporting guest IP addresses to the host:

```bash
virsh domifaddr web-01 --source agent
virsh domfsfreeze web-01
```

Without the agent, `virsh shutdown` relies on ACPI, which a guest can ignore.

## Running QEMU directly

Useful for a quick test or a live ISO, without defining anything in libvirt:

```bash
qemu-system-x86_64 \
  -enable-kvm \
  -m 2048 -smp 2 \
  -cpu host \
  -drive file=disk.qcow2,if=virtio,cache=none \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=n0 \
  -nographic
```

`-netdev user` is unprivileged SLIRP networking with port forwarding — no bridge, no
root. Slow, but perfect for `ssh -p 2222 localhost`.

## Where to go next

- [[virtualization/kvm/advanced]] — CPU pinning, hugepages, passthrough
- [[virtualization/kvm/usage]] — managing all this through libvirt
- [[virtualization/kvm/troubleshooting]] — when QEMU refuses to start

<!-- uplink -->
Part of [[virtualization/kvm/index|KVM and QEMU]].
