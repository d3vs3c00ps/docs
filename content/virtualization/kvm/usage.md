---
title: Using virsh day to day
description: Lifecycle, console access, snapshots and their traps, cloning, live migration, and editing a running domain
tags: [virtualization, kvm, libvirt, virsh, operations]
type: reference
status: complete
---

# Using virsh day to day

`virsh` is the libvirt CLI. Everything a graphical tool does, it does — and it is what
you will have over SSH.

Set the connection once so you are not surprised by
[[virtualization/kvm/basics|session versus system]]:

```bash
export LIBVIRT_DEFAULT_URI=qemu:///system
```

## Lifecycle

```bash
virsh list --all
virsh start web-01
virsh shutdown web-01           # ACPI request — the guest may ignore it
virsh reboot web-01
virsh destroy web-01            # pull the power. Not a delete
virsh suspend web-01            # pause in RAM
virsh resume web-01
virsh autostart web-01
virsh autostart --disable web-01
```

> [!warning] `virsh destroy` does not delete anything
> It force-stops the domain, the equivalent of holding the power button. The
> definition and disks remain. Deleting is `undefine`, and the disks are separate
> again:
>
> ```bash
> virsh undefine web-01 --remove-all-storage --nvram
> ```
>
> Without `--remove-all-storage` you get orphaned qcow2 files quietly consuming the
> pool. Without `--nvram` (or `--keep-nvram`), `undefine` refuses a UEFI VM outright.
> A VM with snapshots is refused too: delete them first, or add
> `--snapshots-metadata`. With external snapshots, `--remove-all-storage` removes only
> the disks the domain uses now, not the older layers under them.

## Console and display

```bash
virsh console web-01            # serial console; Ctrl+] to detach
virsh domdisplay web-01         # VNC/SPICE URI
virt-viewer web-01
```

Serial console needs the guest to be putting a getty on `ttyS0`. On a systemd guest:

```bash
sudo systemctl enable --now serial-getty@ttyS0.service
```

And in the kernel command line, `console=ttyS0,115200n8`. Doing this at build time is
worth the effort — it is the difference between debugging a broken boot and rebuilding
the VM.

## Information

```bash
virsh dominfo web-01
virsh domstate web-01 --reason      # why it is off
virsh domblklist web-01             # disks
virsh domiflist web-01              # interfaces
virsh domifaddr web-01 --source agent
virsh dumpxml web-01
virsh domstats web-01
```

`virsh domstate --reason` earns its place: "shut off (crashed)" and "shut off
(shutdown)" are very different situations. `virsh destroy` gives "shut off
(destroyed)".

## Resources at runtime

```bash
virsh setmem web-01 4G --live --config
virsh setvcpus web-01 4 --live --config
virsh domblkstat web-01 vda
```

| Flag | Effect |
| --- | --- |
| `--live` | Apply to the running domain now |
| `--config` | Apply to the persistent definition, for next boot |
| both | Now **and** persistently — usually what you want |

`setmem` moves the balloon, so it cannot go above the domain's maximum memory
(`<memory>`). `setvcpus` cannot go above the maximum vCPU count (`<vcpu>`). Both
maximums change only in the persistent definition, and take effect at the next
boot:

```bash
virsh setmaxmem web-01 8G --config
virsh setvcpus web-01 8 --maximum --config
```

After that restart, the live commands above work. The guest must online the new
vCPUs, which most modern guests do automatically.

> [!warning] Correction
> An earlier version said live memory increase needs `<maxMemory>`. `<maxMemory>` is
> for memory hot-plug with DIMM devices. Ballooning up is limited by `<memory>`, set
> with `virsh setmaxmem`.

## Snapshots

```bash
virsh snapshot-create-as web-01 before-upgrade "Pre-upgrade state"
virsh snapshot-list web-01
virsh snapshot-revert web-01 before-upgrade
virsh snapshot-delete web-01 before-upgrade
```

Include memory for a snapshot you can resume into, rather than one that boots:

```bash
virsh snapshot-create-as web-01 snap1 --memspec file=/var/lib/libvirt/images/snap1.mem
```

> [!danger] Snapshots are not backups, and they degrade the VM
> Each snapshot adds a qcow2 layer, and every guest read may traverse the chain. A VM
> with a dozen accumulated snapshots is measurably slower and is one corrupted layer
> away from losing everything — the layers are not independent.
>
> They are a short-lived undo for a risky change, taken minutes before and deleted
> minutes after. For real recovery, back up the disk image or the data inside the
> guest.

For a consistent snapshot of a running VM, freeze the filesystem first — which needs
the [[virtualization/kvm/qemu|guest agent]]:

```bash
virsh domfsfreeze web-01
virsh snapshot-create-as web-01 consistent-snap --disk-only --atomic
virsh domfsthaw web-01
```

Forgetting the thaw leaves the guest's filesystems frozen and the VM apparently hung.

## Cloning

```bash
virsh shutdown web-01
virt-clone --original web-01 --name web-02 \
  --file /var/lib/libvirt/images/web-02.qcow2
```

`virt-clone` copies the disk and generates a new MAC and UUID. It does **not** touch
anything inside the guest, so the clone keeps the original's hostname, SSH host keys
and machine-id. Reset them:

```bash
sudo virt-sysprep -d web-02
```

`virt-sysprep` removes host keys, machine-id, logs, and the persistent network naming
that would otherwise give the clone an unexpected interface name. Skipping it produces
two machines sharing SSH host keys, which is both confusing and a real problem.

## Live migration

```bash
virsh migrate --live --persistent --undefinesource \
  web-01 qemu+ssh://host2/system
```

Requirements: shared storage or `--copy-storage-all`, compatible CPU models, and the
destination able to reach the source. Check compatibility first:

```bash
virsh capabilities | grep -A5 '<cpu>'
virsh domcapabilities
```

A `<cpu mode='host-passthrough'>` domain migrates only to identical hardware. For a
migratable fleet use `host-model` or a named baseline model — see
[[virtualization/kvm/advanced]].

## Editing a domain

```bash
virsh edit web-01
```

Opens the XML in `$EDITOR` and validates on save. Changes apply at next boot; `virsh
edit` does not touch a running domain.

Hot-plug instead, with device XML fragments:

```bash
virsh attach-device web-01 disk.xml --live --config
virsh detach-device web-01 disk.xml --live --config
virsh attach-interface web-01 network default --model virtio --live --config
```

On a `q35` machine, each hot-plugged PCI device needs a free `pcie-root-port`
controller. `virt-install` adds many spare ones. For a short hand-written XML,
libvirt may add only one: the next hot-plug fails with `No more available PCI
slots`. Add `<controller type='pci' model='pcie-root-port'/>` lines to the XML,
one per device you plan to hot-plug.

## Networks and pools

```bash
virsh net-list --all
virsh net-dhcp-leases default
virsh net-edit default

virsh pool-list --all
virsh vol-list default
virsh vol-create-as default data.qcow2 50G --format qcow2
virsh vol-delete data.qcow2 --pool default
```

## Batch and scripting

```bash
virsh list --all --name | while read -r vm; do
  [ -n "$vm" ] || continue
  virsh dominfo "$vm" | grep -E 'Name|State|Used memory'
done
```

`virsh list --name` ends with an empty line. Skip it with `|| continue`: the
shorter `[ -n "$vm" ] && ...` makes the loop exit with status 1, which stops a
script that uses `set -e`.

`virsh -q` suppresses headers, which makes output easier to parse.

## Where to go next

- [[virtualization/kvm/advanced]] — performance tuning and passthrough
- [[virtualization/kvm/troubleshooting]] — when something refuses
- [[virtualization/kubevirt/index|KubeVirt]] — the same VMs, driven by Kubernetes

<!-- uplink -->
Part of [[virtualization/kvm/index|KVM and QEMU]].
