---
title: "NixOS home lab"
description: "NixOS VMs on a Mac with vfkit, all declared in one flake: Gitea, Woodpecker CI and Kubernetes, installed with nixos-anywhere."
tags: [nixos-homelab]
type: moc
status: complete
---

<!-- generated-moc -->

# NixOS home lab

NixOS VMs on a Mac with vfkit, all declared in one flake: Gitea, Woodpecker CI and Kubernetes, installed with nixos-anywhere.


| Note | | What it covers |
| --- | --- | --- |
| [[labs/nixos-homelab/gitea\|Gitea with nixos-anywhere]] | lab | Installing the first lab server on vfkit — a server base module with its own option, a disko layout, the Gitea host, nixos-anywhere run by lab.sh, the hardware file round trip, and the admin account |
| [[labs/nixos-homelab/installer-iso\|The lab installer ISO]] | lab | One generic NixOS installer ISO for every lab VM — SSH on, root login by key only, no ZFS — built in a container by lab.sh and booted once per VM on vfkit |
| [[labs/nixos-homelab/kubernetes\|Kubernetes on NixOS with Cilium]] | lab | A three-node cluster on vfkit with services.kubernetes and Cilium instead of flannel — the CNI directories NixOS owns, privileged pods, pod CIDRs, the certmgr loop, the resolved stub and CoreDNS, and one script to join and install |
| [[labs/nixos-homelab/overview\|NixOS home lab overview]] | lab | A home lab of five NixOS VMs on a Mac, run with vfkit and one script, all declared in one flake — the machines, the IP plan, the network, and the install-then-deploy workflow |
| [[labs/nixos-homelab/woodpecker\|Woodpecker CI with sops-nix]] | lab | CI for the lab flake on vfkit — Woodpecker server and a local-backend agent on one NixOS VM, secrets with sops-nix, a host key generated before the install, Gitea OAuth, and the bootstrap script that does it all |

Part of [[labs/index|Labs]].
