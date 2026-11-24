---
title: KVM basics
description: Installing the stack, creating a first VM with virt-install, storage pools, the default network, and what a domain XML contains
tags: [virtualization, kvm, libvirt, installation]
type: howto
status: complete
---

# KVM basics

## Installing

```bash
# openSUSE Leap
sudo zypper install -t pattern kvm_server kvm_tools
# or the individual packages (libvirt-daemon-qemu pulls the QEMU for your CPU):
sudo zypper install libvirt libvirt-daemon-qemu virt-install virt-manager

# RHEL / Rocky / Fedora
sudo dnf install qemu-kvm libvirt virt-install
```

> [!note] Package names
> Leap 16 has no `qemu-kvm` package on ARM64; `libvirt-daemon-qemu` already pulls the
> right QEMU. RHEL 10 and Rocky 10 no longer ship `virt-manager`. Use the web console
> (`cockpit-machines`) there, or install virt-manager on your desktop and connect over
> SSH.

Start libvirt and add yourself to the groups. Current distributions (Leap 16,
RHEL 9 and later, Fedora) run one daemon per driver, started on demand by a socket:
`virtqemud` for VMs, `virtnetworkd` for networks, `virtstoraged` for pools. Older
ones run a single `libvirtd`. Enable one model, not both:

```bash
# modular daemons
for drv in qemu network storage nodedev; do
  sudo systemctl enable --now "virt${drv}d.socket"
done

# or, on an older distribution, the single daemon
sudo systemctl enable --now libvirtd
```

```bash
sudo usermod -aG libvirt,kvm "$USER"
newgrp libvirt          # or log out and back in
```

Verify:

```bash
virt-host-validate
virsh list --all
```

> [!tip] `virsh` connects somewhere different depending on who you are
> As an ordinary user, `virsh` defaults to `qemu:///session` — a per-user hypervisor
> with its own VMs, its own networks, and no access to the system ones. As root it
> uses `qemu:///system`.
>
> A VM you created with `sudo virsh` being invisible to plain `virsh` is this, not a
> lost VM. Be explicit:
>
> ```bash
> export LIBVIRT_DEFAULT_URI=qemu:///system
> virsh --connect qemu:///system list --all
> ```
>
> Use `system` for anything that should start at boot or be shared; `session` is fine
> for a desktop scratch VM.

## Storage pools

libvirt manages disk images in **pools**. libvirt itself creates none. virt-manager
creates a pool named `default`, in `/var/lib/libvirt/images`, the first time it
runs. `virt-install` and `virt-clone` create a pool for each directory you give them
a path in, named after the directory: `images` for `/var/lib/libvirt/images`. On a
host managed with `virsh` alone, define it yourself:

```bash
virsh pool-define-as default dir --target /var/lib/libvirt/images
virsh pool-start default
virsh pool-autostart default
```

```bash
virsh pool-list --all
virsh pool-info default
virsh vol-list default
```

> [!note] The `default` pool
> On a fresh host, `virsh pool-info default` fails until virt-manager or the commands
> above create it.

Creating one on a different filesystem:

```bash
virsh pool-define-as vmstore dir --target /srv/vms
virsh pool-build vmstore
virsh pool-start vmstore
virsh pool-autostart vmstore
```

Pool types include `dir`, `logical` (LVM — see [[linux/storage/lvm]]), `netfs`,
`iscsi` and `rbd`.

## Networks

Out of the box you get `default`: a NAT network on `virbr0`, 192.168.122.0/24, with
DHCP from dnsmasq. It is defined, but not always started or set to autostart.

```bash
virsh net-list --all
virsh net-info default
virsh net-dhcp-leases default        # which VM got which address
```

If it is not running:

```bash
virsh net-start default
virsh net-autostart default
```

| Mode | Behaviour |
| --- | --- |
| **NAT** (`default`) | VMs reach outward; nothing reaches in without forwarding |
| **Bridged** | VMs sit on the physical LAN with their own addresses |
| **Isolated** | VM-to-VM only, no external access |
| **macvtap** | Direct attachment to a physical NIC, lower overhead |

Bridged is what you want for anything server-like. Create the host bridge first — see
[[linux/networking/virtual-interfaces]] — then:

```xml
<interface type='bridge'>
  <source bridge='br0'/>
  <model type='virtio'/>
</interface>
```

> [!warning] A bridge over Wi-Fi does not work
> 802.11 will not forward frames with a source MAC other than the associated
> station's, so bridged VMs on a laptop's wireless interface get no traffic. Use NAT,
> or macvtap in bridge mode with the same caveat. This costs people an afternoon
> regularly.

## Creating a VM

The unattended way, with `virt-install`:

```bash
virt-install \
  --name web-01 \
  --memory 2048 \
  --vcpus 2 \
  --disk path=/var/lib/libvirt/images/web-01.qcow2,size=20,format=qcow2,bus=virtio \
  --os-variant rocky9 \
  --network network=default,model=virtio \
  --graphics none \
  --console pty,target_type=serial \
  --location 'https://download.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/' \
  --extra-args 'console=ttyS0,115200n8 inst.ks=https://example.com/ks.cfg'
```

`--os-variant` matters more than it looks — it selects sensible defaults for
devices, clock and drivers. List them with `osinfo-query os`. Recent `virt-install`
refuses to run without it, unless it can detect the OS from the install media.

`--graphics none` with a `pty` console attaches your terminal to the VM's serial
console. Add `--noautoconsole` to return at once, for example in a script. For a
Rocky 9 network install, `virt-install` raises `--memory` to 3072 MiB, the installer's
minimum, and says so in a warning.

From an existing cloud image, which is faster and what you usually want:

```bash
qemu-img create -f qcow2 -F qcow2 \
  -b /var/lib/libvirt/images/rocky9-base.qcow2 \
  /var/lib/libvirt/images/web-01.qcow2 20G

virt-install --name web-01 --memory 2048 --vcpus 2 \
  --disk path=/var/lib/libvirt/images/web-01.qcow2,bus=virtio \
  --import --os-variant rocky9 \
  --network network=default,model=virtio \
  --cloud-init user-data=./user-data.yaml \
  --graphics none --console pty,target_type=serial
```

> [!important] Always use `virtio` for disk and network
> With `--osinfo generic` (no known OS), `virt-install` falls back to emulated IDE
> and e1000, which are slow — often several times slower on disk. `virtio` drivers
> talk to the hypervisor directly rather than pretending to be real hardware. Every modern guest has them;
> Windows needs the virtio-win driver ISO at install time.

## Domain XML

A VM ("domain") is defined by XML. This is the source of truth:

```bash
virsh dumpxml web-01
virsh edit web-01              # edit and validate in $EDITOR
```

The parts you will touch:

```xml
<domain type='kvm'>
  <name>web-01</name>
  <memory unit='KiB'>2097152</memory>
  <vcpu placement='static'>2</vcpu>
  <os>
    <type arch='x86_64' machine='pc-q35-8.0'>hvm</type>
    <boot dev='hd'/>
  </os>
  <cpu mode='host-passthrough' check='none'/>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native' discard='unmap'/>
      <source file='/var/lib/libvirt/images/web-01.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <console type='pty'><target type='serial' port='0'/></console>
  </devices>
</domain>
```

`<domain type='kvm'>` is worth checking on any VM that feels slow — `type='qemu'`
means no hardware acceleration. `virt-install` picks `qemu`, with at most a one-line
warning, when `/dev/kvm` is missing; see [[virtualization/kvm/introduction]].

## First commands

```bash
virsh list --all
virsh start web-01
virsh console web-01           # Ctrl+] to detach
virsh shutdown web-01          # ACPI, graceful
virsh destroy web-01           # power off, abrupt
virsh autostart web-01
```

## Where to go next

- [[virtualization/kvm/usage]] — `virsh` in daily use, snapshots, cloning
- [[virtualization/kvm/qemu]] — the layer underneath
- [[virtualization/kvm/advanced]] — performance and passthrough
- [[virtualization/kvm/troubleshooting]] — when it does not start

<!-- uplink -->
Part of [[virtualization/kvm/index|KVM and QEMU]].
