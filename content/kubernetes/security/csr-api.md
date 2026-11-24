---
title: "The CSR API"
description: "The Kubernetes API exposes CSR resources"
tags: [kubernetes, security]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/csr-api.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# The CSR API

> [!important] These labs expect the upstream repository
> Commands below reference files by their path in a local clone. Get it with:
>
> ```bash
> git clone https://github.com/jpetazzo/container.training
> ```
>
> The manifests can also be browsed at the pinned commit
> [`56563629`](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2).

- The Kubernetes API exposes CSR resources

- We can use these resources to issue TLS certificates

- First, we will go through a quick reminder about TLS certificates

- Then, we will see how to obtain a certificate for a user

- We will use that certificate to authenticate with the cluster

- Finally, we will grant some privileges to that user

## Reminder about TLS

- TLS (Transport Layer Security) is a protocol providing:

  - encryption (to prevent eavesdropping)

  - authentication (using public key cryptography)

- When we access an https:// URL, the server authenticates itself

  (it proves its identity to us; as if it were "showing its ID")

- But we can also have mutual TLS authentication (mTLS)

  (client proves its identity to server; server proves its identity to client)

## Authentication with certificates

- To authenticate, someone (client or server) needs:

  - a *private key* (that remains known only to them)

  - a *public key* (that they can distribute)

  - a *certificate* (associating the public key with an identity)

- A message encrypted with the private key can only be decrypted with the public key

  (and vice versa)

- If I use someone's public key to encrypt/decrypt their messages,
  <br/>
  I can be certain that I am talking to them / they are talking to me

- The certificate proves that I have the correct public key for them

## Certificate generation workflow

This is what I do if I want to obtain a certificate.

1. Create public and private keys.

2. Create a Certificate Signing Request (CSR).

   (The CSR contains the identity that I claim and a public key.)

3. Send that CSR to the Certificate Authority (CA).

4. The CA verifies that I can claim the identity in the CSR.

5. The CA generates my certificate and gives it to me.

The CA (or anyone else) never needs to know my private key.

## The CSR API

- The Kubernetes API has a CertificateSigningRequest resource type

  (we can list them with e.g. `kubectl get csr`)

- We can create a CSR object

  (= upload a CSR to the Kubernetes API)

- Then, using the Kubernetes API, we can approve/deny the request

- If we approve the request, the Kubernetes API generates a certificate

- The certificate gets attached to the CSR object and can be retrieved

## Using the CSR API

- We will show how to use the CSR API to obtain user certificates

- This will be a rather complex demo

- ... And yet, we will take a few shortcuts to simplify it

  (but it will illustrate the general idea)

- The demo also won't be automated

  (we would have to write extra code to make it fully functional)

## Warning

- The CSR API isn't really suited to issue user certificates

- It is primarily intended to issue control plane certificates

  (for instance, deal with kubelet certificates renewal)

- The API was expanded a bit in Kubernetes 1.19 to encompass broader usage

- There are still lots of gaps in the spec

  (e.g. how to specify expiration in a standard way)

- ... And no other implementation to this date

  (but [cert-manager](https://cert-manager.io/docs/faq/#kubernetes-has-a-builtin-certificatesigningrequest-api-why-not-use-that) might eventually get there!)

## General idea

- We will create a Namespace named "users"

- Each user will get a ServiceAccount in that Namespace

- That ServiceAccount will give read/write access to *one* CSR object

- Users will use that ServiceAccount's token to submit a CSR

- We will approve the CSR (or not)

- Users can then retrieve their certificate from their CSR object

- ...And use that certificate for subsequent interactions

## Resource naming

For a user named `jean.doe`, we will have:

- ServiceAccount `jean.doe` in Namespace `users`

- CertificateSigningRequest `user=jean.doe`

- ClusterRole `user=jean.doe` giving read/write access to that CSR

- ClusterRoleBinding `user=jean.doe` binding ClusterRole and ServiceAccount

> [!note]- Extra details
> ## About resource name constraints
>
> - Most Kubernetes identifiers and names are fairly restricted
>
> - They generally are DNS-1123 *labels* or *subdomains* (from [RFC 1123](https://tools.ietf.org/html/rfc1123))
>
> - A label is lowercase letters, numbers, dashes; can't start or finish with a dash
>
> - A subdomain is one or multiple labels separated by dots
>
> - Some resources have more relaxed constraints, and can be "path segment names"
>
>   (uppercase are allowed, as well as some characters like `#:?!,_`)
>
> - This includes RBAC objects (like Roles, RoleBindings...) and CSRs
>
> - See the [Identifiers and Names](https://github.com/kubernetes/community/blob/master/contributors/design-proposals/architecture/identifiers.md) design document and the [Object Names and IDs](https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#path-segment-names) documentation page for more details

## Creating the user's resources

> [!warning]
> If you want to use another name than `jean.doe`, update the YAML file!

> [!example] Hands-on
> - Create the global namespace for all users:
>   ```bash
>   kubectl create namespace users
>   ```
>
> - Create the ServiceAccount, ClusterRole, ClusterRoleBinding for `jean.doe`:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/user=jean.doe.yaml
>   ```

## Extracting the user's token

- Let's obtain the user's token and give it to them

  (the token will be their password)

> [!example] Hands-on
> - Request a token for the user's ServiceAccount:
>   ```bash
>   kubectl --namespace=users create token jean.doe
>   ```

> [!note] No token Secret
> Since Kubernetes 1.24, a ServiceAccount gets no `<name>-token-xxxxx` Secret.
> `kubectl create token` asks the TokenRequest API for a short-lived token instead
> (one hour by default; `--duration` changes it).

## Configure `kubectl` to use the token

- Let's create a new context that will use that token to access the API

> [!example] Hands-on
> - Add a new identity to our kubeconfig file:
>   ```bash
>   kubectl config set-credentials token:jean.doe --token=...
>   ```
>
> - Add a new context using that identity:
>   ```bash
>   kubectl config set-context jean.doe --user=token:jean.doe --cluster=kubernetes
>   ```
>   (Make sure to adapt the cluster name if yours is different!)
>
> - Use that context:
>   ```bash
>   kubectl config use-context jean.doe
>   ```

## Access the API with the token

- Let's check that our access rights are set properly

> [!example] Hands-on
> - Try to access any resource:
>   ```bash
>   kubectl get pods
>   ```
>   (This should tell us "Forbidden")
>
> - Try to access "our" CertificateSigningRequest:
>   ```bash
>   kubectl get csr user=jean.doe
>   ```
>   (This should tell us "NotFound")

## Create a key and a CSR

- There are many tools to generate TLS keys and CSRs

- Let's use OpenSSL; it's not the best one, but it's installed everywhere

  (many people prefer cfssl, easyrsa, or other tools; that's fine too!)

> [!example] Hands-on
> - Generate the key and certificate signing request:
>   ```bash
>     openssl req -newkey rsa:2048 -nodes -keyout key.pem \
>                 -new -subj /CN=jean.doe/O=devs/ -out csr.pem
>   ```

The command above generates:

- a 2048-bit RSA key, without encryption, stored in key.pem
- a CSR for the name `jean.doe` in group `devs`

## Inside the Kubernetes CSR object

- The Kubernetes CSR object is a thin wrapper around the CSR PEM file

- The PEM file needs to be encoded to base64 on a single line

  (we will use `base64 -w0` for that purpose)

- The Kubernetes CSR object also needs to list the right "usages"

  (these are flags indicating how the certificate can be used)

## Sending the CSR to Kubernetes

> [!example] Hands-on
> - Generate and create the CSR resource:
>   ```bash
>   kubectl apply -f - <<EOF
>   apiVersion: certificates.k8s.io/v1
>   kind: CertificateSigningRequest
>   metadata:
>     name: user=jean.doe
>   spec:
>     request: $(base64 -w0 < csr.pem)
>     signerName: kubernetes.io/kube-apiserver-client
>     expirationSeconds: 3600
>     usages:
>     - digital signature
>     - key encipherment
>     - client auth
>   EOF
>   ```

## Adjusting certificate expiration

- By default, the CSR API generates certificates valid 1 year

- We want short-lived certificates, so the CSR above asks for 1 hour with
  `spec.expirationSeconds: 3600`

- The signer may give less than requested, never more than its own maximum
  (`--cluster-signing-duration` on the controller manager, 1 year by default)

> [!note] Per-request duration
> `spec.expirationSeconds` (GA since Kubernetes 1.22) sets the duration per request,
> with no control plane change. The controller manager flag
> `--experimental-cluster-signing-duration` is gone.

## Verifying and approving the CSR

- Let's inspect the CSR, and if it is valid, approve it

> [!example] Hands-on
> - Switch back to `cluster-admin` (`kctx` comes with
>   [kubectx](https://github.com/ahmetb/kubectx); without it, use
>   `kubectl config use-context <previous context>`):
>   ```bash
>   kctx -
>   ```
>
> - Inspect the CSR:
>   ```bash
>   kubectl describe csr user=jean.doe
>   ```
>
> - Approve it:
>   ```bash
>   kubectl certificate approve user=jean.doe
>   ```

## Obtaining the certificate

> [!example] Hands-on
> - Switch back to the user's identity:
>   ```bash
>   kctx -
>   ```
>
> - Retrieve the updated CSR object and extract the certificate:
>   ```bash
>   kubectl get csr user=jean.doe \
>           -o jsonpath={.status.certificate} \
>           | base64 -d > cert.pem
>   ```
>
> - Inspect the certificate:
>   ```bash
>   openssl x509 -in cert.pem -text -noout
>   ```

## Using the certificate

> [!example] Hands-on
> - Add the key and certificate to kubeconfig:
>   ```bash
>   kubectl config set-credentials cert:jean.doe --embed-certs \
>           --client-certificate=cert.pem --client-key=key.pem
>   ```
>
> - Update the user's context to use the key and cert to authenticate:
>   ```bash
>   kubectl config set-context jean.doe --user cert:jean.doe
>   ```
>
> - Confirm that we are seen as `jean.doe` (but don't have permissions):
>   ```bash
>   kubectl get pods
>   ```

## What's missing?

We have just shown, step by step, a method to issue short-lived certificates for users.

To be usable in real environments, we would need to add:

- a kubectl helper to automatically generate the CSR and obtain the cert

  (and transparently renew the cert when needed)

- a Kubernetes controller to automatically validate and approve CSRs

  (checking that the subject and groups are valid)

- a way for the users to know the groups to add to their CSR

  (e.g.: annotations on their ServiceAccount + read access to the ServiceAccount)

## Is this realistic?

- Larger organizations typically integrate with their own directory

- The general principle, however, is the same:

  - users have long-term credentials (password, token, ...)

  - they use these credentials to obtain other, short-lived credentials

- This provides enhanced security:

  - the long-term credentials can use long passphrases, 2FA, HSM...

  - the short-term credentials are more convenient to use

  - we get strong security *and* convenience

- Systems like Vault also have certificate issuance mechanisms

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/csr-api.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/csr-api.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked;
> token Secret replaced by `kubectl create token`; removed controller manager
> flag replaced by `spec.expirationSeconds`; backtick placeholders removed
> from commands.

<!-- uplink -->
Part of [[kubernetes/security/index|Security]].
