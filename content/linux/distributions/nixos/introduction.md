---
title: What NixOS is
description: A distribution built on a purely functional package manager — the store, atomic generations, and what you give up in exchange
tags: [linux, nixos, nix, distributions, immutable]
type: concept
status: complete
---

# What NixOS is

NixOS is a Linux distribution where **the entire system is built from a declarative
configuration**, by a purely functional package manager.

The claim is not "configuration management, but built in". It is stronger: the same
configuration produces the same system, upgrades are atomic, rollbacks take one
reboot, and two versions of a package can coexist without conflict — because the
package manager was designed around those properties rather than acquiring them
later.

## The one idea everything follows from

Packages do not go in `/usr/bin`. They go in the **Nix store**, at a path derived
from a hash of every input that produced them:

```text
/nix/store/wq2y4bl5m7i9v6rk3z8x1c0dhpqn5jfa-openssl-3.0.12/
/nix/store/8k3jd9s2mfl0pq7xr4nv6tbc1yh5gwze-openssl-3.0.14/
```

That hash covers the source, the compiler, the flags, and every dependency —
transitively. Change any of them and the path changes.

Consequences, all of which fall straight out of that:

| Property | Because |
| --- | --- |
| **No dependency hell** | Two versions have different paths and simply coexist |
| **Atomic upgrades** | A new generation is built completely, then one symlink is swapped |
| **Rollback** | The previous generation's paths still exist; point back at them |
| **Reproducible** | Same inputs, same hash, same output |
| **Safe experimentation** | Nothing is modified in place, so nothing can be half-upgraded |

```bash
ls -l /run/current-system
# → /nix/store/...-nixos-system-hostname-26.05.../
```

`/run/current-system` is a symlink. Switching generations is changing where it points
— which is why an upgrade cannot leave you halfway.

## What a system looks like

One file describes the machine:

```nix
{ config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  boot.loader.systemd-boot.enable = true;
  networking.hostName = "web-01";

  users.users.alice = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA..." ];
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  services.nginx = {
    enable = true;
    virtualHosts."example.com" = {
      enableACME = true;
      forceSSL = true;
      root = "/var/www/example.com";
    };
  };

  security.acme = {                  # required by enableACME
    acceptTerms = true;
    defaults.email = "your.name@example.com";
  };

  environment.systemPackages = with pkgs; [ vim git htop ];

  system.stateVersion = "26.05";
}
```

```bash
sudo nixos-rebuild switch
```

> [!warning] `system.stateVersion` is not the version you run
> It records the release the machine was **first installed** with, so that stateful
> services (PostgreSQL data formats, default paths) keep their old behaviour after an
> upgrade. Set it once, at install time, and never bump it with an upgrade. The
> release you run comes from the `nixpkgs` input — see
> [[linux/distributions/nixos/basics#Channels or flakes]].

That configuration produces a machine with SSH hardened, nginx configured, TLS
certificates obtained from Let's Encrypt, and a user with a key. There is no separate
tool, no playbook, and no drift — the file *is* the system.

## Generations

Every rebuild creates a generation, and they are all still there:

```bash
nixos-rebuild list-generations
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system
```

They appear in the boot menu. A change that breaks the machine is undone by
selecting the previous entry — **including** kernel, bootloader and service
configuration, because all of it is part of the generation.

```bash
sudo nixos-rebuild switch --rollback
```

> [!important] This is the property that justifies the learning curve
> Every other distribution's answer to "the upgrade broke it" involves restoring
> backups or reinstalling. NixOS's answer is a reboot into the previous entry, which
> is guaranteed to be exactly what you had, because it was never modified.
>
> For anything you cannot easily rebuild — a workstation, a machine you can't reach
> physically — that is worth real inconvenience elsewhere.

## What you give up

Being honest about this matters, because the enthusiasm around NixOS tends not to be.

> [!warning] The Filesystem Hierarchy Standard does not apply, and this breaks things
> `/usr/bin` holds only `env`, and `/bin` only `sh`. There is no `/lib64`. Any
> downloaded binary expecting `/lib64/ld-linux-x86-64.so.2` fails immediately — which is most
> proprietary software, many language-specific installers, and anything shipped as a
> generic Linux tarball.
>
> There are answers — `nix-ld`, `steam-run`, `buildFHSEnv`, or packaging it
> properly — but they are extra work every time, and this is the single most common
> reason people abandon NixOS.

> [!warning] Correction
> An earlier version said there is no `/usr/bin`. There is one, with `/usr/bin/env`
> only, so `#!/usr/bin/env bash` scripts work. It also named `buildFHSUserEnv`, which
> was renamed `buildFHSEnv` and is gone from nixpkgs 26.05. The example
> configuration lacked `security.acme`: without `acceptTerms` and an email,
> `enableACME` stops the build with an assertion error.

The rest:

- **A real learning curve.** The Nix language is unfamiliar, and error messages are
  poor. Expect weeks, not days.
- **Disk usage.** Keeping every generation and all their dependencies costs tens of
  gigabytes until you garbage-collect.
- **Documentation is thin and fragmented**, split across the manual, the wiki,
  Discourse and source code. Reading `nixpkgs` is a normal part of using it.
- **Flakes are the de facto standard and still officially experimental**, so much
  material describes one of two incompatible approaches without saying which.

## Where it fits

**Good fit:** workstations you want reproducible, servers whose configuration should
live in Git, build and CI machines, anything where "rebuild it identically" matters,
and development shells pinned per project.

**Poor fit:** teams without appetite for the learning curve, estates depending on
vendor packages and agents, and anywhere the ecosystem's tooling assumes a
conventional filesystem.

> [!note] Nix without NixOS is the low-risk way in
> The package manager runs on any Linux distribution and on macOS. `nix develop`
> giving every project a pinned, reproducible toolchain delivers much of the value
> with none of the commitment — and is a far better first step than converting a
> server. See [[linux/distributions/nixos/basics]].

## Where to go next

- [[linux/distributions/nixos/basics]] — installing, rebuilding, managing generations
- [[linux/distributions/nixos/language]] — the Nix language
- [[linux/distributions/nixos/derivations]] — what a build actually is
- [[linux/distributions/nixos/workstation]] · [[linux/distributions/nixos/server]]

<!-- uplink -->
Part of [[linux/distributions/nixos/index|NixOS]].
