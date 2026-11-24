---
title: cosign troubleshooting
description: Why verification failed — missing signatures after a mirror, tag versus digest, expired certificates, air-gapped trust roots and registry permissions
tags: [security, supply-chain, cosign, troubleshooting]
type: reference
status: complete
---

# cosign troubleshooting

Verification failures are usually structural rather than cryptographic. Work down this
list before suspecting the signature itself. The commands are for cosign v3; see
[[security/supply-chain/cosign]] for what changed from v2.

## `no matching signatures`

The most common message, with the most causes.

**You verified a different digest than you signed.** Signing `:1.2.3` signs whatever
the tag pointed at then; if it moved, the signature is orphaned.

```bash
crane digest myregistry/myapp:1.2.3          # what the tag points at now
cosign tree myregistry/myapp:1.2.3           # what is attached to that digest
```

**The signature was not copied.** Signatures are separate OCI artifacts. Mirroring the
image alone leaves them behind. Copy the referrers too:

```bash
oras copy -r myregistry/myapp:1.2.3 internal-registry/myapp:1.2.3
```

> [!warning] Correction
> The note used `cosign triangulate` and `cosign copy`. Both are deprecated in
> cosign v3 (`triangulate` is to be removed in v4). `cosign tree` shows what is
> attached; `oras copy -r`, or `cosign save` then `cosign load`, copies an image with
> its signatures.

**Signed with no log, verified with the default.** A signature made with a signing
config that has no transparency log has no Rekor entry. A plain `cosign verify`
then fails with `not enough verified log entries from transparency log: 0 < 1`.
Add `--insecure-ignore-tlog=true`, and only for signatures you know were made that
way.

**Wrong key.** The public key does not match the private key that signed. With a KMS
key, re-export it — `cosign public-key --key "$KMS_KEY"` — rather than trusting a copy
in a repository that may predate a key rotation.

**Signed with keyless, verified with a key,** or the reverse. The two paths are not
interchangeable; keyless verification needs `--certificate-identity` and
`--certificate-oidc-issuer`.

List what is actually attached before theorising:

```bash
cosign tree myregistry/myapp@sha256:abc123...
```

That prints signatures, attestations and attachments for the digest, and usually ends
the investigation immediately.

## `error: certificate expired`

Fulcio certificates live about ten minutes, so this looks alarming and normally is
not.

> [!important] Expiry is expected; the transparency log is the answer
> Verification is supposed to check the signature against the certificate **as it was
> at signing time**, proven by the Rekor entry or a signed timestamp. Getting an
> expiry error means that proof is missing or not checked — for example because
> `--insecure-ignore-tlog` was passed to work around an earlier problem and then left
> in place.

With cosign v3, the Sigstore bundle carries the log entry, its inclusion proof and
the timestamp, so verification checks them against the trust root without calling
Rekor. Check that cosign has a current trust root (`cosign initialize`), or pass one
with `--trusted-root`.

## Air-gapped verification fails

Keyless verification needs Fulcio's roots and Rekor. Neither is reachable from a
disconnected environment.

Mirror the trust root:

```bash
cosign initialize --mirror https://internal-tuf.example.com --root root.json
```

Or give `cosign verify` a trust root file directly: `--trusted-root trusted_root.json`.

Or, more simply, **use KMS-backed keys for anything that must verify offline**. This
is the reason an internal PKI remains the right default for air-gapped platforms —
see [[security/secure-container-images]].

## `UNAUTHORIZED` or `denied` when signing

Signing **writes** to the registry, because that is where the signature is stored. A
robot account with pull-only rights can build and verify but not sign.

```bash
cosign login myregistry -u "$USER" -p "$TOKEN"
```

Some registries also need the signature tags to be permitted by tag-immutability or
naming policies. With no OCI 1.1 referrers API, cosign v3 writes a fallback tag
`sha256-<digest>` and updates it on every new signature or attestation. The v2 layout
uses `sha256-<digest>.sig` and `.att`. A registry that rejects tags not matching a
semver pattern, or that makes tags immutable, will reject signatures.

## `unsupported media type` or the signature is invisible

Older registries and some proxies do not understand OCI artifact media types.
Symptoms: signing appears to succeed, `cosign tree` shows nothing.

```bash
COSIGN_DOCKER_MEDIA_TYPES=1 cosign sign --key cosign.key \
  --new-bundle-format=false --use-signing-config=false "myregistry/myapp@${DIGEST}"
```

This writes the v2 layout with Docker media types. Prefer upgrading the registry —
the fallback is a compatibility shim, not a fix.

> [!warning] Correction
> The note showed `COSIGN_DOCKER_MEDIA_TYPES=1` alone. In cosign v3 it changes
> nothing on its own: the default v3 layout is always an OCI index. It applies only
> together with `--new-bundle-format=false --use-signing-config=false`.

## Kyverno admits an unsigned image

Two usual causes:

- **`validationActions: [Audit]`** rather than `[Deny]` (in an old `ClusterPolicy`:
  `failureAction: Audit` rather than `Enforce`). It is logging the violation and
  admitting the pod, which is correct for a rollout and wrong for a finished policy.
- **The image pattern does not match.** The glob `myregistry/*` does not match
  `myregistry.example.com/team/myapp`. Test the pattern against the exact string in
  the pod spec, including registry host and any path segments.
- **An old `ClusterPolicy` and cosign v3 signatures.** In our test, the Kyverno 1.19
  `verifyImages` rule found no signature in the cosign v3 layout. Use an
  `ImageValidatingPolicy` — see [[security/supply-chain/cosign#Verifying at admission]].

```bash
kubectl get events -n <namespace> --field-selector reason=PolicyViolation
```

## `verify-attestation` passes but the predicate is wrong

`cosign verify-attestation` without `--policy` checks only that a signed attestation
of that type exists. It does not look at the content.

```bash
# Proves an SBOM attestation exists and is signed — nothing more
cosign verify-attestation --key cosign.pub --type cyclonedx "$IMG"

# Actually checks what it says
cosign verify-attestation --key cosign.pub --type cyclonedx --policy no-gpl.rego "$IMG"
```

See [[security/supply-chain/cosign-advanced]].

## Debugging generally

```bash
cosign tree "$IMG"                    # what is attached
cosign verify --verbose ...           # debug output (-d for short)
crane ls myregistry/myapp             # every tag, including sha256-<digest> fallback tags
crane manifest myregistry/myapp:sha256-<digest>   # the referrers in the fallback tag
```

The tag list is quietly the most useful: seeing the `sha256-<digest>` tag (or
`sha256-<digest>.sig` for the v2 layout) present or absent answers the question
directly. A registry with the OCI 1.1 referrers API has no such tag: use
`cosign tree` or `oras discover`.

> [!warning] Correction
> The note used `COSIGN_VERBOSE=true`. cosign has no such variable; the flag is
> `--verbose` (`-d`).

## Where to go next

- [[security/supply-chain/cosign]] — signing and verification basics
- [[security/supply-chain/cosign-advanced]] — keyless, attestations, policies
- [[kubernetes/security/kyverno]] — the admission side

<!-- uplink -->
Part of [[security/supply-chain/index|Supply chain]].
