---
title: cosign
description: Signing and verifying container images — key pairs, what actually gets stored in the registry, and verifying at admission
tags: [security, supply-chain, cosign, sigstore, containers]
type: howto
status: complete
---

# cosign

[cosign](https://docs.sigstore.dev/cosign/overview/) signs and verifies container
images and other OCI artifacts. It is part of [Sigstore](https://www.sigstore.dev/),
alongside Fulcio (a certificate authority) and Rekor (a transparency log).
This note is for cosign v3 (v3.0 came out in October 2025).

The problem it solves: a registry proves an image exists at a tag. It proves nothing
about **who built it**. Anyone who can write to the registry can replace the contents
of a tag, and a digest only tells you bytes did not change — not that the right party
produced them.

## Installation

```bash
brew install cosign

# or
go install github.com/sigstore/cosign/v3/cmd/cosign@latest

# or the container image (multi-arch)
docker run --rm ghcr.io/sigstore/cosign/cosign:v3.1.4 version
```

> [!note] The v3 module path
> Since v3.0 the Go module is `github.com/sigstore/cosign/v3`.
> `go install github.com/sigstore/cosign/v2/...` installs the old v2 line.

## Key-based signing

Generate a key pair:

```bash
cosign generate-key-pair
# → cosign.key (encrypted with a passphrase) and cosign.pub
```

Sign an image:

```bash
cosign sign --key cosign.key myregistry/myapp@sha256:abc123...
```

Verify it:

```bash
cosign verify --key cosign.pub myregistry/myapp@sha256:abc123...
```

> [!warning] A key signature also goes to the public Rekor log
> Since cosign v3, `cosign sign --key` takes its services from the public Sigstore
> signing config. It uploads the signature, the public key and the image digest to
> the public Rekor log, after a confirmation prompt (`--yes` skips it). Without a
> terminal, the prompt counts as "no" and signing fails. For a private image, give
> cosign a signing config with no log, and tell `verify` that there is no log entry:
>
> ```bash
> cosign signing-config create --out no-tlog.json
> cosign sign --key cosign.key --signing-config no-tlog.json myregistry/myapp@sha256:abc123...
> cosign verify --key cosign.pub --insecure-ignore-tlog=true myregistry/myapp@sha256:abc123...
> ```
>
> The old flag `--tlog-upload=false` is deprecated, and refused together with a
> signing config. Without a log, nobody can prove *when* you signed, so the key
> must stay valid as long as the signatures.

> [!danger] Always sign the digest, never the tag
> `cosign sign --key cosign.key myregistry/myapp:1.2.3` resolves the tag and signs
> whatever it points at *right now*. If the tag is later re-pushed, the signature
> still exists but refers to the old digest. Verifying the tag also resolves it at
> that moment: it checks the image the tag points to *then*, not the image a node
> pulls a minute later.
>
> Resolve the digest explicitly and use it everywhere:
>
> ```bash
> DIGEST=$(crane digest myregistry/myapp:1.2.3)
> cosign sign --key cosign.key "myregistry/myapp@${DIGEST}"
> ```

## Where the signature lives

cosign stores the signature **in the registry itself**, as a separate OCI artifact.
Nothing extra to host. Since v3, the signature is a Sigstore bundle, pushed as an
**OCI 1.1 referrer** of the image digest. A registry without the referrers API gets
the fallback the OCI spec defines: an index under the tag `sha256-abc123...` (no
suffix) that lists the referrers.

```bash
cosign tree myregistry/myapp@sha256:abc123...
# └── 🔗 https://sigstore.dev/cosign/sign/v1 artifacts via OCI referrer: myregistry/myapp@sha256:...
```

> [!note] The v2 layout
> A signature under the tag `sha256-<digest>.sig` is the cosign v2 layout. cosign v3
> still reads it, and writes it only with
> `--new-bundle-format=false --use-signing-config=false`. `cosign triangulate`, which
> finds that tag, is deprecated (removal planned in v4): use `cosign tree`, or
> `oras discover`.

> [!note] Mirroring can silently drop signatures
> Because the signature is a *separate* artifact, a mirroring process that copies only
> the image tag leaves it behind, and verification then fails in the air-gapped
> environment for reasons that look nothing like the cause. Copy the image together
> with its signatures and attestations, through a directory (for an air gap) or with
> `oras copy -r`:
>
> ```bash
> cosign save --dir ./myapp-signed "myregistry/myapp@${DIGEST}"
> cosign load --dir ./myapp-signed internal-registry/myapp
> # or, registry to registry
> oras copy -r myregistry/myapp:1.2.3 internal-registry/myapp:1.2.3
> ```
>
> `cosign copy` did this in v2. It is deprecated in v3.

## KMS-backed keys

A private key on disk in CI is a private key that will eventually leak. cosign talks
to KMS (Key Management Service) providers natively, so the key never leaves the
provider's HSM (Hardware Security Module):

```bash
cosign generate-key-pair --kms awskms:///alias/my-signing-key

cosign sign --key awskms:///alias/my-signing-key "myregistry/myapp@${DIGEST}"

cosign verify --key awskms:///alias/my-signing-key "myregistry/myapp@${DIGEST}"
```

Supported prefixes include `awskms://`, `gcpkms://`, `azurekms://`, `hashivault://`
and `k8s://` for a key in a Kubernetes Secret.

Export the public key once, and distribute that to verifiers — they need no access to
the KMS:

```bash
cosign public-key --key awskms:///alias/my-signing-key > cosign.pub
```

## Verifying at admission

Signing without verification is theatre. Enforce it in the cluster with a policy
engine — Kyverno's `ImageValidatingPolicy`:

```yaml
apiVersion: policies.kyverno.io/v1
kind: ImageValidatingPolicy
metadata:
  name: verify-image-signatures
spec:
  validationActions: [Deny]
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  matchImageReferences:
    - glob: "myregistry/*"
  attestors:
    - name: cosign
      cosign:
        key:
          data: |-
            -----BEGIN PUBLIC KEY-----
            ...
            -----END PUBLIC KEY-----
  validations:
    - expression: >-
        images.containers.map(image, verifyImageSignatures(image, [attestors.cosign])).all(e, e > 0)
      message: the image is not signed with our key
```

For a private signature with no Rekor entry, add this under `cosign:`, next to `key:`:

```yaml
        ctlog:
          insecureIgnoreTlog: true
          insecureIgnoreSCT: true
```

> [!warning] `verifyImages` misses cosign v3 signatures
> Kyverno 1.19 prints that `ClusterPolicy` is deprecated, in favour of the CEL (Common
> Expression Language) policy types such as `ImageValidatingPolicy`. In a test with
> the Kyverno 1.19.2 CLI, a `kyverno.io/v1` `verifyImages` rule found **no signature**
> on an image signed with cosign v3 defaults; it only verified the v2 layout. The
> `ImageValidatingPolicy` above verified both.

See [[kubernetes/security/kyverno]]. The Sigstore
[Policy Controller](https://docs.sigstore.dev/policy-controller/overview/) does the
same job if you would rather not run a general-purpose policy engine.

> [!important] Kyverno mutates the image reference to a digest
> When the verification passes, Kyverno rewrites the pod's image reference to the
> digest it verified (`validationConfigurations.mutateDigest`, on by default). That closes the window where a tag could be re-pushed between admission
> and the kubelet pulling — a genuinely important detail, and a reason to prefer
> admission-time verification over a CI-only check.

## Verifying third-party images

Images that are already signed can be verified before you use them as a base. For
keyless-signed upstream images you match on the identity rather than a key — see
[[security/supply-chain/cosign-advanced]]:

```bash
cosign verify \
  --certificate-identity 'https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  cgr.dev/chainguard/static
```

> [!warning] Never `--certificate-identity-regexp '.*'`
> With the GitHub issuer, `'.*'` accepts a signature from **any** GitHub Actions
> workflow, in any repository. Pin the exact workflow identity. To find it, run
> `verify` once with the regexp and read the `Subject` field of the output.

## Signing other artifacts

cosign is not limited to container images:

```bash
cosign sign-blob --key cosign.key myfile.tar.gz --bundle myfile.bundle
cosign verify-blob --key cosign.pub --bundle myfile.bundle myfile.tar.gz
```

Useful for release archives, Helm charts and SBOMs. `--bundle` is required in v3.
The same Rekor rule applies: add `--signing-config no-tlog.json` to `sign-blob`, and
`--insecure-ignore-tlog=true` to `verify-blob`, for a private file.

## Where to go next

- [[security/supply-chain/cosign-advanced]] — keyless signing, attestations, policies
- [[security/supply-chain/cosign-troubleshooting]] — when verification fails
- [[security/supply-chain/sbom-lifecycle]] — attesting an SBOM with cosign
- [[security/secure-container-images]] — where signing sits in the build

<!-- uplink -->
Part of [[security/supply-chain/index|Supply chain]].
