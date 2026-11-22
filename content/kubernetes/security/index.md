---
title: "Security"
description: "Authentication, authorisation, securing the control plane, restricting what pods may do, and policy enforcement."
tags: [security]
type: moc
status: complete
---

<!-- generated-moc -->

# Security

Authentication, authorisation, securing the control plane, restricting what pods may do, and policy enforcement.


| Note | | What it covers |
| --- | --- | --- |
| [[kubernetes/security/admission\|Dynamic Admission Control]] | lab | This is one of the many ways to extend the Kubernetes API |
| [[kubernetes/security/authn-authz\|Authentication and authorization]] | lab | Authentication (certificates, tokens, ServiceAccounts) and authorization (RBAC roles, bindings, kubectl auth can-i) in Kubernetes |
| [[kubernetes/security/bootstrap\|TLS bootstrap]] | lab | How a new kubelet gets its certificate: bootstrap tokens, the cluster-info ConfigMap and the CSR API |
| [[kubernetes/security/cainjector\|CA injector - overview]] | concept | How cert-manager's CA injector fills the caBundle of webhooks and CRDs, from a Certificate, a Secret or the API server CA |
| [[kubernetes/security/cert-manager\|cert-manager]] | lab | we create a Certificate object (that's a CRD) |
| [[kubernetes/security/control-plane-auth\|Securing the control plane]] | concept | How etcd, the API server, kubelet, the scheduler and the controller manager authenticate to each other: mTLS, tokens and their flags |
| [[kubernetes/security/csr-api\|The CSR API]] | lab | The Kubernetes API exposes CSR resources |
| [[kubernetes/security/kyverno-colors\|Painting pods]] | lab | Kyverno lab: making a Pod label optional, restricted to three values, then immutable and impossible to remove |
| [[kubernetes/security/kyverno-ingress\|Detecting duplicate Ingress routes]] | concept | Kyverno lab: rejecting an Ingress whose host and path are already used by another Ingress |
| [[kubernetes/security/kyverno\|Policy Management with Kyverno]] | lab | Kyverno, a Kubernetes policy engine: validating, mutating and generating resources with YAML policies, and reporting violations |
| [[kubernetes/security/openid-connect\|OpenID Connect]] | lab | Authenticating to the Kubernetes API with OpenID Connect tokens: the JWT flow, the API server flags, and authorizing the user |
| [[kubernetes/security/pod-security-admission\|Pod Security Admission]] | lab | (available in alpha since Kubernetes 1.22, and GA since Kubernetes 1.25) |
| [[kubernetes/security/pod-security-intro\|Restricting Pod Permissions]] | lab | By default, our pods and containers can do everything |
| [[kubernetes/security/pod-security-policies\|Pod Security Policies]] | lab | The legacy PodSecurityPolicy admission controller, deprecated in Kubernetes 1.21 and removed in 1.25; kept for history |
| [[kubernetes/security/user-cert\|Generating user certificates]] | lab | Signing a user certificate with the cluster CA, adding it to kubeconfig, and granting it permissions with RBAC |

> [!info] Derived from container.training
> Pages in this section marked with a `source` in their frontmatter are
> derived from [container.training](https://github.com/jpetazzo/container.training)
> under CC BY 4.0, with changes. See [[attribution]].

Part of [[kubernetes/index|Kubernetes]].
