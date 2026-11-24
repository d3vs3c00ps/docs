---
title: VEX
description: Saying "not affected" in a way machines understand — statuses, justifications, vexctl, and why this is what makes scanning sustainable
tags: [security, supply-chain, vex, vulnerability-management]
type: concept
status: complete
---

# VEX

**Vulnerability Exploitability eXchange** is a format for stating whether a product is
actually affected by a vulnerability its components contain.

The problem it addresses is the one that kills vulnerability programmes: a scanner
reports 400 CVEs against an image, most of which are genuinely not exploitable in that
context — the vulnerable function is never called, the affected code path is compiled
out, the component is present but unreachable. Without a way to record that judgement,
someone re-derives it on every scan, and eventually stops looking at the output at
all.

VEX turns "we looked at this and it does not apply" from tribal knowledge into a
signed, machine-readable document.

## The four statuses

| Status | Meaning |
| --- | --- |
| `not_affected` | The vulnerability is present in a component but cannot be exploited here |
| `affected` | Genuinely exploitable; remediation is needed |
| `fixed` | Was affected, has been remediated in this version |
| `under_investigation` | Not yet determined |

## Justifications

`not_affected` **requires** a reason: a justification from a fixed vocabulary, or a
free-text impact statement. Prefer the justification — the fixed vocabulary is what
stops it becoming a rubber stamp:

| Justification | Use when |
| --- | --- |
| `component_not_present` | The component is not actually in the artifact |
| `vulnerable_code_not_present` | The component is there, the vulnerable code is not |
| `vulnerable_code_not_in_execute_path` | Present, but never called |
| `vulnerable_code_cannot_be_controlled_by_adversary` | Reachable, but not with attacker-controlled input |
| `inline_mitigations_already_exist` | A compensating control is in place |

> [!important] The justification is the audit trail
> A free-text "we decided this is fine" is unreviewable. A justification of
> `vulnerable_code_not_in_execute_path` is a specific, falsifiable claim someone can
> check — and will be checked, when the CVE turns out to matter after all. Picking the
> justification honestly is the whole discipline.

## vexctl

[`vexctl`](https://github.com/openvex/vexctl) creates and merges
[OpenVEX](https://github.com/openvex) documents.

```bash
go install github.com/openvex/vexctl@latest
```

Create a statement:

```bash
vexctl create \
  --product="pkg:oci/myapp@sha256:abc123..." \
  --vuln="CVE-2026-1234" \
  --status="not_affected" \
  --justification="vulnerable_code_not_in_execute_path" \
  --file vex.json
```

Merge documents — one per team or per component — into a single view:

```bash
vexctl merge --product="pkg:oci/myapp@sha256:abc123..." \
  team-a.vex.json team-b.vex.json > merged.vex.json
```

Apply the VEX to a scan result, filtering out what has been ruled out. `vexctl filter`
reads SARIF only:

```bash
vexctl filter scan-results.sarif merged.vex.json
```

> [!note] VEX documents accumulate rather than replace
> A statement is a point-in-time assertion about a product and a vulnerability.
> Re-assessing later means adding a **new** statement with a later timestamp, not
> editing the old one — the history is part of the value. `vexctl merge` resolves a
> set of documents to the current status per vulnerability.

## Attaching VEX to an artifact

Like an SBOM, a VEX document is only useful where consumers can find it:

```bash
cosign attest --predicate merged.vex.json \
  --type openvex --key "$KMS_KEY" "myregistry/myapp@${DIGEST}"
```

See [[security/supply-chain/cosign-advanced]]. Signing matters more here than for an
SBOM: an unsigned VEX is an invitation for anyone to declare your vulnerabilities
inapplicable.

## In a scanning pipeline

```bash
grype sbom:./sbom.json --vex merged.vex.json -o json > actionable.json

# Gate on what is left
jq -e '[.matches[] | select(.vulnerability.severity == "High" or .vulnerability.severity == "Critical")] | length == 0' actionable.json
```

grype reads the VEX itself and moves the matches it rules out to `ignoredMatches`, so
the gate only sees what is left. Trivy does the same with `--vex`.

> [!warning] `vexctl filter` reads SARIF only
> On grype's JSON (`grype -o json`) it prints a SARIF document with no `.matches`, and
> a `jq` gate fails. Use the scanner's `--vex` flag, or give `vexctl filter` the SARIF
> output (`grype -o sarif`).

## Formats

There are three implementations of the concept, which is a mess:

| Format | Origin | Notes |
| --- | --- | --- |
| **OpenVEX** | OpenSSF | Minimal, standalone JSON. The easiest to produce; what `vexctl` emits |
| **CSAF VEX** | OASIS | Comprehensive and heavyweight. What large vendors publish |
| **CycloneDX VEX** | OWASP | Embedded in a CycloneDX SBOM, or standalone |

For your own artifacts, OpenVEX is the pragmatic choice. Expect to *consume* CSAF from
upstream vendors.

## Where this goes wrong

> [!warning] VEX is a tool for honesty, and works equally well for dishonesty
> Nothing validates a justification. A team under pressure to clear a dashboard can
> mark everything `not_affected` with a plausible-sounding reason and the numbers go
> green. Two defences: require the statement to name who made the assessment, and
> **review VEX statements the way you review code** — because that is what they are, a
> claim about your software's behaviour.

The second failure is staleness. `vulnerable_code_not_in_execute_path` is true until
someone adds a call to it. A VEX statement is tied to a product version; re-assess on
significant change rather than carrying assertions forward indefinitely.

## Where to go next

- [[security/supply-chain/sbom-lifecycle]] — where VEX fits in the loop
- [[security/cvss]] — why severity alone is a poor gate
- [[security/supply-chain/guac]] — correlating all of this with what is deployed

<!-- uplink -->
Part of [[security/supply-chain/index|Supply chain]].
