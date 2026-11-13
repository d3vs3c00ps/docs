---
title: Gitea with nixos-anywhere
description: Installing the first lab server on vfkit — a server base module with its own option, a disko layout, the Gitea host, nixos-anywhere run by lab.sh, the hardware file round trip, and the admin account
tags: [homelab, nixos, gitea, nixos-anywhere, disko, vfkit]
type: lab
status: draft
---

# Gitea with nixos-anywhere

> [!note] Not tested locally
> The lab runs on a Mac with vfkit. The test harness cannot run it. The install
> was run by hand on vfkit. The SSH login and a push of a test branch work.

The first server of the lab, and the template for every later one. See
[[labs/nixos-homelab/overview]].

## A base module for servers, with its own option

Every headless host needs the same things: a static IP, DNS, root SSH by key for
deployment. A module with an **option** keeps each host file down to what is
specific to it:

```nix
# modules/server.nix
{ config, lib, ... }:
let cfg = config.lab.server; in
{
  options.lab.server = {
    address = lib.mkOption {
      type = lib.types.str;
      example = "192.168.64.10";
      description = "Static IPv4 address on the vfkit NAT network.";
    };
  };

  config = {
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    # networkd matches by type: the virtio NIC name differs between hypervisors.
    networking.useDHCP = false;
    networking.useNetworkd = true;
    systemd.network.networks."10-lab" = {
      matchConfig.Type = "ether";
      address = [ "${cfg.address}/24" ];
      gateway = [ "192.168.64.1" ];
    };
    networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
    networking.firewall.enable = true;

    services.openssh.settings.PermitRootLogin = "prohibit-password";
    users.users.root.openssh.authorizedKeys.keys =
      [ (builtins.readFile ../keys/id_nix_lab.pub) ];
    users.mutableUsers = false;
  };
}
```

`options` declares a typed setting; `config` uses it. A host that forgets
`lab.server.address` fails at evaluation with a clear error, not at boot with no
network. See [[linux/distributions/nixos/language]] for the module system.

The NIC is matched by type (`ether`), so there is no interface option. The
nameservers are public resolvers.

## The disk layout

```nix
# modules/disk-vm.nix
{ lib, ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    device = lib.mkDefault "/dev/vda";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          type = "EF00";
          size = "512M";
          content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot";
                      mountOptions = [ "umask=0077" ]; };
        };
        root = {
          size = "100%";
          content = { type = "filesystem"; format = "ext4"; mountpoint = "/"; };
        };
      };
    };
  };
}
```

On real hardware, use a `/dev/disk/by-id/` path. A vfkit VM has one virtio disk,
`/dev/vda`, the same in every VM. That is what makes one shared module possible.

disko also generates the `fileSystems` entries, so the host's
`hardware-configuration.nix` must not declare them.

## The host

```nix
# hosts/gitea/default.nix
{ config, ... }:
let domain = "gitea.lab.home.arpa"; in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/server.nix
    ../../modules/disk-vm.nix
  ];

  networking.hostName = "gitea";
  lab.server.address = "192.168.64.10";

  services.gitea = {
    enable = true;
    database.type = "sqlite3";
    settings = {
      server = {
        DOMAIN = domain;
        ROOT_URL = "http://${domain}:3000/";
        HTTP_PORT = 3000;
        SSH_DOMAIN = domain;
      };
      service.DISABLE_REGISTRATION = true;
      session.COOKIE_SECURE = false;   # plain HTTP inside the lab
      # Webhooks to private addresses are blocked by default; Woodpecker is one.
      security.ALLOWED_HOST_LIST = "private";
    };
  };

  networking.firewall.allowedTCPPorts = [ 3000 ];

  # The service has gitea in its own PATH only; this adds the CLI for admin tasks.
  environment.systemPackages = [ config.services.gitea.package ];

  system.stateVersion = "26.05";
}
```

Before the install, `hosts/<host>/hardware-configuration.nix` may be `{ }`: the
flake cannot evaluate without the file. Add the host to `flake.nix` with `mkHost`.
Nix reads only tracked files, so `git add` new files before a build.

## Install

```bash
lab/lab.sh up gitea
```

This **erases the VM's virtual disk**, never a real one. The steps:

1. Build the ISO, boot a new VM on it with a blank disk.
2. Find its DHCP lease by MAC address, wait for SSH.
3. Run nixos-anywhere (version pinned by `flake.lock`) with `--no-reboot` and
   `--generate-hardware-config`.
4. Power the VM off, start it again from its disk only, wait for SSH on
   `192.168.64.10`.

`up` and `install` never touch a host that already has a `lab/state/<host>`
folder. To redo one, use `lab/lab.sh install --force gitea`.

Check it:

```bash
lab/lab.sh smoke gitea
lab/lab.sh ssh gitea 'hostname; systemctl is-active gitea'
```

## The hardware file round trip

nixos-anywhere writes `hosts/gitea/hardware-configuration.nix` in the repository
on the Mac. **Commit it**. Without it, the next deploy from a fresh clone would use
the empty `{ }` and lose the kernel modules needed to boot.

The file has no `fileSystems` entries, as expected with disko. The first generation
on the server shows `<rev>-dirty`, since the file was written during the install.
Redeploying from the clean commit fixes that, and proves the update path works:

```bash
lab/lab.sh deploy gitea
lab/lab.sh ssh gitea nixos-rebuild list-generations
```

## Admin account, SSH key and repository

Registration is off, so the first account is created on the server with the Gitea
CLI. Run this after `lab.sh up gitea`:

```bash
lab/ci-bootstrap.sh
```

Among other things (see [[labs/nixos-homelab/woodpecker]]), it:

1. creates the Gitea admin `lab_admin` (email `lab_admin@lab.home.arpa`). The password
   goes to `secrets/gitea/admin-password`;
2. registers `secrets/ssh/id_nix_lab.pub` as an SSH key of `lab_admin`, through the
   Gitea API;
3. creates the empty repository `lab_admin/nix-lab`;
4. sets the git remote `gitea` to `gitea@192.168.64.10:lab_admin/nix-lab.git`, and
   `core.sshCommand` to `ssh -F <repo>/secrets/ssh/config`.

Git over SSH uses the `gitea` system user through the server's normal sshd; Gitea
maps the key to the `lab_admin` account. Then push:

```bash
git push -u gitea main
```

> [!note] Checked on vfkit
> The key logs in, and pushing and deleting a test branch works. A push of `main` was
> not run. `lab.sh` builds from the working tree on the Mac,
> so the lab does not need Gitea as the source of truth. It is the place for CI to
> clone from.

> [!note] New Gitea repositories are public by default
> Anyone on the lab network can read them. Keep secrets out of the repository: see
> [[linux/distributions/nixos/server#Secrets|sops-nix]] and the next step.

## Next

[[labs/nixos-homelab/woodpecker]] — CI for this repository.

<!-- uplink -->
Part of [[labs/nixos-homelab/index|NixOS home lab]].
