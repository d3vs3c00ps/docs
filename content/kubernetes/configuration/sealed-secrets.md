---
title: "Sealed Secrets"
description: "Store encrypted Secrets in git with Sealed Secrets: kubeseal, scopes, offline sealing and key rotation"
tags: [kubernetes, configuration, secrets]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/sealed-secrets.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Sealed Secrets

Kubernetes has the Secret resource to store credentials, keys, passwords... We can
protect Secrets with RBAC (role-based access control): for example, "you can write
Secrets, but only the app's service account can read them". See
[[kubernetes/configuration/secrets]].

[Sealed Secrets](https://github.com/bitnami/sealed-secrets) is an operator that lets us
store secrets in code repositories. It uses asymmetric cryptography:

- anyone can *encrypt* a secret;
- only the cluster can *decrypt* it.

## Principle

- The Sealed Secrets operator uses a *public* key and a *private* key.
- The public key is, well, public.
- We use the public key to encrypt Secrets into a SealedSecret resource.
- We can store the SealedSecret resource in a code repository, even a public one.
- We `kubectl apply` the SealedSecret resource to the cluster.
- The Sealed Secrets controller decrypts the SealedSecret with the private key. This
  creates a normal Secret resource.
- Nobody else can decrypt the secrets, because only the controller has the private key.

## In action

We will:

1. install the Sealed Secrets operator;
2. generate a Secret;
3. "seal" that Secret, which generates a SealedSecret;
4. load that SealedSecret into the cluster;
5. check that we now have a Secret.

## Installing the operator

The official installation uses a single YAML file. There is also a Helm chart, if you
prefer (see below).

> [!example] Hands-on
> - Install the operator:
>   ```bash
>   kubectl apply -f \
>           https://github.com/bitnami/sealed-secrets/releases/download/v0.41.2/controller.yaml
>   ```

It installs into the `kube-system` Namespace by default. If you change that, you must
also tell `kubeseal` later: use `kubeseal --controller-namespace`, or set the
`SEALED_SECRETS_CONTROLLER_NAMESPACE` environment variable.

> [!note]- Extra details
> ## Installing with Helm
>
> The Sealed Secrets controller can be installed like this:
>
> ```bash
> helm install --repo https://bitnami.github.io/sealed-secrets/ \
>      sealed-secrets-controller sealed-secrets --namespace kube-system
> ```
>
> - Install it in the `kube-system` Namespace.
> - Name the release `sealed-secrets-controller`, or pass a `--controller-name` option
>   to `kubeseal` later. With another release name, the chart names the controller
>   `<release>-sealed-secrets`, unless you set `fullnameOverride`.

> [!warning] Correction
> The project moved from `bitnami-labs` to `bitnami` on GitHub. The old Helm repository
> URL, `https://bitnami-labs.github.io/sealed-secrets/`, now returns 404: use
> `https://bitnami.github.io/sealed-secrets/`. The release download links still redirect.
> The version was v0.37.0; it is now v0.41.2.

## Creating a Secret

Let's create a normal (unencrypted) Secret.

> [!example] Hands-on
> - Create a Secret with a couple of API tokens:
>   ```bash
>   kubectl create secret generic awskey \
>           --from-literal=AWS_ACCESS_KEY_ID=AKI... \
>           --from-literal=AWS_SECRET_ACCESS_KEY=abc123xyz... \
>           --dry-run=client -o yaml > secret-aws.yaml
>   ```

Note the `--dry-run=client` and `-o yaml`: we only generate YAML. We do not send the
secrets to our Kubernetes cluster. We could also write the YAML by hand, or generate it
with other tools.

## Creating a Sealed Secret

We do this with the `kubeseal` tool. It gets the public key from the cluster.

> [!example] Hands-on
> - Create the Sealed Secret:
>   ```bash
>   kubeseal < secret-aws.yaml > sealed-secret-aws.json
>   ```

We can commit the file `sealed-secret-aws.json` to a public repository. The default
output is JSON; add `-o yaml` for YAML.

`kubeseal` puts the Namespace in the SealedSecret: the one in the input file, or else
the current Namespace of our kubeconfig context.

## Using a Sealed Secret

Now let's `kubectl apply` that Sealed Secret to the cluster. The Sealed Secrets
controller "unseals" it for us.

> [!example] Hands-on
> - Check that our Secret doesn't exist (yet):
>   ```bash
>   kubectl get secrets
>   ```
>
> - Load the Sealed Secret into the cluster:
>   ```bash
>   kubectl create -f sealed-secret-aws.json
>   ```
>
> - Check that the Secret is now available:
>   ```bash
>   kubectl get secrets
>   ```

## Tweaking secrets

Let's see what happens if we rename the Secret, or use it in another Namespace.

> [!example] Hands-on
> - Delete both the Secret and the SealedSecret.
> - Edit `sealed-secret-aws.json`.
> - Change the name of the Secret, or its Namespace, both in the SealedSecret metadata
>   and in the Secret template (`spec.template.metadata`).
> - `kubectl apply -f` the new JSON file and look at the results.

## Sealed Secrets are *scoped*

A SealedSecret cannot be renamed or moved to another Namespace, at least not by default.
The controller does not create the Secret. The SealedSecret gets the condition
`Synced=False`, and an `ErrUnsealFailed` event with the message `no key could decrypt
secret`.

Otherwise, it would be a way around RBAC rules:

- if I can view Secrets in Namespace `myapp` but not in Namespace `yourapp`,
- I could take a SealedSecret that belongs to Namespace `yourapp`,
- deploy it in `myapp`,
- and view the decrypted Secret.

`kubeseal --scope namespace-wide` (the name can change) or `--scope cluster-wide` (the
name and Namespace can change) changes this.

## Working offline

We can get the public key from the server (technically, a PEM certificate). Then we can
use that public key offline, without contacting the server.

Get the certificate:

```bash
kubeseal --fetch-cert > seal.pem
```

Use it:

```bash
kubeseal --cert seal.pem < secret.yaml > sealedsecret.json
```

## Key rotation

- By default, the controller generates a new key every 30 days (`--key-renew-period`).
- The keys are kept as TLS Secrets in the controller's Namespace (`kube-system`), named
  `sealed-secrets-keyXXXXX`.
- When keys are "rotated", the old decryption keys are kept. Otherwise, the controller
  could not decrypt SealedSecrets that were sealed before.

## Key compromise

- If the *sealing* key (the one we get with `--fetch-cert`) is compromised, we don't need
  to do anything: it is a public key.
- If the *unsealing* key (the TLS Secret in `kube-system`) is compromised, we need to:
  - rotate the key;
  - rotate the SealedSecrets that were encrypted with that key, because they are
    compromised.

## Rotating the key

By default, new keys are generated every 30 days. To generate a new key "right now":

1. Get an RFC 1123 timestamp with `date -R`.
2. Edit the Deployment `sealed-secrets-controller` (in `kube-system`).
3. Add `--key-cutoff-time=TIMESTAMP` to the command line.

For example:

```bash
kubectl -n kube-system get deployment sealed-secrets-controller -o json |
  jq --arg t "$(date -R)" '.spec.template.spec.containers[0].args += ["--key-cutoff-time=" + $t]' |
  kubectl replace -f -
```

This works whether the container already has arguments (the Helm chart sets some) or
not (`controller.yaml` sets none, so a JSON patch that appends to `args` fails).

*Then*, rotate the SealedSecrets that were encrypted with the old key: generate new
secret values, and seal them with the new key. Re-sealing the old values
(`kubeseal --re-encrypt`) is not enough, since the old key could decrypt them.

## Discussion (the good)

The operator has a small footprint:

- only one CRD;
- one Deployment, and two Services (the controller and its metrics);
- a few RBAC-related objects.

## Discussion (the less good)

- Events could be better:
  - `no key could decrypt secret` when the name or Namespace does not match;
  - only an `Unsealed` event when a SealedSecret is unsealed, nothing more detailed.
- Key rotation could be better: how do we find the Secrets that use a given key?
- If the sealing keys are lost (for example, when the cluster is reinstalled), the
  SealedSecrets cannot be unsealed anymore.
- So we need to back up the sealing keys,
- so we need to be very careful with these backups.

## Other approaches

- [Kamus](https://kamus.soluto.io/) ([git](https://github.com/Soluto/kamus)) offers
  "zero-trust" secrets: the cluster cannot decrypt them, only the application can. The
  project is archived and no longer maintained.
- [Vault](https://developer.hashicorp.com/vault/tutorials/kubernetes/kubernetes-sidecar)
  can do a lot:
  - dynamic secrets, generated on the fly for each consumer;
  - certificate management;
  - integration outside of Kubernetes;
  - and much more.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/sealed-secrets.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/sealed-secrets.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; updated to Sealed Secrets v0.41 (repository, Helm URL, events,
> Services), with a key cutoff example.

<!-- uplink -->
Part of [[kubernetes/configuration/index|Configuration and secrets]].
