---
title: sbomqs
description: Scoring SBOM quality — the categories, using it as a build gate, and why a compliant SBOM can still be useless
tags: [security, supply-chain, sbom, quality]
type: howto
status: complete
---

# sbomqs

[`sbomqs`](https://github.com/interlynk-io/sbomqs) scores the **quality** of an SBOM.
Not only whether it is valid — whether it is any good.

The distinction matters. A syntactically perfect CycloneDX document listing forty
components with no purls, no versions and no licences passes every validator and
answers no question you will ever ask it. sbomqs exists to catch that before it
matters.

## Installation

```bash
go install github.com/interlynk-io/sbomqs/v2@latest

# or
brew tap interlynk-io/interlynk && brew install sbomqs
```

Since version 2 the Go module path ends in `/v2`. Without it, `go install` fetches
the last 1.x release.

> [!note] sbomqs 2.x
> Version 2 (current: 2.1) changed the categories, the feature names, the output and
> the JSON fields. `--category NTIA-minimum-elements` from 1.x fails with "invalid
> category". The commands below are for 2.x. `--legacy` (`-e`) still gives the 1.x
> scoring.

## Scoring

```bash
sbomqs score sbom.json
```

The output starts with an overall score out of 10 and a letter grade, then a score
per compliance profile, per category, and per feature. Abridged, for a syft SBOM of
an Alpine image:

```text
SBOM Quality Score: 4.8/10.0	 Grade: F	Components: 96 	 EngineVersion: 8	File: alp.json

Industry Profile Overviews:
+--------------------------------+----------+-------+
|            PROFILE             |  SCORE   | GRADE |
+--------------------------------+----------+-------+
| Interlynk                      | 4.7/10.0 | F     |
| NTIA Minimum Elements (2026)   | 5.4/10.0 | D     |
| BSI TR-03183-2 v1.1            | 3.2/10.0 | F     |
+--------------------------------+----------+-------+

Category Breakdown:
+-------------------+--------+-----------+-------+
|     CATEGORY      | WEIGHT |   SCORE   | GRADE |
+-------------------+--------+-----------+-------+
| Identification    | 12.2%  | 7.1/10.0  | C     |
| Provenance        | 14.6%  | 5.5/10.0  | D     |
| Integrity         | 18.3%  | 8.1/10.0  | B     |
| Completeness      | 14.6%  | 3.0/10.0  | F     |
| Licensing         | 18.3%  | 0.2/10.0  | F     |
| Vulnerability     | 12.2%  | 1.6/10.0  | F     |
| Structural        | 9.8%   | 10.0/10.0 | A     |
+-------------------+--------+-----------+-------+
```

Filter to one category, or score against one compliance profile:

```bash
sbomqs score sbom.json --category identification
sbomqs score sbom.json --category licensing
sbomqs score sbom.json --profile ntia
```

## The categories

| Category | Asks |
| --- | --- |
| **Identification** | Do components have a name, a version, a local ID? |
| **Provenance** | Does the document say who made it, with what tool, and when? |
| **Integrity** | Do components have checksums? Is the SBOM signed? |
| **Completeness** | Is there a dependency graph, a primary component, a supplier per component? |
| **Licensing** | Do components have licences, as valid SPDX expressions? |
| **Vulnerability** | Do components carry a purl or a CPE, so a scanner can match them? |
| **Structural** | Is it schema-valid for its declared specification and version? |

The profiles check one baseline each. `ntia` is the US minimum elements as updated by
CISA (the draft of August 2025; sbomqs calls the profile "CISA 2026"). `ntia-2021` is
the original 2021 NTIA list: supplier, component name, version, unique identifier,
dependency relationships, author, timestamp. `bsi` is the German BSI TR-03183-2.

> [!important] The score to watch is unique identifiers
> `comp_with_purl_or_cpe`, in the Vulnerability category, measures whether
> components carry a purl or CPE. Anything below ~9 means a meaningful fraction of
> the SBOM cannot be automatically matched against a vulnerability database — which
> makes the whole document decorative. Every other criterion is secondary to this
> one.

## As a build gate

The point is to fail the pipeline when quality regresses, not to admire a number:

```bash
sbomqs score sbom.json --basic
```

`--basic` prints one line: score, grade, profile, spec version, format, file.

```yaml
- name: Generate SBOM
  run: syft "myregistry/myapp@${DIGEST}" -o cyclonedx-json=sbom.json

- name: Check SBOM quality
  run: |
    SCORE=$(sbomqs score sbom.json --json | jq -r '.files[0].sbom_quality_score')
    echo "SBOM score: $SCORE"
    awk -v s="$SCORE" 'BEGIN { exit (s >= 7.0) ? 0 : 1 }' || {
      echo "SBOM quality below threshold"; exit 1;
    }
```

> [!tip] Gate on regression, not on an absolute number
> Teams set a threshold of 7, hit 6.9 for reasons outside their control — an upstream
> image whose components lack suppliers — and disable the check. Recording the score
> and failing when it **drops** is more durable, because it catches the real event:
> the day your generator silently stops emitting purls after a tooling upgrade.

## Comparing and listing

```bash
sbomqs score sbom-old.json sbom-new.json     # score several at once
sbomqs list --feature comp_with_licenses --missing sbom.json
```

That second command is the practically useful one: rather than telling you the licence
score is 0.2, it lists exactly which components are missing a licence, so you can go
and look at why.

## What a low score usually means

| Symptom | Likely cause |
| --- | --- |
| Low `comp_with_purl_or_cpe` | Generator scanning binaries it cannot attribute to a package — C and C++ binaries, vendored code, files copied in by hand. Go binaries are usually fine: syft reads their embedded build information |
| Low `comp_with_supplier` | Base image components; upstream distributions often omit supplier data |
| Low `comp_with_valid_licenses` | Free-text licence strings instead of SPDX expressions |
| Very few components | Scanning the wrong target — a compressed layer, or a `scratch` image where there genuinely is nothing but your binary |

That last row is worth internalising: on a `scratch` image, a nearly empty SBOM is
**correct**, and reflects the small attack surface you deliberately built. See
[[security/secure-container-images]]. Do not chase the score by adding an OS just to
populate it.

## Where to go next

- [[security/supply-chain/sbom]] — what should be in one
- [[security/supply-chain/sbomasm]] — fixing and assembling SBOMs
- [[security/supply-chain/sbom-lifecycle]] — where this gate sits in a pipeline

<!-- uplink -->
Part of [[security/supply-chain/index|Supply chain]].
