---
title: "Security"
description: "Hardening, supply chain and vulnerability management — the controls that make a class of problem impossible, and the ones that only tell you it happened."
tags: [security]
type: moc
status: complete
---

<!-- generated-moc -->

# Security

Hardening, supply chain and vulnerability management — the controls that make a class of problem impossible, and the ones that only tell you it happened.

## Sections

- [[security/boot-integrity/index|Boot integrity]]
- [[security/cryptography/index|Cryptography, PKI and TLS]]
- [[security/offensive/index|Offensive tooling]]
- [[security/supply-chain/index|Supply chain]]

## Notes in this section

| Note | | What it covers |
| --- | --- | --- |
| [[security/auditd\|auditd]] | how-to | The Linux Audit framework — writing rules, keeping them fast, tuning buffers, and the restart quirk that catches everyone |
| [[security/caldera\|MITRE Caldera]] | how-to | Automated adversary emulation — agents, abilities, adversary profiles, and using it to validate detection rather than to prove you can be hacked |
| [[security/cvss\|CVSS 4.0]] | reference | Scoring vulnerability severity with CVSS 4.0 — metric groups, building a vector string, worked examples, and what the number does not tell you |
| [[security/devsecops-chain\|The DevSecOps chain]] | concept | Where each control belongs in a pipeline, what each stage can and cannot catch, and why gate placement matters more than tool selection |
| [[security/kernel-modules\|Kernel module attack surface]] | how-to | Why unused kernel modules are a liability, blacklisting them by hand and with modulejail, module signing, and kernel lockdown |
| [[security/mitre-attack-and-d3fend\|MITRE ATT&CK and D3FEND]] | concept | A shared vocabulary for adversary behaviour and for defences — the matrix structure, using it in threat modelling, and the coverage-map trap |
| [[security/neuvector\|NeuVector]] | how-to | Deploying NeuVector for container runtime security on Kubernetes — what it does, installing it with Helm, and reaching the console |
| [[security/opencti-and-openaev\|OpenCTI and OpenAEV]] | concept | Open-source threat intelligence and adversary exposure validation — what each does, how they connect, and running both from the XTM Docker stack |
| [[security/resources\|Security resources]] | reference | References worth keeping to hand — offensive technique catalogues, defensive cheat sheets, vulnerability feeds and supply-chain tooling |
| [[security/secure-container-images\|Secure container images]] | reference | Guidelines for building and shipping container images — minimal base images, rootless execution, multi-stage builds, signing, scanning and runtime hardening |
| [[security/security-roadmap\|Building a security roadmap]] | concept | How to sequence security work for a Kubernetes platform — the domains worth covering, what to do first, and the tooling for each |
| [[security/selinux\|SELinux]] | how-to | Mandatory access control on Linux — contexts, modes, booleans, and fixing the mislabelled file that broke your web server |

Part of [[index|Ops Notes]].
