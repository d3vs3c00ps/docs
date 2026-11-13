---
title: The lab installer ISO
description: One generic NixOS installer ISO for every lab VM — SSH on, root login by key only, no ZFS — built in a container by lab.sh and booted once per VM on vfkit
tags: [homelab, nixos, iso, installation, vfkit]
type: lab
status: draft
---

# The lab installer ISO

> [!note] Not tested locally
> The lab runs on a Mac with vfkit. The test harness cannot run it.

Every new VM boots this ISO once. It is the NixOS minimal installer with SSH
turned on and one public key allowed for root. It contains **no host
configuration**: the host comes from the flake, installed by nixos-anywhere. One ISO
therefore serves every machine. Rebuild it only when the installer or the key
changes.

This is the custom ISO from the
[nix.dev tutorial](https://nix.dev/tutorials/nixos/building-bootable-iso-image),
as a flake output. For an ISO that installs one host by itself, see
[[linux/distributions/nixos/automated-install#How the ISO works]].

## The configuration

```nix
# hosts/installer/default.nix
{ lib, modulesPath, ... }:
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  nixpkgs.hostPlatform = "aarch64-linux";
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  networking.hostName = "lab-installer";

  # The lab uses ext4 only; dropping ZFS makes the ISO smaller and silences
  # the boot.zfs.forceImportRoot warning.
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # Key only: the ISO has no root password, so nobody else can log in.
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = lib.mkForce "prohibit-password";
  users.users.root.openssh.authorizedKeys.keys =
    [ (builtins.readFile ../../keys/id_nix_lab.pub) ];
}
```

In `flake.nix` it is **not** built with `mkHost`: it is never installed, so it gets
neither disko nor the common modules.

```nix
installer = nixpkgs.lib.nixosSystem {
  specialArgs = { inherit inputs; };
  modules = [ ./hosts/installer ];
};
```

## Build

```bash
lab/lab.sh iso
```

This runs `nix build .#nixosConfigurations.installer.config.system.build.isoImage`
in the `nixos/nix` container and copies the result to `lab/lab.iso`.
`lab.sh install` builds it again each time, so you rarely run `iso` by hand.

## Boot a VM on it

`lab.sh install <host>` does this for you:

1. It creates a blank disk and starts the VM with the ISO attached.
2. It reads the VM's DHCP lease from `/var/db/dhcpd_leases`, by MAC address.
3. It waits for SSH on that address, then runs nixos-anywhere.

The ISO is attached **read-only**. Two vfkit VMs cannot open the same writable
file (`storage device attachment is invalid`), and the ISO is shared by all hosts.

The installer generates new SSH host keys at every boot. The lab SSH config does not
record them, so you get no "host key changed" warnings.

The second boot has no ISO attached: `lab.sh` restarts the VM from its disk alone.

## Next

[[labs/nixos-homelab/gitea]] — the first host installed from this ISO.

<!-- uplink -->
Part of [[labs/nixos-homelab/index|NixOS home lab]].
