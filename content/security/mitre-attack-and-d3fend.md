---
title: MITRE ATT&CK and D3FEND
description: A shared vocabulary for adversary behaviour and for defences — the matrix structure, using it in threat modelling, and the coverage-map trap
tags: [security, mitre, attack, threat-modelling, detection]
type: concept
status: complete
---

# MITRE ATT&CK and D3FEND

> [!note] Not tested locally
> Concept note, nothing to run. Tactic lists and IDs were checked against ATT&CK v20 and D3FEND 1.6 in November 2026.

## ATT&CK

[ATT&CK](https://attack.mitre.org/) is a catalogue of adversary **behaviour**,
compiled from observed intrusions. Its value is that it gives everyone the same
vocabulary: a detection engineer, a red teamer and a risk owner can all refer to
`T1078 — Valid Accounts` and mean the same thing.

### The structure

| Level | Meaning | Example |
| --- | --- | --- |
| **Tactic** | The adversary's *goal* — the "why" | Persistence |
| **Technique** | *How* they achieve it | T1053 — Scheduled Task/Job |
| **Sub-technique** | A specific variant | T1053.003 — Cron |
| **Procedure** | A concrete implementation seen in the wild | A named group's specific cron usage |

Fifteen Enterprise tactics run roughly in intrusion order: Reconnaissance, Resource
Development, Initial Access, Execution, Persistence, Privilege Escalation, Stealth,
Defense Impairment, Credential Access, Discovery, Lateral Movement, Collection,
Command and Control, Exfiltration, Impact.

> [!warning] Correction
> An earlier version listed fourteen tactics, with Defense Evasion. ATT&CK v19
> (April 2026) split Defense Evasion into **Stealth** (TA0005, the old ID) and
> **Defense Impairment** (TA0112). Rules and tools that still use the name "Defense
> Evasion" must be remapped.

There are separate matrices for Enterprise (with Linux, Windows, macOS, cloud,
containers and network sub-matrices), Mobile, and ICS. The **Containers** matrix is
the relevant one for a Kubernetes platform, and is much smaller than Enterprise as a
whole — a realistic starting scope.

> [!important] ATT&CK describes behaviour, not vulnerabilities
> This is the distinction that makes it useful. A CVE list tells you what is
> *theoretically* exploitable; ATT&CK tells you what attackers *actually do* once
> they are in. Those overlap far less than people expect — most techniques involve no
> vulnerability at all, just misuse of legitimate functionality.
>
> That is also why it pairs well with [[security/cvss]]: severity scores prioritise
> patching, ATT&CK prioritises detection.

### Using it in threat modelling

The practical method, roughly following
[the five-step approach](https://www.cycoresecure.com/blogs/5-steps-to-use-mitre-attandck-in-threat-modeling):

1. **Scope the system.** One application, one cluster, one business process — not
   "the company".
2. **Identify the relevant matrix and threat actors.** A Kubernetes platform means
   the Containers matrix; the actors relevant to your sector narrow it further.
3. **Map plausible techniques** onto your architecture. For each, ask *how would this
   actually happen here?*
4. **Assess coverage** — which techniques would you prevent, which would you detect,
   and which would pass unnoticed?
5. **Prioritise the gaps** by likelihood and impact, and feed them into
   [[security/security-roadmap|the roadmap]].

Step 3 is where the value is. "T1610 — Deploy Container" is abstract until you ask
who in your cluster can create a pod, and the answer turns out to be a CI service
account with cluster-wide permissions.

### Coverage mapping

[ATT&CK Navigator](https://mitre-attack.github.io/attack-navigator/) is the usual tool
— a matrix you colour by coverage and export as JSON, so it can be versioned and
diffed.

> [!warning] A green matrix is the easiest self-deception in security
> Two failure modes, both common:
>
> **Claiming coverage from a log source.** "We collect process creation events, so we
> cover T1059" — collecting the data is not detecting the behaviour. Coverage means a
> rule that fires and someone who responds.
>
> **Optimising for the matrix.** Techniques are not equally likely or equally
> damaging, and the matrix gives no weighting. Chasing a fully-coloured grid moves
> effort towards easy, rare techniques and away from the handful that account for most
> real intrusions.
>
> Colour it honestly, including the awkward "we would not notice this" cells. The
> uncoloured squares are the entire point of the exercise.

### Where it fits operationally

- **Detection engineering** — tag rules with technique IDs, then query what you cover.
- **Purple teaming** — a shared plan: the red team executes named techniques and the
  blue team confirms detection. [[security/caldera|Caldera]] automates exactly this.
- **Vendor evaluation** — MITRE's own
  [ATT&CK Evaluations](https://evals.mitre.org/) test EDR (endpoint detection and
  response) products against real technique chains. They tell you more than a
  datasheet.
- **Incident reporting** — describing an intrusion in technique IDs makes it
  comparable with everyone else's.

## D3FEND

[D3FEND](https://d3fend.mitre.org/) is the counterpart: a knowledge graph of
**defensive** techniques, and the mapping between them and the offensive ones.

Where ATT&CK answers "what will they do", D3FEND answers "what can I do about it", in
the same structured vocabulary.

Its tactics are Model, Harden, Detect, Isolate, Deceive, Evict and Restore. This is
a more useful split than "prevent and detect", because *Isolate*, *Evict* and
*Restore* are where most organisations are weakest.

> [!warning] Correction
> An earlier version listed six tactics. D3FEND 1.x has seven. The missing one is
> **Restore**: bring systems and data back after an incident.

The table maps D3FEND techniques to these notes. The mapping is ours, not D3FEND's.

| D3FEND technique | Example in these notes |
| --- | --- |
| Kernel-based Process Isolation | [[security/selinux]], namespaces in [[containers/concepts]] |
| System Call Filtering | seccomp in [[containers/containerd/hardening]] |
| Executable Allowlisting | only signed images are admitted: [[security/supply-chain/cosign]] |
| Bootloader Authentication | [[security/boot-integrity/secure-boot]] |
| Network Isolation | [[kubernetes/networking/netpol]] |

> [!warning] Correction
> An earlier version mapped SELinux to Executable Allowlisting, cosign to Message
> Authentication and Secure Boot to Platform Hardening. In D3FEND, Message
> Authentication covers messages (S/MIME, MACs), not artifact signing, and SELinux
> confines processes rather than listing allowed executables. The rows now use the
> closer techniques.

> [!tip] The digital artifact graph is what makes D3FEND different
> D3FEND relates techniques to the **artifacts** they act on — a process, a file, a
> network packet. That lets you ask "given that I can observe process creation, which
> defensive techniques does that enable, and which ATT&CK techniques do those
> counter?"
>
> It turns a coverage discussion from a wish list into a question about what telemetry
> you actually have. D3FEND is less mature and less adopted than ATT&CK, and this
> artifact-centred view is the reason to look at it anyway.

## Honest limitations

- **ATT&CK is descriptive, not predictive.** It catalogues what has been observed. A
  novel technique is absent by definition.
- **It is not a maturity model.** Coverage percentages are not a security score, and
  treating them as a target distorts priorities.
- **The granularity is uneven.** Some techniques are narrow and specific; others are
  enormous catch-alls.
- **Mapping is subjective.** Two analysts will map the same intrusion differently,
  which limits cross-organisation comparison more than the framing suggests.

None of that undermines its main value, which is having one vocabulary instead of
five.

## Where to go next

- [[security/caldera]] — automating technique execution to validate detection
- [[security/security-roadmap]] — turning gaps into sequenced work
- [[security/resources]] — the other reference material
- [[security/offensive/index|Offensive tooling]] — the tools that implement techniques

<!-- uplink -->
Part of [[security/index|Security]].
