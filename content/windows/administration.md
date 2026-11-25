---
title: Windows administration
description: Transferring a Windows licence, creating symbolic links, and cleaning up or repairing the component store
tags: [windows, licensing, dism, troubleshooting]
type: howto
status: complete
---

# Windows administration

Notes for managing a Windows server.

> [!note] Not tested locally
> These commands need a Windows host. The test harness runs Linux containers only.

## Transferring a Windows licence

### Uninstall the licence on the source machine

Open an administrator command prompt and get the Activation ID associated with the
product key:

```powershell
slmgr /dlv
```

Uninstall the product key, using the Activation ID noted above:

```powershell
slmgr /upk <activation-id>
```

Clear the product key from the registry, so it cannot be recovered from the machine:

```powershell
slmgr /cpky
```

Finally reset the machine's licensing state:

```powershell
slmgr /rearm
```

### Install the licence on the destination machine

Open an administrator command prompt and install the **product key** — the 25
character `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX` string, not the Activation ID:

```powershell
slmgr /ipk XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
```

> [!warning] `/upk` and `/ipk` take different values
> `/upk` takes the **Activation ID** reported by `/dlv` (a GUID-like value), while
> `/ipk` takes the **product key** in 5×5 format. Passing an Activation ID to `/ipk`
> fails with an invalid product key error.

Activate Windows:

```powershell
slmgr /ato
```

### Tips

Start telephone activation:

```powershell
slui 4
```

## Symbolic links

```batch
mklink /d <link> <target>
```

The **link** — the new name you are creating — comes first, and the **target** it
points at second. So to make `C:\data` point at `D:\storage\data`:

```batch
mklink /d C:\data D:\storage\data
```

> [!warning] Link first, target second
> `mklink` follows the same order as its `/?` help: link first, target second.
> `mklink /d source destination` is the wrong way round, and produces a link named
> after the target.

| Flag | Creates |
| --- | --- |
| *(none)* | file symbolic link |
| `/d` | directory symbolic link |
| `/h` | hard link (file, same volume only) |
| `/j` | directory junction |

This works for network shares too, though a symbolic link to a UNC path requires
remote-to-remote symlink evaluation to be enabled
(`fsutil behavior set SymlinkEvaluation R2R:1`).

## Cleaning up after updates and Service Packs

If `C:\Windows\WinSxS` has grown considerably after a Service Pack or major
update, you can reclaim space:

```batch
dism /online /cleanup-image /spsuperseded
```

On Windows 8 / Server 2012 and later, the more general form is:

```batch
dism /online /cleanup-image /startcomponentcleanup
```

Adding `/resetbase` also removes all superseded component versions, reclaiming the
most space:

```batch
dism /online /cleanup-image /startcomponentcleanup /resetbase
```

> [!warning] `/resetbase` is irreversible
> It makes every currently installed update permanent — you can no longer uninstall
> any of them, and Service Packs can no longer be removed. Do not run it on a
> machine you may need to roll back.

### What WinSxS actually is

WinSxS is the **component store**: the authoritative copy of every Windows
component, in every version currently installed. The reason it looks enormous is
that most of what appears to live in `System32` and elsewhere is **hard-linked**
into WinSxS rather than duplicated — so `dir` and Explorer count the same bytes
twice, and WinSxS is much smaller on disk than it reports.

That is also why you must never delete anything from it by hand: you would be
deleting the live files that the rest of the OS points at. Use DISM, which
understands the hard links and the servicing metadata.

To see the real figure:

```batch
dism /online /cleanup-image /analyzecomponentstore
```

> [!note] WinSxS is the component store
> Side-by-side assembly was the original 2001 purpose of the name, but since Vista
> the directory is the servicing component store, and its contents are hard links,
> not clones of DLLs.

## Checking and repairing the image

Three DISM operations, cheapest first:

```batch
Dism /Online /Cleanup-Image /CheckHealth
```

A quick check that only reports corruption already recorded in the servicing logs.
It scans nothing itself.

```batch
Dism /Online /Cleanup-Image /ScanHealth
```

A full scan of the component store for corruption. Slower, and still read-only.

```batch
Dism /Online /Cleanup-Image /RestoreHealth
```

Repairs what it finds, pulling replacement files from Windows Update — or from a
local source with `/Source:` if the machine is offline.

> [!note] `sfc /scannow`
> `sfc` has no `/CheckHealth` switch: its equivalent is `sfc /scannow`, which checks
> protected system files rather than the component store. Run DISM first, then
> `sfc /scannow`: `sfc` repairs *from* the component store, so it cannot fix anything
> if the store itself is damaged.

## Where to go next

- [[automation/ansible/inventory]] — reaching these hosts from Ansible over WinRM:
  the bootstrap script, and the connection variables that decide whether you get
  HTTP with Basic auth or HTTPS with Kerberos
- [[virtualization/vmware-powershell]] — PowerCLI, if these are guests rather than
  bare metal

<!-- uplink -->
Part of [[windows/index|Windows]].
