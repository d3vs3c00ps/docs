---
title: NixOS disk encryption
description: LUKS on NixOS — declarative initrd unlocking, TPM auto-unlock with systemd-cryptenroll, remote unlock over SSH, and impermanence
tags: [linux, nixos, luks, encryption, security, boot]
type: howto
status: complete
---

# NixOS disk encryption

The mechanism is ordinary LUKS — see luks for how it
works, and tpm for the sealing model. What differs on
NixOS is that the initrd is **generated from your configuration**, so unlocking is
declared rather than assembled.

## Installing onto an encrypted disk

```bash
# Partition: EFI system partition + one LUKS container
sudo parted /dev/nvme0n1 -- mklabel gpt
sudo parted /dev/nvme0n1 -- mkpart ESP fat32 1MiB 1GiB
sudo parted /dev/nvme0n1 -- set 1 esp on
sudo parted /dev/nvme0n1 -- mkpart primary 1GiB 100%

sudo mkfs.fat -F32 -n boot /dev/nvme0n1p1

sudo cryptsetup luksFormat \
  --type luks2 --cipher aes-xts-plain64 --key-size 512 \
  --hash sha512 --pbkdf argon2id \
  /dev/nvme0n1p2

sudo cryptsetup open /dev/nvme0n1p2 cryptroot
```

LVM inside the container, so swap and root share it — see lvm:

```bash
sudo pvcreate /dev/mapper/cryptroot
sudo vgcreate vg /dev/mapper/cryptroot
sudo lvcreate -L 16G -n swap vg
sudo lvcreate -l 100%FREE -n root vg

sudo mkfs.ext4 -L nixos /dev/vg/root
sudo mkswap -L swap /dev/vg/swap
```

Then mount and `nixos-generate-config` as usual.

## The configuration

`nixos-generate-config` detects the setup and writes most of this into
`hardware-configuration.nix`:

```nix
{
  boot.initrd.luks.devices."cryptroot" = {
    device = "/dev/disk/by-uuid/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
    preLVM = true;
    allowDiscards = true;
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
}
```

> [!important] Always reference the device by UUID
> `/dev/nvme0n1p2` is not stable across hardware changes or kernel versions. A
> configuration referring to a device name that has moved produces an unbootable
> system whose only symptom is the initrd failing to find the container.
>
> ```bash
> sudo blkid /dev/nvme0n1p2
> ```

`allowDiscards` passes TRIM through to the SSD, which improves wear levelling at the
cost of revealing which blocks are unused — a minor information leak that is
generally an acceptable trade.

## TPM auto-unlock

Unlock without a passphrase, only when the machine booted into a trusted state.
`systemd-cryptenroll` is the modern route and integrates cleanly:

```nix
{
  boot.initrd.systemd.enable = true;      # required; the default on NixOS 26.05

  boot.initrd.luks.devices."cryptroot" = {
    device = "/dev/disk/by-uuid/...";
    crypttabExtraOpts = [ "tpm2-device=auto" "tpm2-measure-pcr=yes" ];
  };
}
```

Enrol the key against PCR 7, which measures Secure Boot state:

```bash
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme0n1p2
sudo systemd-cryptenroll --tpm2-device=auto --wipe-slot=tpm2 /dev/nvme0n1p2   # to redo it
```

> [!warning] Keep the passphrase slot, and expect to reseal
> TPM unlocking is a convenience layered on top of a passphrase, not a replacement.
> Anything that changes PCR 7 — a firmware `db` update, enrolling a MOK, toggling
> Secure Boot, a BIOS flash — makes the TPM refuse, and the passphrase is the only way
> back in.
>
> The 2026 Secure Boot certificate rollout (Microsoft's 2011 certificates expire in
> 2026) moves PCR 7 on every machine that receives the new `db`.
> See secure-boot and the reseal procedure in
> luks.

`boot.initrd.systemd.enable = true` selects the systemd-based initrd, which is what
makes `crypttab` options work. The older script-based initrd does not support them.
On NixOS 26.05 the systemd initrd is already the default; the line makes the
dependency explicit, and keeps it if the default changes.

## Remote unlock over SSH

For a headless server, an encrypted root means someone must be present at boot —
unless the initrd runs an SSH daemon:

```nix
{
  boot.initrd.network = {
    enable = true;
    ssh = {
      enable = true;
      port = 2222;
      authorizedKeys = [ "ssh-ed25519 AAAA... your.name@example.com" ];
      hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];   # a string, not a path
    };
  };

  boot.initrd.availableKernelModules = [ "r8169" ];   # your NIC driver
  boot.kernelParams = [ "ip=dhcp" ];
}
```

Then, at boot:

```bash
ssh -p 2222 root@web-01
# systemd-tty-ask-password-agent   (systemd initrd)
```

Generate the initrd host key separately, and keep it out of the store:

```bash
sudo mkdir -p /etc/secrets/initrd
sudo ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key
```

> [!warning] Correction
> An earlier version wrote the key as a path, `/etc/secrets/initrd/...` without
> quotes. A Nix path is copied into the world-readable `/nix/store` when the
> configuration uses it, which is what this section says to avoid. Write it as a
> string: NixOS then copies the file into the initrd at boot-loader install time,
> not into the store.

> [!danger] The initrd host key is a real host key, in a real initrd
> The initrd is on the **unencrypted** boot partition, so anything embedded in it is
> readable by anyone with physical access. That is acceptable for a host key — it
> authenticates the machine to you — and would not be for a passphrase or a decryption
> key.
>
> It is also a different key from the running system's, so your client will warn about
> a changed host key on port 2222 unless you give it its own `known_hosts` entry.

## Impermanence

A pattern NixOS makes uniquely practical: wipe the root filesystem on every boot, and
declare the few paths that persist.

```nix
{
  # Root on tmpfs, or rolled back to a blank btrfs subvolume at boot
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "defaults" "size=2G" "mode=755" ];
  };

  environment.persistence."/persist" = {
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
      "/etc/NetworkManager/system-connections"
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
    ];
  };
}
```

Requires the [impermanence](https://github.com/nix-community/impermanence) module.

The appeal is that undeclared state cannot accumulate — anything that survives a
reboot is something you listed. It is the logical end point of the NixOS argument, and
it is genuinely unforgiving: forget to persist something and you lose it on the next
boot, which is a real cost to weigh against the guarantee.

## Where to go next

- luks — the mechanism, and the reseal procedure
- tpm — PCRs and what moves them
- [[linux/distributions/nixos/hardening]] — the rest of the security configuration
- lvm — the volume layer inside the container

<!-- uplink -->
Part of [[linux/distributions/nixos/index|NixOS]].
