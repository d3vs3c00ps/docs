---
title: Secure container images
description: Guidelines for building and shipping container images — minimal base images, rootless execution, multi-stage builds, signing, scanning and runtime hardening
tags: [security, containers, supply-chain, kubernetes, hardening]
type: reference
status: complete
---

# Secure container images

A set of guidelines for building and deploying container images, written as
requirement / guideline / rationale so each rule can be argued with rather than
just obeyed.

This is the policy layer. See [[containers/security]] for the mechanics of hardening
a container at run time, and [[kubernetes/security/pod-security-admission]] for how
Kubernetes enforces several of these rules at admission.

## Base image selection

### Requirement

Choose the most minimal base image that satisfies the application's runtime
requirements. Prefer, in order:

1. **`scratch`** — for fully statically linked binaries with no runtime
   dependencies.
2. **Chainguard distroless** — for binaries needing a minimal libc or runtime.
3. **General-purpose distroless** (e.g. `gcr.io/distroless`) — as an exception when
   Chainguard does not offer the required runtime.

General-purpose OS base images (Ubuntu, Debian, Alpine, CentOS) require written
justification and security review.

### Guidelines

- Use `scratch` (Docker's empty base) for fully statically compiled binaries that
  bundle all dependencies — Go with `CGO_ENABLED=0`, Rust with musl. If the binary
  needs to verify TLS connections or handle timezones, copy the CA trust store and
  timezone database from the build stage. These are pre-built system files, not
  generated certificates:

```dockerfile
FROM golang:1.27 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /app/myservice .

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=build /app/myservice /myservice
USER 65532:65532
ENTRYPOINT ["/myservice"]
```

`scratch` has no default command and no users: set `ENTRYPOINT`, and a numeric `USER`
(see [[#Rootless execution]]).

> [!tip] No cert-donor stage needed
> Adding a dedicated Alpine or Debian stage purely to source certificates is
> unnecessary — the build stage already contains them. The result is the smallest
> possible image: zero OS packages, zero base-layer CVE surface.

- When the binary requires a C library or DNS resolution at run time, use a
  [Chainguard](https://www.chainguard.dev/) image:
  - [`static`](https://images.chainguard.dev/directory/image/static/overview)
    (`cgr.dev/chainguard/static`) — an alternative to `scratch` plus a manual cert
    copy, providing managed ca-certificates and tzdata with SBOM coverage and daily
    rebuilds. Prefer this when the CA trust store should receive updates
    independently of application rebuilds.
  - The appropriate runtime image (`cgr.dev/chainguard/node`,
    `cgr.dev/chainguard/python`) for interpreted languages. Both are distroless by
    default.
  - The free public images are only the `:latest` and `:latest-dev` tags. Pinned
    version tags need a Chainguard subscription, so pin the free ones by digest.
- Use the Chainguard development (`-dev`) variant **only** in build stages, never in
  the final image.
- Always minimise the image by removing unused packages, caches and documentation.
- Track exception decisions in a table or an issue, with a review date.

### Rationale

`scratch` is the ideal base: zero packages means zero CVEs inherited from the base
layer. When `scratch` is not viable, Chainguard images are the next best option —
rebuilt daily from source, minimal package sets, build-time SBOMs and timely CVE
patches. This is a large reduction in vulnerability surface compared with a
traditional base image.

## Rootless execution

### Requirement

Containers must not run as root. The image and the Kubernetes pod specification must
both enforce non-root execution.

### Guidelines

- Set a numeric non-root `USER` in the Dockerfile. Chainguard images default to a
  non-root user — do not override it back to root.
- In Kubernetes manifests, enforce it via `securityContext`:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 65532        # Chainguard nonroot UID
  runAsGroup: 65532
  allowPrivilegeEscalation: false
```

- Apply a Pod Security Standard of `restricted` at the namespace level as the default
  for application workloads.
- Platform components that genuinely require elevated privileges — `hostPID`,
  `hostPath`, `privileged` — must run in dedicated namespaces labelled `baseline` or
  `privileged`, and **every exemption must be documented with a justification and a
  review date**. Workload classes that typically need one:
  - node-level maintenance jobs that use `nsenter` to act on the host;
  - DaemonSets that drive vendor storage or hardware tooling through `hostPath`;
  - bootstrap or machine-configuration controllers that talk to a host socket;
  - registry or image-distribution agents that need host filesystem access.

  Keep this list short and audited. Each entry is a permanent hole in the default
  policy.

### Rationale

Running as root inside a container grants privileges that become useful to an
attacker during a container escape or lateral movement. Pod Security Standards
enforce the rule cluster-side, so it cannot be forgotten in a single manifest. The
`restricted` profile is the target for all application workloads; isolating the few
genuinely privileged components in their own namespaces limits the blast radius
while keeping the default strict.

## Minimal attack surface

### Requirement

Production images must not contain tools or binaries beyond what is strictly
required to run the application.

### Guidelines

- No interactive shells (`/bin/sh`, `/bin/bash`). Chainguard production images
  (non-`-dev`) ship without one — do not add it back.
- No `sudo`, `su`, or any setuid/setgid binary.
- No `systemd`, `cron`, `init` or any process supervisor. One container runs exactly
  one process, managed by the container runtime.
- No package managers (`apk`, `apt`, `yum`, `pip`, `npm`) in the final image. Install
  dependencies in a build stage only.
- No debugging tools (`curl`, `wget`, `netcat`, `strace`, `tcpdump`). Use ephemeral
  debug containers (`kubectl debug`) when you need them.
- Do not use the Dockerfile `HEALTHCHECK` instruction. Kubernetes ignores it, and it
  costs a process spawn per interval for nothing. Use liveness, readiness and startup
  probes instead — see [[kubernetes/observability/healthchecks]].

### Rationale

Every binary in an image is a potential tool for an attacker who already has code
execution. Removing them eliminates whole classes of post-exploitation technique:
reverse shells, local privilege escalation, data exfiltration.

## Image build

### Requirement

Use multi-stage builds. The final image must contain only the application artifact
and its runtime dependencies.

### Guidelines

- Separate build-time dependencies (compilers, build tools, test frameworks) from the
  runtime image using multi-stage builds.
- Pin all base image references **by digest** in production Dockerfiles, for your own
  images as much as for external ones. Mutable tags (`:latest`, `:dev`) are fine in
  development and in CI build stages, but the final `FROM` in a release Dockerfile
  must use a digest.

```dockerfile
# Production: pinned by digest
FROM cgr.dev/chainguard/node:latest@sha256:abc123... AS build

# Development only: mutable tag acceptable in local/CI builds
FROM cgr.dev/chainguard/node:latest AS build
```

- Run a Dockerfile linter such as [Hadolint](https://github.com/hadolint/hadolint) in
  CI to catch misconfigurations before the build runs.
- Always use `COPY`, never `ADD`. `ADD` will silently fetch remote URLs and extract
  archives, which can pull unexpected files into the image.
- Tag published images with immutable identifiers (Git commit SHA, or a semantic
  version like `v1.2.3`). A mutable `:latest` may be published alongside for
  convenience, but production deployments and Helm charts must reference a digest or
  an immutable tag.
- Never embed secrets — credentials, API keys, certificates — in image layers. Use
  Kubernetes Secrets, a secret store, or BuildKit's `--secret`, which is not
  persisted into the layer.
- Use `.dockerignore` so source code, git history and local configuration never enter
  the build context.

### Rationale

Multi-stage builds keep the attack surface limited to runtime dependencies. Pinning
by digest in production prevents silent upstream changes — a mutable tag can be
re-pushed at any time, introducing vulnerabilities or breaking changes without any
commit on your side. Allowing mutable tags in development preserves velocity without
compromising production reproducibility.

> [!warning] Secrets in layers are permanent
> A secret written into a layer stays recoverable from the image history even if a
> later layer deletes it. Rotating the secret is the only remedy.

## Image signing and verification

### Requirement

Sign all images before publishing. Verify signatures before deployment.

### Guidelines

- Sign with [cosign](https://docs.sigstore.dev/cosign/overview/) using a key pair
  managed by an internal PKI. Keep the private key in a KMS or HSM — AWS KMS,
  HashiCorp Vault Transit, or a hardware HSM — never as a plain file in CI. cosign
  supports KMS-backed keys natively:

```bash
# Generate a key pair in KMS (one-time setup)
cosign generate-key-pair --kms <provider>://<key-reference>

# Sign in CI using the KMS-backed key, by digest, with no public log
cosign sign --key <provider>://<key-reference> --signing-config no-tlog.json \
  "myregistry/myapp@${DIGEST}"
```

> [!warning] Correction
> The note signed `myregistry/myapp:1.2.3`, a tag. Sign the digest: a tag can move
> after signing (see [[security/supply-chain/cosign]]). And since cosign v3, a key
> signature also goes to the **public** Rekor log by default. For a private PKI with
> no external service, sign with a signing config that has no log
> (`cosign signing-config create --out no-tlog.json`), and verify with
> `--insecure-ignore-tlog=true`.

- Distribute the public key to every verification point: admission controllers, build
  pipelines. It can live in the repository or be distributed by the internal PKI.
- Store signatures in the same OCI registry as the image.
- Enforce verification at admission time with a policy engine — a Kyverno
  `ImageValidatingPolicy` (see [[security/supply-chain/cosign#Verifying at admission]])
  or the Sigstore Policy Controller — configured with that public key. The older
  `ClusterPolicy` `verifyImages` rule is deprecated, and did not read cosign v3
  signatures in our test.
- Chainguard images are already signed; verify them in your build pipeline before
  using them as a base.
- Publish [SLSA](https://slsa.dev/) provenance attestations alongside the image, to
  prove the build's origin, environment and instructions.

### Rationale

An internal PKI with KMS-backed keys gives full control of the trust chain, works in
air-gapped environments, and depends on no external service (Fulcio, Rekor, an OIDC
provider). Signing establishes a verifiable chain from build to deployment; without
admission-time verification, a compromised registry can simply serve a malicious
image and nothing will object.

## Vulnerability scanning

### Requirement

Scan every image for known vulnerabilities in CI before publishing. Block images
carrying fixable Critical or High severity CVEs.

### Guidelines

- Use [Grype](https://github.com/anchore/grype) as the primary image scanner in CI.
- Fail the pipeline on fixable vulnerabilities of severity High or above.
- For unfixable vulnerabilities, document the accepted risk and set a review date.
- Upload the scan report and the image SBOM to a monitoring service such as
  [Dependency-Track](https://dependencytrack.org/), which continuously re-evaluates
  stored SBOMs against newly disclosed CVEs. The full loop is in
  [[security/supply-chain/sbom-lifecycle]].
- Suppress findings that genuinely do not apply with
  [[security/supply-chain/vex|VEX]], rather than by re-deciding them every scan.

### Rationale

Scanning at build time keeps known-vulnerable images out of production. Continuous
monitoring covers the rest: an image that was clean when built does not stay clean,
and re-scanning the SBOM catches that without rebuilding.

Severity alone is a poor gate — see [[security/cvss]] for what a CVSS score does and
does not tell you about your own exposure.

## Runtime hardening

### Requirement

Apply Kubernetes security controls to every container workload.

### Guidelines

- Drop all Linux capabilities and add back only those genuinely required:

```yaml
securityContext:
  capabilities:
    drop: ["ALL"]
    add: []  # only add specific caps with justification
```

- Set resource limits (`resources.limits.cpu`, `resources.limits.memory`) on every
  container, so one workload cannot exhaust a node. See
  [[kubernetes/observability/resource-limits]].
- Apply a `seccompProfile` of type `RuntimeDefault` at minimum:

```yaml
securityContext:
  seccompProfile:
    type: RuntimeDefault
```

- Do not set `privileged: true`. No exception.
- Do not use `hostNetwork`, `hostPID` or `hostIPC` without a documented, approved
  exception.
- Do not mount the service account token unless the pod actually calls the Kubernetes
  API — set `automountServiceAccountToken: false`.
- Set `readOnlyRootFilesystem: true`. Where a process must write temporary data
  (caches, sockets, PID files), mount just those paths as `emptyDir` volumes.
  Persistent volumes for stateful workloads are expected and do not conflict with a
  read-only root.

### Rationale

These controls are defence in depth. Even with application code compromised, the
blast radius is bounded by capability restrictions, resource limits, syscall
filtering, and a root filesystem that cannot be modified at run time.

## Where to go next

- [[containers/security]] — hardening at the engine level, outside Kubernetes
- [[security/cvss]] — reading severity scores without over-trusting them
- [[security/supply-chain/index|Supply chain]] — cosign, SBOMs, VEX and GUAC in depth
- [[kubernetes/security/pod-security-admission]] — enforcing the pod rules above
- [[kubernetes/security/kyverno]] — policy engine, including signature verification

<!-- uplink -->
Part of [[security/index|Security]].
