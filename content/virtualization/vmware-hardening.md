---
title: VMware VM hardening
description: Bulk-applying VMX security options to every virtual machine with PowerCLI
tags: [virtualization, vmware, powershell, powercli, security, hardening]
type: howto
status: complete
---

# VMware VM hardening

This PowerCLI script applies a set of VMX security options to every non-template
virtual machine in one run.

> [!warning] This dates from vSphere 5.1
> Treat it as a pattern rather than a current baseline. Many of these
> `isolation.tools.*` settings became defaults, were renamed, or were removed in
> later releases, and applying an unknown `extraConfig` key is silently accepted —
> so a stale list gives false confidence. Check the current
> [VMware Cloud Foundation Security Configuration Guide](https://github.com/vmware/vcf-security-and-compliance-guidelines/tree/main/security-configuration-hardening-guide)
> for the release you run and adjust the hash table below. The old
> `core.vmware.com` link now redirects to a generic page.

> [!note] Partly tested
> There is no ESXi or vCenter in the test harness. The test parses the script, checks
> every cmdlet and parameter against the real PowerCLI module, and runs it against a
> stub that records the settings it would write. Whether ESXi applies them is not
> tested.

> [!important] A full power cycle is required
> These settings are read when the VM's process is created on the ESXi host, so the
> guest must be **shut down and started again**. A reboot from inside the guest is
> not enough.

## Running it

Connect to vCenter:

```powershell
Connect-VIServer -Server vcenter.example.com
```

Save the script below as `harden-vm.ps1` and run it:

```powershell
.\harden-vm.ps1
```

> [!note] It does not take pipeline input
> The original notes invoked it as
> `Get-Cluster cluster-name | Get-VM | .\hardenningVM51.ps1`, but the script finds
> its own targets with `Get-View` and ignores anything piped in — so that command
> silently hardens *every* VM in vCenter, not just the named cluster. To scope it,
> give `Get-View` a search root:
>
> ```powershell
> $VMs2Update = Get-View -ViewType VirtualMachine -Property Name `
>     -Filter @{ "Config.Template" = "false" } `
>     -SearchRoot (Get-Cluster "cluster-name").ExtensionData.MoRef
> ```

> [!warning] Correction
> An earlier version said to add a `-Location` filter to `Get-View`. `Get-View` has
> no `-Location` parameter; the parameter that limits the search is `-SearchRoot`.

## The script

```powershell
$SecurityOptions = @{
    "RemoteDisplay.maxConnections"                     = "1";
    "tools.setInfo.sizeLimit"                          = "1048576";
    "floppy0.present"                                  = "false";
    "parallel0.present"                                = "false";
    "serial0.present"                                  = "false";
    "usb.present"                                      = "false";
    "isolation.device.connectable.disable"             = "true";
    "isolation.device.edit.disable"                    = "true";
    "isolation.tools.copy.disable"                     = "true";
    "isolation.tools.paste.disable"                    = "true";
    "isolation.tools.dnd.disable"                      = "true";
    "isolation.tools.setGUIOptions.enable"             = "false";
    "isolation.tools.hgfsServerSet.disable"            = "true";
    "isolation.monitor.control.disable"                = "true";
    "isolation.tools.ghi.autologon.disable"            = "true";
    "isolation.bios.bbs.disable"                       = "true";
    "isolation.tools.getCreds.disable"                 = "true";
    "isolation.tools.ghi.launchmenu.change"            = "true";
    "isolation.tools.memSchedFakeSampleStats.disable"  = "true";
    "isolation.tools.ghi.protocolhandler.info.disable" = "true";
    "isolation.ghi.host.shellAction.disable"           = "true";
    "isolation.tools.dispTopoRequest.disable"          = "true";
    "isolation.tools.trashFolderState.disable"         = "true";
    "isolation.tools.ghi.trayicon.disable"             = "true";
    "isolation.tools.unity.disable"                    = "true";
    "isolation.tools.unityInterlockOperation.disable"  = "true";
    "isolation.tools.unity.taskbar.disable"            = "true";
    "isolation.tools.unityActive.disable"              = "true";
    "isolation.tools.unity.windowContents.disable"     = "true";
    "isolation.tools.unity.push.update.disable"        = "true";
    "isolation.tools.vmxDnDVersionGet.disable"         = "true";
    "isolation.tools.guestDnDVersionSet.disable"       = "true";
    "isolation.tools.diskShrink.disable"               = "true";
    "isolation.tools.diskWiper.disable"                = "true";
    "isolation.tools.autoInstall.disable"              = "true";
    "isolation.tools.vixMessage.disable"               = "true";
    "tools.guestlib.enableHostInfo"                    = "false";
    "log.rotateSize"                                   = "100000";
    "log.keepOld"                                      = "10"
}

$SecurityConfigurationSpec = New-Object VMware.Vim.VirtualMachineConfigSpec

foreach ($SecurityOption in $SecurityOptions.GetEnumerator()) {
    $SecurityOptionValue       = New-Object VMware.Vim.OptionValue
    $SecurityOptionValue.Key   = $SecurityOption.Key
    $SecurityOptionValue.Value = $SecurityOption.Value
    $SecurityConfigurationSpec.ExtraConfig += $SecurityOptionValue
}

# Find the VMs that are not templates
$VMs2Update = Get-View -ViewType VirtualMachine -Property Name `
    -Filter @{ "Config.Template" = "false" }

# Apply the changes
foreach ($VM in $VMs2Update) {
    $VM.ReconfigVM_Task($SecurityConfigurationSpec)
    Write-Output "$($VM.Name) - changed"
}
```

> [!warning] Device placeholders in the original
> The original hash table contained literal placeholders — `floppyX.present`,
> `ideX:Y.present`, `parallelX.present`, `serialX.present`. Those are not valid keys:
> `X` and `Y` stand for a device index you must substitute. They have been replaced
> with `floppy0`, `parallel0` and `serial0` above. `ideX:Y.present` was dropped
> entirely — disabling IDE controllers wholesale breaks VMs that boot from them; if
> you want to prevent CD-ROM connection, `isolation.device.connectable.disable`
> already covers it.

## What the key settings do

| Setting | Effect |
| --- | --- |
| `RemoteDisplay.maxConnections` | limits simultaneous console connections, so a second viewer cannot silently watch a session |
| `tools.setInfo.sizeLimit` | caps the size of guest-set VMX data, preventing a guest filling the datastore via the VMX file |
| `floppy0/parallel0/serial0/usb.present` | removes unused virtual hardware, shrinking the attack surface |
| `isolation.device.connectable.disable` | stops a guest user connecting or disconnecting devices |
| `isolation.tools.copy/paste/dnd.disable` | disables clipboard and drag-and-drop between guest and console |
| `isolation.tools.diskShrink.disable` | prevents a guest triggering disk shrink, which can be used as a denial of service |
| `tools.guestlib.enableHostInfo` | stops the guest reading host performance data |
| `log.rotateSize` / `log.keepOld` | bounds `vmware.log` growth, so log volume cannot fill the datastore |

## Verifying afterwards

Read a setting back to confirm it applied:

```powershell
Get-VM | Get-AdvancedSetting -Name "isolation.tools.copy.disable" |
    Select-Object Entity, Name, Value
```

`Get-AdvancedSetting` / `Set-AdvancedSetting` is the modern PowerCLI way to do all of
this, and is considerably less code than the `VirtualMachineConfigSpec` approach
above:

```powershell
Get-VM | New-AdvancedSetting -Name "isolation.tools.copy.disable" `
    -Value "true" -Confirm:$false -Force
```

See [[virtualization/vmware-powershell]] for more PowerCLI.

<!-- uplink -->
Part of [[virtualization/index|Virtualisation]].
