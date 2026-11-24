---
title: SBOMs
description: What a software bill of materials is, SPDX versus CycloneDX, how one is produced, and the gap between having an SBOM and being able to use it
tags: [security, supply-chain, sbom, compliance]
type: concept
status: complete
---

# SBOMs

A **Software Bill of Materials** is an inventory of what is inside a piece of
software: every component, its version, and ideally where it came from and under what
licence.

The motivating question is embarrassingly simple and, without an SBOM, embarrassingly
hard: *when a vulnerability is announced in some library, which of the things we run
contain it?* Organisations that could not answer that within a working day is what
made SBOMs a regulatory topic rather than a nice-to-have.

## What is in one

| Field | Why it matters |
| --- | --- |
| Component name and version | The minimum needed to match against a vulnerability feed |
| **Package URL (purl)** | An unambiguous identifier — `pkg:npm/lodash@4.17.21`. Names alone collide across ecosystems |
| Supplier / author | Provenance, and who to ask |
| Licence | The other reason legal teams want SBOMs |
| Hashes | Lets you verify the component is what it claims |
| Dependency relationships | Distinguishes a direct dependency from something six levels down |

> [!important] The identifier is the whole game
> An SBOM listing "openssl 3.0.2" is nearly useless — is that the Debian package, the
> Alpine one, a vendored copy, a static link? A **purl** or a **CPE** makes the entry
> machine-matchable against a vulnerability database. An SBOM whose components lack
> identifiers will score badly and cannot be automatically scanned. See
> [[security/supply-chain/sbomqs]].

## The two formats

| | SPDX | CycloneDX |
| --- | --- | --- |
| Origin | Linux Foundation | OWASP |
| Standard | ISO/IEC 5962 | ECMA-424 |
| Historical focus | Licence compliance | Security and vulnerability analysis |
| Serialisations | JSON, YAML, RDF, tag-value | JSON, XML, protobuf |
| Also carries | — | VEX statements, and vulnerability data inline |

Both are now capable general-purpose formats and both are accepted wherever SBOMs
are required. Practical guidance: **pick one and be consistent**, because converting
between them is lossy. If security tooling is the driver, CycloneDX has the smoother
path — it can carry [[security/supply-chain/vex|VEX]] in the same document. If
licence compliance is the driver, SPDX has the longer pedigree.

## Producing one

The two ways to generate an SBOM are not equivalent:

**At build time**, from the build system, which knows exactly what it resolved:

```bash
# Go
go version -m ./myapp
cyclonedx-gomod app -json -output sbom.json .

# Node
npm sbom --sbom-format cyclonedx
```

**After the fact**, by scanning a built artifact:

```bash
syft myregistry/myapp:1.2.3 -o cyclonedx-json=sbom.json
syft dir:. -o spdx-json=sbom.spdx.json
```

> [!tip] Build-time SBOMs are more accurate; scanned ones are more honest
> A build-time SBOM knows your declared dependency graph precisely, but it cannot see
> a binary someone `curl`ed into the image in a `RUN` step. A scanner looking at the
> finished image sees what is actually there, including things nobody declared —
> which is usually where the unpleasant surprises live.
>
> Generating both and comparing them is a genuinely useful control: the diff is a list
> of things that entered your image outside the dependency management system.

## Attaching it to the artifact

An SBOM in a CI job's artifacts directory will be lost in a month. Attach it to the
image so it travels with what it describes:

```bash
cosign attach sbom --sbom sbom.json myregistry/myapp:1.2.3
```

Better, sign it as an **attestation**, so consumers can verify both the content and
who produced it — see [[security/supply-chain/cosign-advanced]].

> [!warning] `cosign attach sbom` is deprecated
> cosign 3.1 still runs it, but prints a deprecation warning and points to SBOM
> attestations (`cosign attest --type cyclonedx`). An attached SBOM is not signed, so
> anyone who can push to the registry can replace it. Use the attestation.

## Where this usually fails

Producing SBOMs is a week of work. Making them useful is the part that gets skipped:

- **Generated, then never stored.** An SBOM only pays off when it can be queried
  months later, after a CVE lands. See [[security/supply-chain/sbom-lifecycle]].
- **Never re-evaluated.** The component list does not change, but the vulnerability
  landscape does. An artifact clean at build time is not clean forever.
- **No link to what is deployed.** Knowing that image `1.2.3` contains a vulnerable
  library does not tell you whether `1.2.3` is running anywhere.
  [[security/supply-chain/guac]] exists to close exactly that gap.
- **Poor quality, silently.** An SBOM with no purls, no licences and no relationships
  satisfies a contractual requirement and answers no questions.

> [!warning] "We produce SBOMs" is not a security control
> It is a prerequisite for one. The control is the ability to answer "where is this
> component running, and does it matter?" — which needs storage, continuous
> re-scanning, deployment correlation, and [[security/supply-chain/vex|VEX]] to
> suppress the findings that do not apply to you.

## Regulatory context

SBOMs moved from best practice to requirement through US Executive Order 14028 (2021)
and the NTIA minimum elements that followed it. CISA published an updated draft of
those minimum elements in August 2025. The EU Cyber Resilience Act requires
manufacturers of products with digital elements to draw up an SBOM, covering at least
the top-level dependencies; that obligation applies from 11 December 2027. If you sell
software in either market, this stops being optional.

## Where to go next

- [[security/supply-chain/sbom-lifecycle]] — generate, store, monitor, act
- [[security/supply-chain/sbomqs]] — scoring whether yours are any good
- [[security/supply-chain/sbomasm]] — assembling and editing them
- [[security/supply-chain/vex]] — saying "not affected", machine-readably
- [[security/secure-container-images]] — where SBOM generation fits in a build

<!-- uplink -->
Part of [[security/supply-chain/index|Supply chain]].
