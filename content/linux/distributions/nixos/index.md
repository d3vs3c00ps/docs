---
title: "NixOS"
description: "A distribution built from a declarative configuration by a purely functional package manager — atomic upgrades, real rollback, and an honest account of what you give up for them."
tags: [nixos]
type: moc
status: complete
---

<!-- generated-moc -->

# NixOS

A distribution built from a declarative configuration by a purely functional package manager — atomic upgrades, real rollback, and an honest account of what you give up for them.


| Note | | What it covers |
| --- | --- | --- |
| [[linux/distributions/nixos/automated-install\|Automated NixOS install]] | how-to | The NixOS answer to Kickstart and preseed — an installer ISO that installs a fixed system with no questions, and nixos-anywhere over SSH |
| [[linux/distributions/nixos/basics\|NixOS basics]] | how-to | Installing, the rebuild commands and what each does, channels versus flakes, garbage collection, and finding options and packages |
| [[linux/distributions/nixos/derivations\|Derivations]] | concept | The build recipe underneath everything — how a store path's hash is computed, the difference between evaluation and building, and what reproducibility actually means here |
| [[linux/distributions/nixos/disk-encryption\|NixOS disk encryption]] | how-to | LUKS on NixOS — declarative initrd unlocking, TPM auto-unlock with systemd-cryptenroll, remote unlock over SSH, and impermanence |
| [[linux/distributions/nixos/gitops\|NixOS with GitOps]] | how-to | A configuration repository as the source of truth — repository layout, CI that builds every host, staged rollout, and binary caches |
| [[linux/distributions/nixos/hardening\|NixOS hardening]] | reference | What the declarative model gives you for free, systemd sandboxing, kernel and network hardening, AppArmor, auditing, and where the store's readability bites |
| [[linux/distributions/nixos/introduction\|What NixOS is]] | concept | A distribution built on a purely functional package manager — the store, atomic generations, and what you give up in exchange |
| [[linux/distributions/nixos/language\|The Nix language]] | concept | Attribute sets, functions, laziness, let and with, the module system, and the syntax that trips everyone up |
| [[linux/distributions/nixos/server\|NixOS as a server]] | how-to | Service modules, secrets that must not go in the store, deployment tooling, and building a system image |
| [[linux/distributions/nixos/testing\|Testing NixOS configurations]] | how-to | Checking a configuration before it reaches a machine — build and dry-activate, throwaway VMs with build-vm, automated NixOS VM tests in nix flake check, and building ISO and disk images |
| [[linux/distributions/nixos/workstation\|NixOS as a workstation]] | how-to | Desktop environments, home-manager for user configuration, per-project dev shells, and running binaries that expect a normal filesystem |

Part of [[linux/distributions/index|Distributions]].
