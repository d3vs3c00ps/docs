---
title: Testing NixOS configurations
description: Checking a configuration before it reaches a machine — build and dry-activate, throwaway VMs with build-vm, automated NixOS VM tests in nix flake check, and building ISO and disk images
tags: [linux, nixos, nix, testing, virtualization]
type: howto
status: complete
---

# Testing NixOS configurations

With Packer, the image is the artifact: you build it, test it, then deploy it. On
NixOS, the **flake is the artifact**. The same commit gives the same system on a VM,
on your laptop or on a server. So you do not test an image and reinstall — you test
the configuration, then switch the real machine to it.

Checked against NixOS 26.05, where `nixos-rebuild` is the rewritten Python version
(`nixos-rebuild-ng`).

## The test ladder

From cheapest to most realistic:

| Step | Command | Proves |
| --- | --- | --- |
| Evaluate and check | `nix flake check` | The config evaluates, the checks pass |
| Build | `nixos-rebuild build --flake .#host` | Every package and file can be produced |
| Preview activation | `sudo nixos-rebuild dry-activate --flake .#host` | Which services would restart |
| Throwaway VM | `nixos-rebuild build-vm --flake .#host` | It boots and you can use it |
| Automated VM test | `nix flake check` with a `runNixOSTest` check | It boots *and* behaves as expected, every time |
| Try on the real machine | `sudo nixos-rebuild test --flake .#host` | It works here; a reboot undoes it |
| Commit to it | `sudo nixos-rebuild switch --flake .#host` | — |
| Undo | `sudo nixos-rebuild switch --rollback` | — |

`test` and `switch --rollback` are covered in [[linux/distributions/nixos/basics]].

## Throwaway VMs with `build-vm`

```bash
nixos-rebuild build-vm --flake .#workstation
./result/bin/run-workstation-vm
```

This builds a QEMU VM from your exact configuration, desktop included. It starts in
seconds because it shares the host's `/nix/store` instead of copying it. It is the
right tool to try a Sway or Waybar change — see nixos.

Things to know:

- Your real disks are not used. The VM writes its state to `workstation.qcow2` in the
  current directory. Delete that file to start fresh.
- There is no bootloader in this VM. Use `build-vm-with-bootloader` to test boot
  changes.
- Your users exist with their real settings. Give them a test password for the VM
  only, as below. If a user has `hashedPassword` or `hashedPasswordFile` on the real
  machine, override that one instead (with `lib.mkForce`).

`virtualisation.vmVariant` holds settings that apply **only** to the `build-vm`
output, never to the real machine:

```nix
virtualisation.vmVariant = {
  virtualisation = {
    memorySize = 4096;     # MiB, default 1024
    cores = 4;             # default 1
  };
  users.users.alice.initialPassword = "test";
};
```

`virtualisation.vmVariantWithBootLoader` is the same for `build-vm-with-bootloader`.

## Automated tests with `runNixOSTest`

A NixOS test boots one or more VMs and runs a Python script against them. It is the
`ansible --check` you always wanted: it proves the result works, not only that it
would apply.

```nix
# flake.nix, in outputs
checks.x86_64-linux.ssh =
  let pkgs = nixpkgs.legacyPackages.x86_64-linux;
  in pkgs.testers.runNixOSTest {
    name = "ssh";

    nodes.machine = {
      imports = [ ./modules/hardening.nix ];
      services.openssh.enable = true;
    };

    testScript = ''
      machine.wait_for_unit("sshd.service")
      machine.wait_for_open_port(22)
      machine.succeed("sshd -T | grep -qi '^passwordauthentication no'")
      machine.fail("ss -ltn | grep -q ':80 '")     # nothing listens on port 80
    '';
  };
```

```bash
nix flake check                                  # runs every check
nix build .#checks.x86_64-linux.ssh -L           # one test, with logs
nix run .#checks.x86_64-linux.ssh.driverInteractive   # open a Python shell on the VMs
```

Several nodes in one test can talk to each other over a virtual network — a web
server and a client, a database and its replica. Test your own **modules** this way
(`./modules/hardening.nix` above), not whole hosts: a host includes its
`hardware-configuration.nix`, which does not fit a test VM.

The test needs KVM on the machine that runs it, or it falls back to slow emulation.
GitHub-hosted Linux runners expose `/dev/kvm`, though you may need a udev rule to
give the runner user access; see [[linux/distributions/nixos/gitops#CI]].

## Building images

`nixos-rebuild build-image` builds a disk or ISO image from any host in the flake:

```bash
nixos-rebuild build-image --flake .#web-01                         # lists the variants
nixos-rebuild build-image --image-variant qemu-efi --flake .#web-01  # qcow2, UEFI
nixos-rebuild build-image --image-variant iso --flake .#web-01       # bootable ISO
```

Or as a flake output, for CI:

```bash
nix build .#nixosConfigurations.web-01.config.system.build.images.qemu-efi
```

| Variant | Produces |
| --- | --- |
| `qemu-efi` | qcow2 disk, UEFI — for KVM |
| `qemu` | qcow2 disk, BIOS |
| `iso` | Live ISO of this system |
| `iso-installer` | Installer ISO with this system's config |
| `raw-efi` | Raw disk image, UEFI — `dd` it to a disk |
| `proxmox`, `vmware`, `virtualbox`, `hyperv` | Hypervisor formats |
| `amazon`, `google-compute`, `azure`, `oci` | Cloud images |

> [!note] nixos-generators is deprecated
> This replaces the separate `nixos-generators` tool, which was merged into nixpkgs
> in 25.05 and is now archived. Older guides use `nixos-generate -f qcow2`. There is
> no variant named `qcow2`: use `qemu-efi` or `qemu`.

An image is useful for a golden VM template, a cloud image, or an offline installer
(see [[linux/distributions/nixos/automated-install]]). It is **not** needed to update
a machine that already runs NixOS — `switch` does that.

## A workflow for a workstation

1. Edit the flake. `git add` new files (see
   [[linux/distributions/nixos/basics#Channels or flakes]]).
2. `nix flake check` — evaluation and module tests.
3. `nixos-rebuild build-vm` — look at the change, especially desktop changes.
4. `sudo nixos-rebuild test` — try it for real; reboot to undo.
5. `sudo nixos-rebuild switch`, then commit.
6. Something wrong next week: `switch --rollback`, or pick an older generation at boot.

For a new machine, the same flake installs it from scratch:
[[linux/distributions/nixos/automated-install]].

## Where to go next

- [[linux/distributions/nixos/automated-install]] — installing a new machine from the flake
- [[linux/distributions/nixos/gitops]] — running these checks in CI
- [[linux/distributions/nixos/basics]] — the rebuild commands

<!-- uplink -->
Part of [[linux/distributions/nixos/index|NixOS]].
