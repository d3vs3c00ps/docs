---
title: CVSS 4.0
description: Scoring vulnerability severity with CVSS 4.0 — metric groups, building a vector string, worked examples, and what the number does not tell you
tags: [security, cvss, vulnerability-management]
type: reference
status: complete
---

# CVSS 4.0

CVSS (Common Vulnerability Scoring System) version 4.0 is the current standard for
rating the severity of a vulnerability. It produces a score from **0.0 to 10.0** and
a qualitative rating.

| Score range | Severity |
| --- | --- |
| 0.0 | None |
| 0.1 – 3.9 | Low |
| 4.0 – 6.9 | Medium |
| 7.0 – 8.9 | High |
| 9.0 – 10.0 | Critical |

## Metric groups

CVSS 4.0 has four groups. Only **Base** is mandatory.

| Group | Purpose | Required |
| --- | --- | --- |
| Base | Intrinsic qualities of the vulnerability | Yes |
| Threat | Current exploit landscape (replaces the old Temporal group) | No |
| Environmental | Adjustments for your own deployment | No |
| Supplemental | Extra context, not scored | No |

## Base metrics

### Exploitability

| Metric | Abbrev | Values |
| --- | --- | --- |
| **Attack Vector** | AV | Network (N), Adjacent (A), Local (L), Physical (P) |
| **Attack Complexity** | AC | Low (L), High (H) |
| **Attack Requirements** | AT | None (N), Present (P) |
| **Privileges Required** | PR | None (N), Low (L), High (H) |
| **User Interaction** | UI | None (N), Passive (P), Active (A) |

**Attack Vector (AV)** — how does the attacker reach the target?

- **Network (N)** — exploitable remotely through the network stack. Highest score.
- **Adjacent (A)** — needs access to the same physical or logical segment: Bluetooth,
  local Wi-Fi, a VLAN.
- **Local (L)** — needs local access, such as a shell, or tricking a user into
  opening a malicious file.
- **Physical (P)** — needs hands on the hardware: USB, a debug port. Lowest score.

**Attack Complexity (AC)** — must the attacker defeat a security measure?

- **Low (L)** — the attacker takes no special action. The exploit works every time.
- **High (H)** — the attacker must evade or get around a security measure that is in
  place, such as ASLR (address space layout randomisation) or DEP (data execution
  prevention), or must first obtain a secret specific to the target, such as a key.

**Attack Requirements (AT)** — does the attack depend on how the target is deployed
or on its state at that moment?

- **None (N)** — works against all or most instances of the vulnerable component.
- **Present (P)** — needs specific deployment or execution conditions: a race
  condition the attacker must win, an on-path (machine-in-the-middle) position
  between the victim and the resource, a debug flag enabled, a specific kernel module
  loaded.

> [!warning] Correction
> An earlier version put race conditions and machine-in-the-middle positions under
> `AC:H`. In CVSS 4.0 they are `AT:P` (specification, section 2.1.3). `AC:H` is only
> for defeating security measures (ASLR, DEP) or obtaining target-specific secrets.

**Privileges Required (PR)** — what does the attacker need *before* exploiting?

- **None (N)** — unauthenticated and anonymous.
- **Low (L)** — an ordinary user account.
- **High (H)** — administrative or root access.

**User Interaction (UI)** — must a human do something?

- **None (N)** — fully automated.
- **Passive (P)** — the victim only has to *view* something: visit a page, receive a
  message. No deliberate action.
- **Active (A)** — the victim must deliberately act: click a link, install something,
  dismiss a warning.

### Impact on the vulnerable system

| Metric | Abbrev | Values |
| --- | --- | --- |
| **Confidentiality** | VC | None (N), Low (L), High (H) |
| **Integrity** | VI | None (N), Low (L), High (H) |
| **Availability** | VA | None (N), Low (L), High (H) |

### Impact on subsequent systems

Impact reaching **beyond** the vulnerable component — a container escape affecting
the host, or an SSRF reaching an internal service.

| Metric | Abbrev | Values |
| --- | --- | --- |
| **Confidentiality** | SC | None (N), Low (L), High (H) |
| **Integrity** | SI | None (N), Low (L), High (H) |
| **Availability** | SA | None (N), Low (L), High (H) |

> [!note] The Scope metric is gone
> CVSS 3.1 expressed cross-boundary impact with a single `S:C`/`S:U` flag. 4.0
> replaces it with the explicit VC/VI/VA versus SC/SI/SA split, which says *what*
> happens to the other system rather than merely that something does.

### Reading the impact values

These apply to both VC/VI/VA and SC/SI/SA.

**Confidentiality** — can the attacker *read* what they should not?

- **None** — nothing disclosed.
- **Low** — some restricted data exposed, but the attacker cannot choose *which* —
  a partial memory leak, metadata exposure.
- **High** — all data in the component exposed, or the attacker can target specific
  sensitive data: credentials, private keys, a database dump.

**Integrity** — can the attacker *modify* data or behaviour?

- **None** — no modification possible.
- **Low** — limited modification with no serious consequence, or the attacker cannot
  control what changes — injecting non-critical log entries.
- **High** — any data can be modified, or code execution is achievable.

**Availability** — can the attacker disrupt the service?

- **None** — no impact.
- **Low** — degraded performance or intermittent disruption; mostly still working.
- **High** — the service can be fully crashed or shut down.

## Building a vector string

The string starts with `CVSS:4.0/`, then metric abbreviations and values separated by
`/`:

```text
CVSS:4.0/AV:<val>/AC:<val>/AT:<val>/PR:<val>/UI:<val>/VC:<val>/VI:<val>/VA:<val>/SC:<val>/SI:<val>/SA:<val>
```

All eleven Base metrics are mandatory — there is no defaulting.

## Worked examples

### Remote code execution — Critical

An unauthenticated attacker executes arbitrary code over the network on a web
server, with no user interaction. The attack is straightforward and the server is
fully compromised. No impact elsewhere.

| Metric | Value | Rationale |
| --- | --- | --- |
| AV | N | exploitable over the network |
| AC | L | no special conditions |
| AT | N | no preconditions |
| PR | N | no authentication |
| UI | N | no user interaction |
| VC / VI / VA | H | server fully compromised |
| SC / SI / SA | N | nothing beyond the server |

```text
CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N
```

Base score **9.3**, Critical.

### Container escape — with subsequent system impact

A local attacker with low privileges inside a container escapes to the host.
Complexity is low, but a specific runtime configuration is required. The container is
fully compromised and the host's confidentiality is affected.

| Metric | Value | Rationale |
| --- | --- | --- |
| AV | L | local access, inside the container |
| AC | L | no exploit mitigation to bypass |
| AT | P | specific runtime configuration required |
| PR | L | low-privilege user in the container |
| UI | N | no user interaction |
| VC / VI / VA | H | container fully compromised |
| SC | H | host confidentiality affected |
| SI / SA | N | host integrity and availability intact |

```text
CVSS:4.0/AV:L/AC:L/AT:P/PR:L/UI:N/VC:H/VI:H/VA:H/SC:H/SI:N/SA:N
```

Base score **8.5**, High.

### Stored XSS — Medium

An authenticated low-privilege attacker injects a stored XSS payload through a web
form. A victim must visit the page. Only the victim's session data is affected.

| Metric | Value | Rationale |
| --- | --- | --- |
| AV | N | delivered over the network |
| AC | L | no special conditions |
| AT | N | no prerequisites beyond authentication |
| PR | L | attacker needs a valid account |
| UI | P | victim must navigate to the page |
| VC | L | limited exposure — session cookies |
| VI | L | limited ability to alter page content |
| VA | N | no availability impact |
| SC / SI / SA | N | no subsequent impact |

```text
CVSS:4.0/AV:N/AC:L/AT:N/PR:L/UI:P/VC:L/VI:L/VA:N/SC:N/SI:N/SA:N
```

Base score **5.1**, Medium.

### Denial of service via malformed packet

An unauthenticated attacker crashes a service with a single crafted packet. It
restarts automatically but is unavailable meanwhile. No data leak or tampering.

```text
CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:N/VI:N/VA:H/SC:N/SI:N/SA:N
```

Base score **8.7**, High.

### Information disclosure via physical access — Medium

An attacker with physical access reads cached credentials from an unlocked debug
port. High privileges required. Only device confidentiality is affected.

```text
CVSS:4.0/AV:P/AC:L/AT:N/PR:H/UI:N/VC:H/VI:N/VA:N/SC:N/SI:N/SA:N
```

Base score **5.1**, Medium.

> [!warning] Correction
> An earlier version rated this example Low. The 4.0 calculator gives 5.1, Medium:
> `VC:H` keeps the score up even with physical access and high privileges.

## Picking values — decision order

1. **How does the attacker reach the target?**
   Network → `AV:N` · adjacent segment → `AV:A` · local → `AV:L` · physical → `AV:P`
2. **Must the attacker defeat a security measure** (ASLR, DEP) or get a
   target-specific secret? No → `AC:L` · yes → `AC:H`
3. **Does it depend on deployment or execution conditions** (a race to win, an
   on-path position, a non-default setting)? No → `AT:N` · yes → `AT:P`
4. **What access does the attacker need beforehand?**
   None → `PR:N` · regular user → `PR:L` · admin → `PR:H`
5. **Must a user do something?**
   No → `UI:N` · view a page or open a file → `UI:P` · click, confirm or install → `UI:A`
6. **What is compromised on the vulnerable system?** → `VC`, `VI`, `VA`
7. **Does it propagate to other systems?** → `SC`, `SI`, `SA`

> [!tip] AC and AT are not the same thing
> A common 4.0 scoring mistake is to mix them up, often by carrying over CVSS 3.1
> habits. `AC:H` is about *security measures* the attacker must defeat: ASLR, DEP, a
> secret to obtain. `AT:P` is about the *conditions* the target must be in: a race
> to win, an on-path position, a setting that happens to be enabled. A race
> condition was `AC:H` in 3.1; in 4.0 it is `AT:P`.

## Threat metrics

The Threat group holds a single metric, replacing the old Temporal group:

| Metric | Abbrev | Values |
| --- | --- | --- |
| **Exploit Maturity** | E | Not Defined (X), Unreported (U), PoC (P), Attacked (A) |

Append it when known:

```text
CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N/E:A
```

`E:A` (Attacked) means attacks have been reported. It gives the same score as
leaving `E` out, because Not Defined (`X`) counts as Attacked: the worst case. `E:P`
(proof of concept public) and `E:U` (Unreported) lower the score. With `E:U`, the
example above drops from 9.3 to 8.1. A score that includes threat metrics is called
CVSS-BT (Base + Threat).

## What the score does not tell you

A CVSS Base score describes the vulnerability, not your exposure to it. Treat it as
an input, not a verdict.

- **Base scores ignore your environment entirely.** A `9.8` in a component you do not
  deploy, or that is unreachable behind a network policy, is not a `9.8` for you.
  That is precisely what the Environmental metrics are for, and almost nobody fills
  them in.
- **Exploit availability matters more than severity.** A Medium with a public
  exploit and active scanning is a more urgent problem than a Critical nobody has
  ever weaponised. This is what `E:` is for — and why
  [EPSS](https://www.first.org/epss/) (probability of exploitation in the next 30
  days) and [CISA KEV](https://www.cisa.gov/known-exploited-vulnerabilities-catalog)
  are better prioritisation signals than CVSS alone.
- **"Not affected" is a real answer.** If a vulnerable function is never called, say
  so in a machine-readable way rather than arguing about the score — see
  [[security/supply-chain/vex|VEX]].

> [!warning] Do not build a policy on severity alone
> "Block anything High or above" is a common CI gate — see
> [[security/secure-container-images]] — and it is a reasonable *floor*, not a
> strategy. It will block on unreachable code paths and wave through the Medium that
> is being exploited today.

## Tools and references

- **FIRST CVSS 4.0 calculator** — <https://www.first.org/cvss/calculator/4.0>
  A vector appended as a fragment pre-fills it, which makes for shareable links:
  `https://www.first.org/cvss/calculator/4.0#CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N`
- **Specification** — <https://www.first.org/cvss/v4.0/specification-document>
- **User guide** — <https://www.first.org/cvss/v4.0/user-guide>
- **Python `cvss` library**:

  ```bash
  pip install cvss
  ```

  ```python
  from cvss import CVSS4

  v = CVSS4("CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N")
  print(v.base_score)   # 9.3
  print(v.severity)     # Critical
  ```

  An incomplete vector raises `CVSS4MandatoryError`, which makes the library a cheap
  check for vectors in a CI job or a VEX document.

## Where to go next

- [[security/secure-container-images]] — where these scores become a CI gate
- [[security/index|Security]] — the rest of this section

<!-- uplink -->
Part of [[security/index|Security]].
