---
title: Ops Notes
description: Sysadmin and platform engineering notes — Linux, servers, networking, containers, Kubernetes, Ansible and the tooling around them
tags: [meta]
type: moc
status: complete
---

# Ops Notes

Working notes from a systems and platform engineering career: Linux, the daemons that
run on it, networking, containers, Kubernetes, and the automation that ties them
together.

These were written over years, originally in French, as a personal reference rather
than as a course. They are opinionated, occasionally incomplete, and aimed at someone
who already knows roughly what they are doing and needs the specific thing.

## Sections

| Section | What is in it |
| --- | --- |
| [[linux/index\|Linux]] | the shell, CLI tools, boot and init, storage, logging, distributions |
| [[servers/index\|Servers]] | web servers, databases, directory and time services, TLS |
| [[networking/index\|Networking]] | packet filtering with iptables and nftables |
| [[observability/index\|Observability]] | Prometheus and Grafana: metrics, alerts, dashboards |
| [[containers/index\|Containers]] | what a container is, Docker, Podman, containerd, and hardening |
| [[kubernetes/index\|Kubernetes]] | the largest section — concepts through to operating a cluster |
| [[security/index\|Security]] | hardening, boot integrity, supply chain, offensive tooling, frameworks |
| [[automation/index\|Automation]] | Ansible in depth |
| [[dev/index\|Development]] | Git, Markdown, YAML, Gherkin, Python, Task and vfkit |
| [[ai/index\|Local LLMs]] | running models on your own hardware, and the tooling around them |
| [[storage/index\|Storage]] | SAN and RAID concepts |
| [[labs/index\|Labs]] | a NixOS home lab on macOS: Gitea, Woodpecker CI and Kubernetes on VMs |
| [[virtualization/index\|Virtualisation]] | KVM and QEMU, KubeVirt, and VMware via PowerCLI |
| [[windows/index\|Windows]] | licensing, links, the component store |

## Where to start

Depending on what you came for:

- **A specific command or flag** — use search. Most notes are reference material and
  the search index covers the code blocks too.
- **Building a Kubernetes cluster from nothing** —
  [[kubernetes/my-notes/vanilla-cluster-lab]] does it by hand, every certificate and
  unit file written out, so the moving parts are visible.
- **Understanding Kubernetes properly** — start at
  [[kubernetes/concepts/index|concepts]] and work along.
- **Reliable log shipping** — [[linux/logging/rsyslog]] covers queues, failover and
  the difference between TCP and RELP.
- **Ansible conventions for a team** — [[automation/ansible/best-practices]].
- **Why my container cannot reach anything** —
  [[linux/networking/virtual-interfaces]] explains the namespace and interface types
  underneath, with diagrams.
- **Running an LLM locally** — [[ai/quickstart-macos]] is a complete Apple Silicon
  setup; [[ai/hardware-requirements]] decides what your machine can actually hold.
- **Disk encryption that unlocks itself** —
  [[security/boot-integrity/index|boot integrity]] covers Secure Boot, the TPM and
  LUKS as one chain.
- **What a container actually is** — [[containers/concepts]] takes it apart into the
  kernel features it is assembled from, which explains most of its odd behaviour.
- **Proving where an artifact came from** —
  [[security/supply-chain/index|supply chain]] covers SBOMs, signing and VEX, and why
  producing an SBOM is not yet a control.
- **Running VMs on Kubernetes** — [[virtualization/kubevirt/introduction]], and
  [[virtualization/kvm/introduction]] for the hypervisor underneath.

## How these notes are organised

Every note carries typed frontmatter, which drives the tag pages and the listings:

| Field | Meaning |
| --- | --- |
| `type` | `concept`, `howto`, `reference`, `lab` or `moc` |
| `status` | `stub`, `draft` or `complete` |
| `tags` | a controlled vocabulary, so tag pages stay useful |
| `source` / `license` | present on anything derived from someone else's work |

See [[dev/markdown]] for the writing conventions, and [[attribution]] for where
third-party content comes from and under what licence.

## A caveat

Notes go stale. Where I know something has changed since it was written — a
deprecated flag, a removed kernel module, a superseded API — there is a callout
saying so. Where I do not know, there is not. Check the version you are running
before pasting anything into a production shell.

The lab code is in [d3vs3c00ps/nix-lab](https://github.com/d3vs3c00ps/nix-lab).
Corrections and additions are welcome:
[github.com/d3vs3c00ps/docs](https://github.com/d3vs3c00ps/docs).
