---
title: "cert-manager"
description: "we create a Certificate object (that's a CRD)"
tags: [kubernetes, security, tls, cert-manager]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/cert-manager.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# cert-manager

> [!important] These labs expect the upstream repository
> Commands below reference files by their path in a local clone. Get it with:
>
> ```bash
> git clone https://github.com/jpetazzo/container.training
> ```
>
> The manifests can also be browsed at the pinned commit
> [`56563629`](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2).

- cert-manager¹ facilitates certificate signing through the Kubernetes API:

  - we create a Certificate object (that's a CRD)

  - cert-manager creates a private key

  - it signs that key ...

  - ... or interacts with a certificate authority to obtain the signature

  - it stores the resulting key+cert in a Secret resource

- These Secret resources can be used in many places (Ingress, mTLS, ...)

***¹**Always lower case, words separated with a dash; see the [style guide](https://cert-manager.io/docs/faq/style/_.)*

## Getting signatures

- cert-manager can use multiple *Issuers* (another CRD), including:

  - self-signed

  - cert-manager acting as a CA

  - the [ACME protocol](https://en.wikipedia.org/wiki/Automated_Certificate_Management_Environment]) (notably used by Let's Encrypt)

  - [HashiCorp Vault](https://www.vaultproject.io/)

- Multiple issuers can be configured simultaneously

- Issuers can be available in a single namespace, or in the whole cluster

  (then we use the *ClusterIssuer* CRD)

## cert-manager in action

- We will install cert-manager

- We will create a ClusterIssuer to obtain certificates with Let's Encrypt

  (this will involve setting up an Ingress Controller)

- We will create a Certificate request

- cert-manager will honor that request and create a TLS Secret

## Installing cert-manager

- It can be installed with a YAML manifest, or with Helm

> [!example] Hands-on
> - Let's install the cert-manager Helm chart with this one-liner:
>   ```bash
>     helm install cert-manager cert-manager \
>         --repo https://charts.jetstack.io --version v1.21.3 \
>         --create-namespace --namespace cert-manager \
>         --set crds.enabled=true
>   ```

> [!note] Changed from the original
> The original used `--set installCRDs=true`. The chart now marks it deprecated,
> in favour of `crds.enabled` (and `crds.keep`, which defaults to keeping the CRDs
> on uninstall). The version is pinned so the lab is reproducible.

- If you prefer to install with a single YAML file, that's fine too!

  (see [the documentation](https://cert-manager.io/docs/installation/kubernetes/#installing-with-regular-manifests) for instructions)

## ClusterIssuer manifest

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    # To use the production environment, use the following line instead:
    #server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: issuer-letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: traefik
```
<small>Source: [`k8s/cm-clusterissuer.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/cm-clusterissuer.yaml)</small>

## Creating the ClusterIssuer

- The manifest shown on the previous slide is in [`k8s/cm-clusterissuer.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/cm-clusterissuer.yaml)

> [!example] Hands-on
> - Create the ClusterIssuer, without the file's `email:` line:
>   ```bash
>   grep -v 'email:' ~/container.training/k8s/cm-clusterissuer.yaml \
>     | kubectl apply -f -
>   ```

> [!warning] Correction: Let's Encrypt refuses `example.com` contacts
> The upstream file sets `email: hello@example.com`. Let's Encrypt rejects it,
> and the ClusterIssuer stays `Ready=False` with
> `contact email has forbidden domain "example.com"`. The email is optional, so
> the manifest above drops it. If you want one, set an address you own.

## Certificate manifest

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: xyz.A.B.C.D.nip.io
spec:
  secretName: xyz.A.B.C.D.nip.io
  dnsNames:
  - xyz.A.B.C.D.nip.io
  issuerRef:
    name: letsencrypt-staging
    kind: ClusterIssuer
```
<small>Source: [`k8s/cm-certificate.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/cm-certificate.yaml)</small>

- The `name`, `secretName`, and `dnsNames` don't have to match

- There can be multiple `dnsNames`

- The `issuerRef` must match the ClusterIssuer that we created earlier

## Creating the Certificate

- The manifest shown on the previous slide is in [`k8s/cm-certificate.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/cm-certificate.yaml)

> [!example] Hands-on
> - Edit the Certificate to update the domain name
>
>   (make sure to replace A.B.C.D with the IP address of one of your nodes!)
>
> - Create the Certificate:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/cm-certificate.yaml
>   ```

## What's happening?

- cert-manager will create:

  - the secret key

  - a Pod, a Service, and an Ingress to complete the HTTP challenge

- then it waits for the challenge to complete

> [!example] Hands-on
> - View the resources created by cert-manager:
>   ```bash
>     kubectl get pods,services,ingresses \
>             --selector=acme.cert-manager.io/http01-solver=true
>   ```

## HTTP challenge

- The CA (in this case, Let's Encrypt) will fetch a particular URL:

  `http://<our-domain>/.well-known/acme-challenge/<token>`

> [!example] Hands-on
> - Check the *path* of the Ingress in particular:
>   ```bash
>     kubectl describe ingress \
>             --selector=acme.cert-manager.io/http01-solver=true
>   ```

## What's missing ?

An Ingress Controller! 😅

> [!example] Hands-on
> - Install an Ingress Controller:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/traefik.yaml
>   ```
>
> - Wait a little bit, and check that we now have a `kubernetes.io/tls` Secret:
>   ```bash
>   kubectl get secrets
>   ```

> [!note]- Extra details
> ## Using the secret
>
> - For bonus points, try to use the secret in an Ingress!
>
> - This is what the manifest would look like:
>
> ```yaml
> apiVersion: networking.k8s.io/v1
> kind: Ingress
> metadata:
>   name: xyz
> spec:
>   tls:
>   - secretName: xyz.A.B.C.D.nip.io
>     hosts:
>     - xyz.A.B.C.D.nip.io
>   rules:
>   ...
> ```

> [!note]- Extra details
> ## Automatic TLS Ingress with annotations
>
> - It is also possible to annotate Ingress resources for cert-manager
>
> - If we annotate an Ingress resource with `cert-manager.io/cluster-issuer=xxx`:
>
>   - cert-manager will detect that annotation
>
>   - it will obtain a certificate using the specified ClusterIssuer (`xxx`)
>
>   - it will store the key and certificate in the specified Secret
>
> - Note: the Ingress still needs the `tls` section with `secretName` and `hosts`

> [!note]- Extra details
> ## Let's Encrypt and nip.io
>
> - Let's Encrypt has [rate limits](https://letsencrypt.org/docs/rate-limits/) per domain
>
>   (the limits only apply to the production environment, not staging)
>
> - There is a limit of 50 certificates per registered domain
>
> - If we try to use the production environment, we will probably hit the limit
>
> - It's fine to use the staging environment for these experiments
>
>   (our certs won't validate in a browser, but we can always check
>   the details of the cert to verify that it was issued by Let's Encrypt!)

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/cert-manager.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/cert-manager.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked;
> chart version pinned and `installCRDs` replaced by `crds.enabled`; the
> ClusterIssuer's `example.com` email removed (Let's Encrypt rejects it); a
> missing line continuation fixed.

<!-- uplink -->
Part of [[kubernetes/security/index|Security]].
