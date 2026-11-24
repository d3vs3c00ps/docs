---
title: sbomasm
description: Assembling several SBOMs into one and editing metadata — for products built from multiple components, and for fixing what the generator left out
tags: [security, supply-chain, sbom, tooling]
type: howto
status: complete
---

# sbomasm

[`sbomasm`](https://github.com/interlynk-io/sbomasm) assembles multiple SBOMs into
one, and edits SBOM metadata.

Two situations need it. First, a **product is rarely one artifact** — a release is a
backend image, a frontend bundle, a CLI and a Helm chart, each with its own SBOM,
while the customer wants one document for the product. Second, generators routinely
omit metadata they cannot infer: supplier, author, the product version as *you* number
it rather than as the build system saw it.

## Installation

```bash
go install github.com/interlynk-io/sbomasm/v2@latest

# or
brew tap interlynk-io/interlynk && brew install sbomasm
```

> [!warning] Correction
> This note was written for sbomasm 1.x. Version 2 (current: 2.1) has a `/v2` module
> path (without it, `go install` fetches 1.0.9), new names for the assembly flags, and
> no `-i` flag: `edit` takes the input file as its last argument. The commands below
> are for 2.x.

## Assembling

```bash
sbomasm assemble \
  -n "my-product" -v "2.1.0" -t "application" \
  -o product.cdx.json \
  backend.cdx.json frontend.cdx.json cli.cdx.json
```

`-n`, `-v` and `-t` describe the **primary component** — the thing being assembled —
under which the inputs become dependencies.

### Assembly modes

| Flag | Result |
| --- | --- |
| `-m`, `--hierMerge` | Default. Each input stays one component, with its own packages nested inside it |
| `-f`, `--flatMerge` | Everything becomes a flat list under the primary component |
| `-a`, `--assemblyMerge` | Inputs are merged as siblings, without implying dependency |
| `--augmentMerge` | Components are merged into an existing primary SBOM (`-p`), with no new root |

> [!important] Hierarchical preserves the information you will want later
> Flattening answers "what is in this product". Hierarchical also answers "**which
> part** of the product contains it", which is the question during an incident, when
> you need to know whether the affected component is in the internet-facing frontend
> or the internal CLI. Only flatten when a consumer specifically requires it.

Inputs must share a format — assemble CycloneDX with CycloneDX, SPDX with SPDX.
Converting between them first is lossy; see [[security/supply-chain/sbom]].

## Editing

The other half of the tool, and the one used more often:

```bash
sbomasm edit --subject document \
  --author "Platform Team (platform@example.com)" \
  --supplier "Example Corp (security@example.com)" \
  --tool "syft (1.56.0)" \
  -o sbom-enriched.json sbom.json
```

Subjects are `document` for the SBOM's own metadata, `primary-component` for the thing
it describes, or `component-name-version` to target one component:

```bash
sbomasm edit --subject primary-component \
  --version "2.1.0" \
  --license "Apache-2.0" \
  -o sbom-fixed.json sbom.json

sbomasm edit --subject component-name-version \
  --search "somelib (1.0.0)" \
  --supplier "Upstream Project (security@upstream.example.com)" \
  -o sbom-fixed.json sbom.json
```

`--append` adds to an existing field rather than replacing it; the default is to
overwrite. `--missing` edits only fields that are empty. Names with a contact are
written `name (email)`.

## Fixing what the generator missed

This is the pragmatic pairing with [[security/supply-chain/sbomqs]]: score, find the
missing fields, add them, re-score.

```bash
sbomqs score sbom.json --category provenance
# low: the generator recorded no author and no supplier for the document

sbomasm edit --subject document \
  --supplier "Example Corp (security@example.com)" \
  --author "Platform Team (platform@example.com)" \
  -o sbom.json.tmp sbom.json && mv sbom.json.tmp sbom.json

sbomqs score sbom.json --category provenance
```

Editing the `document` raises the document-level checks only. It does not fill
`comp_with_supplier`, which looks at each component: that needs
`--subject component-name-version`, one component at a time, and only where you know
the answer.

> [!warning] Only add metadata you actually know
> It is trivially easy to raise a compliance score by asserting a supplier for every
> component, and doing so is worse than the low score — a downstream consumer will
> believe it. Fill in what you genuinely know (your own supplier, author, version) and
> leave the rest missing and visibly missing. An SBOM's value is that it is true.

## In a release pipeline

```yaml
- name: Assemble the product SBOM
  run: |
    sbomasm assemble \
      -n "${PRODUCT}" -v "${RELEASE_VERSION}" -t application \
      --hierMerge \
      -o product.cdx.json \
      artifacts/*/sbom.cdx.json

- name: Stamp our metadata
  run: |
    sbomasm edit --subject document \
      --author "Platform Team (platform@example.com)" \
      --supplier "Example Corp (security@example.com)" \
      -o product.cdx.json.tmp product.cdx.json
    mv product.cdx.json.tmp product.cdx.json

- name: Quality gate
  run: sbomqs score product.cdx.json --basic

- name: Sign and publish
  run: cosign attest --predicate product.cdx.json --type cyclonedx --key "$KMS_KEY" "$IMAGE_DIGEST"
```

Sign the assembled document, not just the per-artifact ones — see
[[security/supply-chain/cosign-advanced]].

## Where to go next

- [[security/supply-chain/sbomqs]] — finding what needs fixing
- [[security/supply-chain/sbom]] — formats and required fields
- [[security/supply-chain/sbom-lifecycle]] — the surrounding loop

<!-- uplink -->
Part of [[security/supply-chain/index|Supply chain]].
