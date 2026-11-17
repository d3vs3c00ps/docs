---
title: "CA injector - overview"
description: "How cert-manager's CA injector fills the caBundle of webhooks and CRDs, from a Certificate, a Secret or the API server CA"
tags: [kubernetes, security, tls, cert-manager]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/cainjector.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# CA injector - overview

## CA injector - overview

- The Kubernetes API server can invoke various webhooks:

  - conversion webhooks (registered in CustomResourceDefinitions)

  - mutation webhooks (registered in MutatingWebhookConfigurations)

  - validation webhooks (registered in ValidatingWebhookConfiguration)

- These webhooks must be served over TLS

- These webhooks must use valid TLS certificates

## Webhook certificates

- Option 1: certificate issued by a global CA

  - doesn't work with internal services
    <br/>
    (their CN must be `<servicename>.<namespace>.svc`)

- Option 2: certificate issued by private CA + CA certificate in system store

  - requires access to the API server certificate store

  - generally not doable on managed Kubernetes clusters

- Option 3: certificate issued by private CA + CA certificate in `caBundle`

  - pass the CA certificate in `caBundle` field
    <br/>
    (in CRD or webhook manifests)

  - can be managed automatically by cert-manager

## CA injector - details

- Add annotation to *injectable* resource
  (CustomResourceDefinition, MutatingWebhookConfiguration, ValidatingWebhookConfiguration)

- Annotation refers to the thing holding the certificate:

  - `cert-manager.io/inject-ca-from: <namespace>/<certificate>`

  - `cert-manager.io/inject-ca-from-secret: <namespace>/<secret>`

  - `cert-manager.io/inject-apiserver-ca: true` (use API server CA)

- When injecting from a Secret, the Secret must have a special annotation:

  `cert-manager.io/allow-direct-injection: "true"`

- See [cert-manager documentation] for details

[cert-manager documentation]: https://cert-manager.io/docs/concepts/ca-injector/

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/cainjector.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/cainjector.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.

<!-- uplink -->
Part of [[kubernetes/security/index|Security]].
