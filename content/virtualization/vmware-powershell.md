---
title: VMware PowerCLI snippets
description: PowerCLI one-liners for bulk snapshot management across a folder of virtual machines
tags: [virtualization, vmware, powershell, powercli, snapshots]
type: reference
status: complete
---

# VMware PowerCLI snippets

PowerCLI is VMware's PowerShell module. Since version 9.0 (2025) Broadcom ships it
as `VCF.PowerCLI` on the PowerShell Gallery; older releases are `VMware.PowerCLI`.
> [!note] Partly tested
> There is no vCenter in the test harness. The test parses every block and checks each
> cmdlet and parameter against the real PowerCLI module. Running the snippets against
> VMs is not tested.

The cmdlets below are the same in both. Install it and connect:

```powershell
Install-Module VCF.PowerCLI -Scope CurrentUser
Connect-VIServer -Server vcenter.example.com
```

## Selecting the virtual machines

List the VMs in the `PROD` folder:

```powershell
$VMs = Get-VM -Location (Get-Folder -Name "PROD")
```

Everything below operates on `$VMs`.

## Snapshotting them

```powershell
New-Snapshot -VM $VMs -Name "os ready" `
    -Description "ready to install application" -Quiesce
```

`-Quiesce` asks VMware Tools to flush the guest file systems first. The snapshot
is then file-system consistent: its file systems are clean when the guest boots
from it.
`-Memory` also saves the running memory, so the VM resumes where it was instead of
booting. The snapshot is much larger. Pick one of the two: the vSphere Client lets
you choose only one, because a memory snapshot does not need a quiesced file system.

> [!note] Crash-consistent or file-system consistent
> A snapshot taken *without* quiescing is crash-consistent; quiescing is what makes it
> file-system consistent.

## Restoring them

```powershell
foreach ($vm in $VMs) {
    Set-VM -VM $vm -Snapshot (Get-Snapshot -VM $vm -Name "os ready") -Confirm:$false
}
```

> [!note] Name, not description
> `Get-Snapshot -Name` matches the snapshot's name (`os ready`), not its description.
> Looking it up by the description returns nothing, and `Set-VM` fails.

## Removing them

```powershell
foreach ($vm in $VMs) {
    Remove-Snapshot -Snapshot (Get-Snapshot -VM $vm -Name "os ready") -Confirm:$false
}
```

Remove snapshots for every VM whose name starts with `leap-`:

```powershell
Get-Snapshot -Name "os ready" -VM leap-* | Remove-Snapshot
```

Remove every snapshot everywhere — with `-WhatIf` so it only reports what it would
do:

```powershell
Get-Snapshot -VM * | Remove-Snapshot -WhatIf
```

> [!warning] Read the `-WhatIf` output first
> Remove `-WhatIf` only when you have read its output: without it, this line deletes
> every snapshot in the environment. PowerShell reads an en-dash (`–`) in front of a
> parameter name as a normal dash, so text copied from a word processor still runs,
> but type a plain hyphen, so that other tools (grep, linters) see the flag.

## Inspecting snapshots

```powershell
Get-VM leap01 | Get-Snapshot |
    Select-Object -Property Name, Description, Created, SizeMB | Format-List *
```

> [!tip] Find snapshots that have been forgotten
> Old snapshots quietly consume datastore capacity and slow the VM down. This finds
> anything older than a week:
>
> ```powershell
> Get-VM | Get-Snapshot | Where-Object { $_.Created -lt (Get-Date).AddDays(-7) } |
>     Select-Object VM, Name, Created, SizeGB
> ```

See [[virtualization/vmware-hardening]] for bulk VM reconfiguration, and
[[storage/raid-and-alua]] for the storage side.

<!-- uplink -->
Part of [[virtualization/index|Virtualisation]].
