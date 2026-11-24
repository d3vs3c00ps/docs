---
title: Security resources
description: References worth keeping to hand — offensive technique catalogues, defensive cheat sheets, vulnerability feeds and supply-chain tooling
tags: [security, links, tooling]
type: reference
status: complete
---

# Security resources

A short, opinionated list of references that have earned a bookmark. Not a link
dump — everything here is something worth returning to.

> [!note] Not tested locally
> Link list, nothing to run. The links were checked in November 2026.

## Technique catalogues

| Resource | What it is good for |
| --- | --- |
| [GTFOBins](https://gtfobins.org/) | How a given Unix binary can be abused to break out of a restricted shell, escalate privileges, or exfiltrate data. The reference when you are deciding whether a binary belongs in an image or a `sudoers` entry. |
| [LOLBAS](https://lolbas-project.github.io/) | The Windows equivalent — living-off-the-land binaries, scripts and libraries. |
| [MITRE ATT&CK](https://attack.mitre.org/) | A structured catalogue of adversary tactics and techniques. Most useful as a shared vocabulary for describing what a detection actually covers. See [[security/mitre-attack-and-d3fend]]. |

> [!tip] Read GTFOBins defensively
> Its main value is not offensive. Before granting a `sudo` rule or leaving a binary
> in a production image, check whether it has an entry — `find`, `tar`, `awk` and
> `less` all do, and all of them will give you a shell.

## Defensive references

| Resource | What it is good for |
| --- | --- |
| [OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/index.html) | Concise, opinionated guidance per topic — authentication, session management, secrets, injection. The single best starting point for application security questions. |
| [OWASP Top 10](https://owasp.org/www-project-top-ten/) | The awareness list. Useful for framing, less useful as a checklist. |
| [CIS Benchmarks](https://www.cisecurity.org/cis-benchmarks) | Per-platform hardening baselines. The source of most of what is in [[security/auditd]] and [[security/selinux]]. |

## Vulnerability intelligence

| Resource | What it is good for |
| --- | --- |
| [CISA KEV](https://www.cisa.gov/known-exploited-vulnerabilities-catalog) | Vulnerabilities known to be exploited in the wild. A far better prioritisation signal than severity alone. |
| [EPSS](https://www.first.org/epss/) | Probability that a vulnerability will be exploited in the next 30 days. Pairs well with [[security/cvss]]. |
| [OSV](https://osv.dev/) | Vulnerability database keyed to package versions, which is what a scanner actually needs. |

## Practising

| Resource | What it is |
| --- | --- |
| [Hackropole](https://hackropole.fr/fr/) | ANSSI's archive of **France Cybersecurity Challenge** exercises — 600+ challenges across cryptography, forensics, hardware, pwn, reverse engineering and web, with published solutions. Free, and in French |
| [Atomic Red Team](https://github.com/redcanaryco/atomic-red-team) | Small per-technique tests mapped to [[security/mitre-attack-and-d3fend\|ATT&CK]]. The cheapest way to validate a detection |
| [OverTheWire](https://overthewire.org/wargames/) | Progressive Linux and networking wargames; `bandit` is the standard starting point |

> [!tip] Hackropole is unusually good for defenders, not just for CTF players
> Because the challenges come from a national agency's competition and ship with
> **published solutions**, it works as a study resource rather than only as a puzzle
> box. Reading the solution to a forensics or pwn challenge is one of the faster ways
> to understand what an attacker actually does with a weakness — which is the same
> understanding [[security/mitre-attack-and-d3fend]] tries to convey abstractly.

## Keeping current

| Resource | Why |
| --- | --- |
| [DevSec Blog](https://devsec-blog.com/blog/) | DevSecOps and supply-chain security practice, at working-engineer depth rather than vendor level |
| [oss-security](https://www.openwall.com/lists/oss-security/) | Where open-source vulnerabilities are disclosed and argued about first |
| [Project Zero](https://projectzero.google/) | Deep exploitation write-ups; useful for calibrating what is actually hard |

> [!tip] Follow disclosure lists, not news sites
> By the time a vulnerability reaches a security news site the useful details are
> usually already on `oss-security` or the vendor's own advisory, along with the
> discussion of what is genuinely exploitable. The signal-to-noise is far better, and
> it arrives days earlier.

## Supply chain

| Resource | What it is good for |
| --- | --- |
| [SLSA](https://slsa.dev/) | Framework for build provenance — what it means to be able to prove where an artifact came from. |
| [Sigstore](https://www.sigstore.dev/) | Signing and verification, including cosign. See [[security/supply-chain/cosign]] and [[security/secure-container-images]]. |
| [OpenVEX](https://github.com/openvex) | Stating machine-readably that you are *not* affected by a CVE, rather than arguing about the score. See [[security/supply-chain/vex]]. |

## Where to go next

- [[security/index|Security]] — the notes in this section
- [[security/secure-container-images]] — where most of the supply-chain links get used

<!-- uplink -->
Part of [[security/index|Security]].
