---
title: RAID and ALUA
description: RAID levels, storage array anatomy, LUNs and initiators, and asymmetric LUN access with ALUA on VMware
tags: [storage, raid, san, alua, vmware, fibre-channel, iscsi]
type: concept
status: complete
---

# RAID and ALUA

> [!note] Not tested locally
> Concept note about SAN arrays, LUNs and ALUA on VMware. It needs storage hardware
> and vSphere, so nothing here runs in the test harness.

## Storage refresher

### RAID

RAID stands for **Redundant Array of Independent Disks** — originally *Inexpensive*
Disks, in the 1988 Berkeley paper that named it. The commonly used levels:

| Level | Description |
| --- | --- |
| **RAID 0** | Striping with no redundancy, for high performance. Data is spread evenly across all disks. Losing any one disk loses everything. |
| **RAID 1** | Mirroring for both reads and writes. Data is duplicated on every disk in the set. |
| **RAID 5** | Striping with parity distributed across all disks. The good financial compromise between redundancy and capacity. Tolerates one disk failure. |
| **RAID 6** | Striping with **two** independent parity blocks, both distributed across the set. Tolerates two simultaneous disk failures. |
| **RAID DP** | NetApp's variant of the RAID 6 idea: two parity blocks computed with different algorithms, written to two *dedicated* disks rather than distributed. |
| **RAID 0+1** | A mirror of RAID 0 stripes. Very fast, but expensive in disks. |
| **RAID 10** | A stripe of RAID 1 mirrors — generally preferred over 0+1, because rebuilding affects only one mirror pair rather than a whole stripe. |

> [!note] RAID 6 and RAID DP
> RAID 6 is *dual* parity, and both parity blocks are distributed across all members.
> The fixed-disk variant is RAID DP, listed separately.

> [!warning] RAID 5 and large drives
> Rebuild time scales with disk size, and during a rebuild the array has no
> redundancy while reading every block of every remaining disk. With multi-terabyte
> drives the probability of a second failure or an unrecoverable read error during
> that window is no longer negligible, which is why RAID 6 or RAID 10 is the
> conventional choice above a few terabytes.

### The controller

A controller is the board that drives a set of physical disks and binds them into
a RAID set. That set then holds one or more logical volumes called **arrays**. It
follows that one disk shelf can contain pieces of several arrays at different RAID
levels — RAID 5 for the first array, RAID 6 for the second, and so on.

Sizing a storage array is then a balance between the number of disks — the
**spindles** — the number of controllers, and the performance, safety and rebuild
time you expect. More spindles means better performance, because each disk handles
less data per I/O operation.

Conversely, every disk in a set shares the total bandwidth of the controller
driving them. A 4 Gb/s Fibre Channel controller gives roughly 400 MB/s of usable
throughput — 8b/10b line encoding costs 20% — which is about seven SATA II disks at
65 MB/s accessed simultaneously. Access at full rate like this is described as
*non-blocking*.

For the last couple of decades controllers have traditionally lived in a SAN or NAS
head: a server running an operating system. At EMC that OS was called FLARE; at
NetApp it is Data ONTAP, which is closer to a BSD Unix. The operating system driving
the whole array is responsible for its behaviour and includes ancillary hardware and
software functions such as memory cache and replication. This is called
**monolithic** storage.

There are exceptions, called **modular** storage — Pillar Data Axiom, IBM XIV,
EMC VMAX — where the functions are spread across the array's components. The
controllers are built into the disk shelves themselves, making them entirely
non-blocking.

### LUN

An array is shared on the storage network under a unique number called a **LUN**
(Logical Unit Number).

### Initiator

The port on a machine that seeks access to a LUN, over iSCSI, Fibre Channel or
FCoE (Fibre Channel over Ethernet).

### Target and Target Port Group

The combination of one or more physical ports and the descriptor — the logical name
— you connect to in order to reach a LUN.

In iSCSI the descriptor takes the iSCSI Qualified Name (iqn) form:

```text
iqn.1998-01.com.vmware:ESX4-1db07213
```

In Fibre Channel it is a World Wide Name, eight bytes:

```text
22:00:00:0b:08:45:18:3c
```

## ALUA

Redundant controllers, and life gets more complicated.

Most storage arrays include redundant controllers to drive their LUNs — EMC
CLARiiON, NetApp, IBM DS and NS, HP EVA, Pillar Data Axiom, Dell EqualLogic. But
although the controllers are redundant and administered identically, the access
characteristics of each controller's ports to a given LUN can differ, notably in
performance. At any given moment one controller has faster access to the LUN than
the other; that is the **optimised path**. This asymmetric mode of access to a LUN
is what ALUA — **Asymmetric Logical Unit Access** — describes.

Up to VMware ESX 3.5, ALUA was not natively supported in the hypervisor. You could
only configure Fixed path, Most Recently Used, or alternating Round Robin. The last
two could produce non-optimised access to LUNs. It was worth getting everyone to
agree, on pain of `LUN Non Optimal Access Path` messages that could escalate to a
reboot of the controller concerned — with the attendant inconvenience to the VMs
depending on it: black screens, frozen machines, damaged VMDKs, and a queue of
users at your desk whose systems you have just cut off.

Only an add-on plug-in such as EMC PowerPath could avoid this, by getting the ESX
host and the storage to agree on the optimal path to use.

vSphere implements two APIs natively:

| API | Responsibility |
| --- | --- |
| **SATP** — Storage Array Type Plug-in | failover behaviour |
| **PSP** — Path Selection Plug-in | load balancing across paths |

Together they remove the need to manage optimised paths by hand.

## Some CLI

These APIs are reachable from the vSphere console.

> [!warning] These are ESX 4-era commands
> `esxcli nmp ...` was replaced by `esxcli storage nmp ...` in ESXi 5.0. The modern
> equivalents are given after each block.

List the SATP claim rules the host knows about:

```console
[root@esxi ~]# esxcli nmp satp listrules

Name              Vendor   Model     Claim Options  Description
VMW_SATP_ALUA_CX  DGC                tpgs_on        CLARiiON array in ALUA mode
VMW_SATP_EVA               HSV111    tpgs_off       active/active EVA 5000 GL
VMW_SATP_EVA               HSV200    tpgs_off       active/active EVA 4000/6000 XL
VMW_SATP_EVA               HSV210    tpgs_off       active/active EVA 8000/8100 XL
VMW_SATP_ALUA     NETAPP             tpgs_on        NetApp with ALUA
VMW_SATP_ALUA     HP       ^MSA2*    tpgs_on        HP MSA A/A with ALUA
VMW_SATP_ALUA     Pillar             tpgs_on        active/active Ctl Pillar Axiom ALUA Support
```

Modern form:

```bash
esxcli storage nmp satp rule list
```

`tpgs_on` means the SATP is only claimed if Target Port Group Support — the SCSI
feature that reports which paths are optimised — is enabled on the storage.

List the PSPs:

```console
[root@esxi ~]# esxcli nmp psp list

Name           Description
VMW_PSP_MRU    Most Recently Used Path Selection
VMW_PSP_RR     Round Robin Path Selection
VMW_PSP_FIXED  Fixed Path Selection
```

Modern form:

```bash
esxcli storage nmp psp list
```

Make Round Robin the default for ALUA arrays:

```bash
# legacy
esxcli nmp satp setdefaultpsp --psp="VMW_PSP_RR" --satp="VMW_SATP_ALUA"

# modern
esxcli storage nmp satp set --default-psp=VMW_PSP_RR --satp=VMW_SATP_ALUA
```

And add a rule for storage not listed by default:

```bash
# legacy
esxcli nmp satp addrule --vendor="Overland" --claim-option="tpgs_on" \
  --satp="VMW_SATP_ALUA" --description="Overland Snap Server 620"

# modern
esxcli storage nmp satp rule add --vendor="Overland" --claim-option="tpgs_on" \
  --satp="VMW_SATP_ALUA" --description="Overland Snap Server 620"
```

## Where to go next

Following one LUN upwards through the stack:

- [[linux/storage/lvm]] — the guest-side view, once the LUN is a block device
- [[security/boot-integrity/luks]] — encrypting what sits on top of it, and why the
  multipath device rather than a single path is what you want to hand to `cryptsetup`
- [[kubernetes/storage/pv-pvc-sc]] — how that block device becomes a
  `PersistentVolume`, and why `ReadWriteMany` is a property of the filesystem above
  rather than of the array below
- [[linux/storage/disk-io-performance]] — measuring it, and why `%util` lies on
  anything with a queue depth above one
- vmware-powershell — driving vSphere from PowerCLI

<!-- uplink -->
Part of [[storage/index|Storage]].
