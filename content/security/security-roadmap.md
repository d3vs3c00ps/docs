---
title: Building a security roadmap
description: How to sequence security work for a Kubernetes platform — the domains worth covering, what to do first, and the tooling for each
tags: [security, kubernetes, planning, supply-chain, hardening]
type: concept
status: complete
---

# Building a security roadmap

Security work on a platform tends to arrive as a list of disconnected items: a
benchmark someone ran, a CVE that made the news, an auditor's finding. A roadmap is
what turns that into an order of work.

This note is about **how to sequence it**, and the vendor-neutral tooling for each
domain. It is deliberately generic — the right roadmap depends on what you are
running and what your threat model actually is.

> [!note] Not tested locally
> Concept note, nothing to run. The tool links were checked in November 2026.

## The ordering principle

Two rules, in tension, decide almost everything:

1. **Prevention before detection.** A control that makes a class of problem
   impossible is worth more than an alert saying it happened. Pod Security Admission
   beats a runtime alert about a privileged container.
2. **Visibility before enforcement.** You cannot safely block what you have not
   measured. Every enforcement control needs an audit-only phase first, or it takes
   production down.

The resolution is to build each control in two stages — observe, then enforce — and
to prioritise controls by how permanently they close a gap.

> [!tip] Sequence by blast radius, not by severity
> The instinct is to work the CVE list top-down. Resist it. A single admission
> policy that prevents privileged pods removes a whole category of escalation
> permanently; patching one Critical removes exactly one. Structural controls first,
> then the backlog.

## Domain 1 — Host and OS baseline

The foundation everything else assumes. Usually the least glamorous and the highest
return.

| Work item | Tooling |
| --- | --- |
| Automated CIS / SCAP compliance scanning | [OpenSCAP](https://www.open-scap.org/), `oscap-podman` for images |
| Mandatory access control enabled and enforcing | [[security/selinux]], or AppArmor |
| Kernel audit rules, tuned | [[security/auditd]] |
| File integrity monitoring on critical paths | [AIDE](https://aide.github.io/), or a runtime agent |
| Measured boot and disk encryption | [[security/boot-integrity/index|boot integrity]] |
| Reproducible, minimal host image | an immutable distribution removes most of this domain outright |

> [!note] Immutable hosts change the calculus
> Moving to an immutable, API-managed node OS (Talos, Flatcar, Bottlerocket) deletes
> a large part of this list rather than automating it — there is no package manager
> to patch, no shell to harden, and no drift to detect. If that migration is on the
> table, do not spend a quarter automating compliance scanning for an OS you are
> about to replace.

## Domain 2 — Cluster configuration

| Work item | Tooling |
| --- | --- |
| CIS Kubernetes benchmark, continuously | [kube-bench](https://github.com/aquasecurity/kube-bench) |
| Broader posture and misconfiguration scanning | [Kubescape](https://kubescape.io/), [Trivy](https://trivy.dev/) |
| RBAC review — find the cluster-admin bindings nobody remembers | [rbac-tool](https://github.com/alcideio/rbac-tool), `kubectl-who-can` |
| API server audit logging, shipped off-cluster | `--audit-policy-file` and `--audit-log-path` on the API server; shipping in [[kubernetes/observability/logs-centralized]] |
| etcd encryption at rest and restricted access | [[kubernetes/configuration/secrets]] (encryption at rest), [[kubernetes/security/control-plane-auth]] (etcd TLS) |
| Pod Security Standards enforced at namespace level | [[kubernetes/security/pod-security-admission]] |

## Domain 3 — Workload policy

Where prevention actually lands.

| Work item | Tooling |
| --- | --- |
| Admission policy: deny privileged, enforce non-root, require limits | [Kyverno](https://kyverno.io/) ([[kubernetes/security/kyverno]]), OPA Gatekeeper, or built-in [ValidatingAdmissionPolicy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/) |
| Default-deny network policy per namespace | [[kubernetes/networking/netpol]] |
| Signature verification at admission | Kyverno `verifyImages`, [Sigstore Policy Controller](https://docs.sigstore.dev/policy-controller/overview/) |
| Documented, reviewed privilege exemptions | see [[security/secure-container-images]] |

Every one of these should ship in `Audit` mode, sit there long enough to see a full
workload cycle, and only then move to `Enforce`.

## Domain 4 — Supply chain

| Work item | Tooling |
| --- | --- |
| Minimal base images | [[security/secure-container-images]] |
| SBOM generated per build | [Syft](https://github.com/anchore/syft), see [[security/supply-chain/sbom]] |
| SBOM stored and continuously re-evaluated | [Dependency-Track](https://dependencytrack.org/), [GUAC](https://docs.guac.sh/) ([[security/supply-chain/guac]]), see [[security/supply-chain/sbom-lifecycle]] |
| Image scanning as a CI gate | [Grype](https://github.com/anchore/grype), Trivy |
| Artifact signing and provenance | [cosign](https://docs.sigstore.dev/cosign/signing/overview/) ([[security/supply-chain/cosign]]), [SLSA](https://slsa.dev/), [in-toto](https://in-toto.io/) |
| "Not affected" statements, machine-readable | [OpenVEX](https://github.com/openvex), `vexctl`, see [[security/supply-chain/vex]] |

> [!warning] SBOM generation is the easy half
> Producing an SBOM per build is a week of work. Making it *useful* — stored,
> queryable, re-scanned as new CVEs land, and connected to what is actually running
> — is the part that takes a quarter and delivers the value. Plan for the second
> half or skip the first.

## Domain 5 — Runtime detection

Only worth building once the preventive layers are in place; otherwise you are
alerting on things you could have prevented.

| Work item | Tooling |
| --- | --- |
| Syscall-level runtime detection | [Falco](https://falco.org/), [Tetragon](https://tetragon.io/) |
| Container behavioural policy and L7 network inspection | [[security/neuvector]] |
| Network flow collection for anomaly detection | Hubble, netflow/IPFIX collectors |
| Centralised alerting on the above | [[kubernetes/observability/prometheus]] |

## Domain 6 — Vulnerability management as a process

The part that is organisational rather than technical, and the part that most often
fails.

- A defined severity gate for CI — and an explicit, time-bound exception process for
  what it blocks. See [[security/cvss]] on why severity alone is a poor gate.
- Prioritisation using exploitation signals (KEV, EPSS), not just CVSS.
- Tracking of *fixed* vulnerabilities, not only open ones, so you can answer customer
  and auditor questions without archaeology.
- A recurring review of accepted risks with expiry dates. An accepted risk without a
  review date is just an ignored risk.

## Domain 7 — Cryptography and long-horizon items

Worth having on the roadmap explicitly so they are not perpetual surprises:

- **Certificate lifecycle** — automated issuance and rotation, no manual renewals.
  Public TLS certificates are limited to 200 days since 15 March 2026, 100 days from
  March 2027 and 47 days from March 2029 (CA/Browser Forum ballot SC-081v3), so manual
  renewal stops being an option. See [[kubernetes/security/cert-manager]],
  [[security/cryptography/acme]] and [[security/cryptography/pki-and-x509]].
- **Post-quantum readiness** — inventory where you depend on classical asymmetric
  cryptography, and track your TLS library's PQ support
  ([Open Quantum Safe](https://openquantumsafe.org/),
  [[security/cryptography/post-quantum]]). This is an inventory problem long before
  it is a migration problem.
- **Secrets management** — where secrets live, how they rotate, and who can read
  them. See [[kubernetes/configuration/secrets]].

## A workable first year

If everything above is empty, this order tends to work:

1. **Visibility** — API audit logs shipped, kube-bench and a scanner running,
   findings visible somewhere. No enforcement.
2. **The structural controls** — Pod Security Admission at `restricted`, default-deny
   network policy, RBAC cleanup. In audit mode first.
3. **Build-time** — minimal base images, scanning as a CI gate, SBOM per build.
4. **Trust** — signing, and verification at admission.
5. **Runtime detection** — once the above means an alert is genuinely anomalous.
6. **Process** — the exception, review and reporting loop that keeps it all honest.

> [!note] The roadmap is not the point
> The output that matters is a short list of things that are now *impossible*, not a
> long list of things that are monitored. Judge each quarter by what moved from
> "detected" to "prevented".

## Where to go next

- [[security/secure-container-images]] — the build-time half, in detail
- [[security/cvss]] — how to read the severity scores this all produces
- [[security/resources]] — the reference material behind these choices
- [[kubernetes/security/index|Kubernetes security]] — the cluster-side controls

<!-- uplink -->
Part of [[security/index|Security]].
