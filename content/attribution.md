---
title: Attribution and licences
description: Where the content of this vault comes from, and the licences it is used under
tags: [meta, licensing, attribution]
type: reference
status: complete
---

# Attribution and licences

> [!note] Not tested locally
> This page is a licence and credit notice. It has no commands to run.

## My own notes

Everything outside `kubernetes/` — the Linux, servers, networking, storage,
automation, containers, security, dev, AI and Windows sections — is my own work,
translated from French where it started there, and reorganised. Licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/): use it, adapt it, just
say where it came from.

The same applies to `kubernetes/my-notes/`, which is original material rather than
derived from the course below.

## container.training — CC BY 4.0

Most of the `kubernetes/` section is **derived from
[container.training](https://github.com/jpetazzo/container.training)** by **Jérôme
Petazzoni and the container.training contributors**, used under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/legalcode).

**Changes were made.** Specifically:

- The upstream material is a set of [remark.js](https://remarkjs.com) slide decks.
  Each deck has been restructured into a single web page, with slide breaks becoming
  document sections.
- remark-specific markup was translated into Obsidian equivalents: `.lab[…]`
  exercise blocks became "Hands-on" callouts, `.warning[…]` became warning callouts,
  and `class: extra-details` slides became collapsible callouts.
- Files that upstream embeds with `@@INCLUDE[…]` were inlined as code blocks, and
  `@@LINK[…]` references became permanent links to the upstream repository at a
  pinned commit.
- Presenter-only content was removed: autopilot terminal directives, and slides
  marked for in-person delivery.
- Topics that are purely workshop logistics — VM allocation, chat rooms, closing
  slides and link dumps — are not reproduced at all.
- Some topics have been placed in a different order and grouping than any upstream
  deck uses.

Every derived page records its provenance in its own frontmatter:

```yaml
source: https://github.com/jpetazzo/container.training/blob/<commit>/slides/k8s/<topic>.md
license: CC-BY-4.0
upstream_commit: <commit>
```

That is both the attribution and the re-sync ledger: it says exactly which upstream
file and which commit a page was generated from, so drift can be found later.

The conversion is reproducible — see `scripts/convert-slides.mjs` in this
repository.

> [!important] Upstream is the authority, not this copy
> These pages were generated from one commit and do not track upstream. For the
> current, maintained version of this material — and for the accompanying lab
> environments — go to [container.training](https://container.training) and the
> [repository](https://github.com/jpetazzo/container.training).

### Which licence covers which part of upstream

container.training's own `LICENSE` splits it:

| Upstream content | Licence |
| --- | --- |
| The instructions and slides — `slides/**/*.md`, `slides/**/*.yml` | **CC BY 4.0** |
| The code — everything else, including `slides/markmaker.py` and the build tooling | **Apache 2.0** |

Only the CC BY 4.0 material is reproduced here. None of the Apache-2.0 tooling is
vendored into this repository, so no `NOTICE` file is required.

### Third-party diagrams

Two architecture diagrams reproduced from upstream were contributed by others, and
upstream encodes the credit in their filenames — which this vault preserves rather
than tidying away:

| File | Credit |
| --- | --- |
| `k8s-arch3-thanks-weave.png` | Weaveworks |
| `k8s-arch4-thanks-luxas.png` | Lucas Käldström |

## Other third-party material

| Note | Source | Licence / terms |
| --- | --- | --- |
| zsh | [Zsh cheat sheet](https://gist.github.com/ClementNerma/1dd94cb0f1884b9c20d1ba0037bdcde2) by Clément Nerma | **no licence stated** on the source; reproduced with attribution, formatting changes and corrections. Happy to remove it on request |
| inventory | [`ConfigureRemotingForAnsible.ps1`](https://github.com/ansible/ansible-documentation/blob/devel/examples/scripts/ConfigureRemotingForAnsible.ps1), from the Ansible project | GPLv3. Linked, not vendored — a GPLv3 script does not belong inside a CC BY 4.0 vault, and a pinned copy would go stale against current Windows builds |
| auditd | [Linux Audit Framework 101](https://linux-audit.com/linux-audit-framework-101-basic-rules-for-configuration/) by Michael Boelen | **no licence stated**; the rule-ordering, exclusion and buffer-tuning strategies follow that article, rewritten in my own words and extended. Happy to remove it on request |
| remote-attestation | ["TPM-Based Continuous Remote Attestation and Integrity Verification for 5G VNFs on Kubernetes"](https://arxiv.org/abs/2510.03219) | an arXiv preprint; summarised and cited, not reproduced. The pod-aware IMA approach described in the Kubernetes section is theirs |
| secure-boot | [Red Hat](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/managing_monitoring_and_updating_the_kernel/signing-a-kernel-and-modules-for-secure-boot) and [Oracle Linux](https://docs.oracle.com/en/operating-systems/oracle-linux/9/secure-boot/sboot-SigningKernelModulesforUseWithSecureBoot.html) documentation on signing kernels and modules | vendor documentation. The `openssl` x509 configuration and the `sign-file` procedure follow Oracle's chapter, which documents the same workflow as Red Hat's; adapted, with the `basicConstraints` difference between them noted in place |
| secure-boot · tpm | [OneUptime](https://oneuptime.com/blog/) articles on Secure Boot verification, unsigned kernel modules, and TPM 2.0 measured boot on RHEL 9 | **no licence stated**; the verification commands, PCR assignments and baseline workflow follow those articles, rewritten and extended. Happy to remove on request |
| secure-boot | [It's FOSS — What are shim files?](https://itsfoss.com/secure-boot-shim-file/) | **no licence stated**; used for the conceptual framing of why shim exists. No text reproduced |
| kernel-modules | [modulejail](https://github.com/jnuyens/modulejail) by Jeroen Nuyens | described and cited, not vendored. The blacklist examples are my own |
| ai-assisted-scanning | [Vigolium](https://github.com/vigolium/vigolium) (AGPL-3.0) and [Help Net Security's Lyrie coverage](https://www.helpnetsecurity.com/2026/05/18/lyrie-ai-autonomous-pentesting-agent/) | tools described and cited; no code reproduced |
| resources | [Hackropole](https://hackropole.fr/fr/), by ANSSI | linked as a training resource. No challenge content reproduced |
| strands-agents | [Strands Agents documentation](https://strandsagents.com/) | vendor documentation; the code examples follow its quickstart, adapted |
| cgroups-v2 | [Rawkode Academy — cgroups: from chaos to control](https://rawkode.academy/read/cgroups-from-chaos-to-control) | **no licence stated**; the v1/v2 comparison and Kubernetes slice layout follow this article, rewritten. Happy to remove on request |
| disk-io-performance | [Tecmint — Monitor Linux disk I/O performance](https://www.tecmint.com/monitor-linux-disk-io-performance/) | **no licence stated**; used as a starting point, rewritten and extended with PSI and the `%util` correction |
| kill | [witr](https://github.com/pranshuparmar/witr), via [Stéphane Robert's blog](https://blog.stephane-robert.info/docs/admin-serveurs/linux/exploiter/processus/witr/) | tool described and cited |
| local-aws-emulation | [Floci](https://blog.stephane-robert.info/docs/cloud/aws/floci/) (MIT) | described and cited; configuration examples adapted from the article |
| git · parallel-agents | [The workflow: worktrees and parallel agents](https://www.jpaul.me/2026/07/the-workflow-worktrees-parallel-agents/) by J. Paul | **no licence stated**; the worktrees-for-agents framing follows this article, rewritten |
| zsh | [7 best free and open source Zsh configuration frameworks](https://www.linuxtoday.com/blog/7-best-free-and-open-source-zsh-configuration-frameworks/) | **no licence stated**; used as the survey behind the comparison table |
| lnav | [multitail — what it is and how it can make you a better sysadmin](https://idolinux.com/multitail-what-it-is-and-how-it-can-make-you-a-better-sysadmin/) | **no licence stated**; used as the basis for the multitail section |
| k8gb | [K8GB documentation](https://www.k8gb.io/latest/) (CNCF, Apache-2.0) | the `Gslb` example is reproduced from the project's documentation |
| advanced | [CNCF — Benchmarking KubeVirt performance with virtbench](https://www.cncf.io/blog/2026/06/08/benchmarking-kubevirt-performance-with-virtbench/) | tool and metrics described and cited |
| zero-trust-access | [Pangolin](https://pangolin.net) | described and cited |
| sztp | [Linux.com — From DHCP to SZTP](https://www.linux.com/contributed/from-dhcp-to-sztp-the-trust-revolution/), and [RFC 8572](https://www.rfc-editor.org/rfc/rfc8572.html) | the article for framing; the RFC is the normative source |
| mitre-attack-and-d3fend | [MITRE ATT&CK](https://attack.mitre.org/) and [D3FEND](https://d3fend.mitre.org/) | MITRE's own material, used under the terms on their sites. Technique identifiers and tactic names are quoted; the framework itself is not reproduced |

Quotations from RFCs, vendor documentation and manual pages are short excerpts used
for reference, attributed inline where they appear.

## Corrections

Where a migrated note corrected an error in its source — a command that could not
run, a description that contradicted the tool's behaviour, a deprecated API — the
correction is marked in place with a callout explaining what changed and why. The
intent is that no correction is silent, so you can judge it for yourself.

## Reporting a problem

If something here is misattributed, or you are the author of material you would like
credited differently or removed, please
[open an issue](https://github.com/d3vs3c00ps/docs/issues).

<!-- uplink -->
Part of [[index|Ops Notes]].
