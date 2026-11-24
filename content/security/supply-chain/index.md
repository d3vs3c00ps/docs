---
title: "Supply chain"
description: "Knowing what is in an artifact, who built it, and whether that still matters — SBOMs, signatures, provenance and VEX."
tags: [supply-chain]
type: moc
status: complete
---

<!-- generated-moc -->

# Supply chain

Knowing what is in an artifact, who built it, and whether that still matters — SBOMs, signatures, provenance and VEX.


| Note | | What it covers |
| --- | --- | --- |
| [[security/supply-chain/cosign-advanced\|cosign — keyless signing and attestations]] | concept | Identity-based signing with Fulcio and Rekor, in-toto attestations, SLSA provenance, and policies that verify more than a signature |
| [[security/supply-chain/cosign-troubleshooting\|cosign troubleshooting]] | reference | Why verification failed — missing signatures after a mirror, tag versus digest, expired certificates, air-gapped trust roots and registry permissions |
| [[security/supply-chain/cosign\|cosign]] | how-to | Signing and verifying container images — key pairs, what actually gets stored in the registry, and verifying at admission |
| [[security/supply-chain/guac\|GUAC]] | concept | Graph for Understanding Artifact Composition — ingesting SBOMs, attestations and VEX into one queryable graph that answers "where is this actually running? |
| [[security/supply-chain/sbom-lifecycle\|SBOM lifecycle]] | how-to | Generate, attest, store, monitor and act — the operational loop that turns an inventory into a control |
| [[security/supply-chain/sbom\|SBOMs]] | concept | What a software bill of materials is, SPDX versus CycloneDX, how one is produced, and the gap between having an SBOM and being able to use it |
| [[security/supply-chain/sbomasm\|sbomasm]] | how-to | Assembling several SBOMs into one and editing metadata — for products built from multiple components, and for fixing what the generator left out |
| [[security/supply-chain/sbomqs\|sbomqs]] | how-to | Scoring SBOM quality — the categories, using it as a build gate, and why a compliant SBOM can still be useless |
| [[security/supply-chain/vex\|VEX]] | concept | Saying "not affected" in a way machines understand — statuses, justifications, vexctl, and why this is what makes scanning sustainable |

Part of [[security/index|Security]].
