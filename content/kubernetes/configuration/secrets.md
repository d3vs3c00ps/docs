---
title: "Managing secrets"
description: "Kubernetes Secrets: how they differ from ConfigMaps, Secret types, private registry credentials, base64, encryption at rest, immutability"
tags: [kubernetes, configuration, secrets]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/secrets.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Managing secrets

Sometimes our code needs sensitive information: passwords, API tokens, TLS keys, and
so on. *Secrets* are made for that. Secrets and ConfigMaps are very similar.

## Similarities between ConfigMap and Secrets

ConfigMaps and Secrets are both key-value maps. A Secret can hold zero, one, or many
key-value pairs.

Both can be exposed to containers as environment variables or as files in a volume.

Both can be created from YAML, or with a CLI command: `kubectl create configmap` and
`kubectl create secret`.

> [!warning] Correction
> The original page said that both "can be exposed with the downward API". The
> downward API exposes information about the Pod itself (its name, Namespace, IP
> address, resource limits). ConfigMaps and Secrets are exposed with
> `valueFrom.configMapKeyRef` / `valueFrom.secretKeyRef`, `envFrom`, or volumes.

## ConfigMap and Secrets are different resources

They can have different RBAC (role-based access control) permissions. For example, the
default `view` role can read ConfigMaps but not Secrets.

They also show a different *intent*:

*"You should use secrets for things which are actually secret like API keys,
credentials, etc., and use config map for not-secret configuration data."*

*"In the future there will likely be some differentiators for secrets like rotation or
support for backing the secret API w/ HSMs, etc."*

(Source: [the author of both features](https://stackoverflow.com/a/36925553/580281).)

## Secrets have an optional *type*

The type says which keys must exist in the Secret. For example:

| Type | Required keys |
| --- | --- |
| `kubernetes.io/tls` | `tls.crt` and `tls.key` |
| `kubernetes.io/basic-auth` | `username` or `password` (at least one) |
| `kubernetes.io/ssh-auth` | `ssh-privatekey` |
| `kubernetes.io/dockerconfigjson` | `.dockerconfigjson` |
| `kubernetes.io/service-account-token` | the annotation `kubernetes.io/service-account.name` |

The whole list is in [the documentation](https://kubernetes.io/docs/concepts/configuration/secret/#secret-types).
A Secret with no type is `Opaque`: any keys are fine.

For a `kubernetes.io/service-account-token` Secret, Kubernetes fills in the keys
`token`, `namespace`, and `ca.crt` itself. Since Kubernetes 1.24, these Secrets are no
longer created automatically for each ServiceAccount. To get a short-lived token,
prefer `kubectl create token <serviceaccount>`.

> [!warning] Correction
> The original page said that the type "is merely for our (human) convenience". It is
> more than that: the API server rejects a typed Secret that lacks the required keys.
> It also listed `token`, `namespace`, and `ca.crt` as required for
> `kubernetes.io/service-account-token`, and both `username` and `password` for
> `kubernetes.io/basic-auth`. See the table above.

## Accessing private registries

Let's see how to use an image from a private registry. These images are protected by
a username and a password. Some registries use a token and a password instead: it
works the same way.

To use a private image, we need to:

- create a Secret;
- reference that Secret in a Pod template,
- or reference it in a ServiceAccount used by the Pod.

## In practice

Let's try to use an image from a private registry. Replace these values with your
own:

- image: `registry.example.com/team/private:latest`
- user: `reader`
- password: in the `REGISTRY_PASSWORD` environment variable

> [!note]
> The original course used a demo registry run by the course author's company, with
> a public read-only account. That registry and account are not reproduced here.

> [!example] Hands-on
> - Create a Deployment using that image:
>   ```bash
>   kubectl create deployment priv \
>           --image=registry.example.com/team/private
>   ```
>
> - Check that the Pod does not start:
>   ```bash
>   kubectl get pods --selector=app=priv
>   ```

The Pod stays in `ErrImagePull`, then `ImagePullBackOff`. `kubectl describe pod` shows
why: `pull access denied, repository does not exist or may require authorization:
authorization failed: no basic auth credentials`.

## Creating a secret

Let's create a Secret with the registry address and the credentials.

> [!example] Hands-on
> - Create the registry Secret:
>   ```bash
>   kubectl create secret docker-registry regcred \
>           --docker-server=registry.example.com \
>           --docker-username=reader \
>           --docker-password="$REGISTRY_PASSWORD"
>   ```

The Secret has the type `kubernetes.io/dockerconfigjson`.

Why do we have to give the registry address? When we use several sets of credentials
for different registries, it keeps the credentials of one registry from leaking to
*another* registry. Kubernetes sends the credentials only to the registry they are
for.

## Using the secret

The first way to use a Secret is to add it to `imagePullSecrets`, in the `spec`
section of a Pod template.

> [!example] Hands-on
> - Patch the `priv` Deployment that we created earlier:
>   ```bash
>   kubectl patch deploy priv --patch='
>   spec:
>     template:
>       spec:
>         imagePullSecrets:
>         - name: regcred
>   '
>   ```

## Checking the results

> [!example] Hands-on
> - Confirm that our Pod can now start correctly:
>   ```bash
>   kubectl get pods --selector=app=priv
>   ```

## Another way to use the secret

We can also add the Secret to a ServiceAccount. Then *all* the Pods that use that
ServiceAccount get the credentials automatically: the ServiceAccount admission
controller copies its `imagePullSecrets` into each new Pod.

> [!example] Hands-on
> - Add the Secret to the ServiceAccount:
>   ```bash
>   kubectl patch serviceaccount default --patch='
>   imagePullSecrets:
>   - name: regcred
>   '
>   ```

## Secrets are displayed with base64 encoding

When shown with `kubectl get secrets -o yaml`, for example, the values of a Secret are
base64-encoded. Likewise, the `data` values are base64-encoded when we write a Secret
in YAML:

```yaml
kind: Secret
apiVersion: v1
metadata:
  name: pin-codes
data:
  onetwothreefour: MTIzNA==
  zerozerozerozero: MDAwMA==
```

Keep in mind that this is just *encoding*, not *encryption*. It is very easy to
[extract and decode Secrets automatically](https://medium.com/@mveritym/decoding-kubernetes-secrets-60deed7a96a3).
For example:

```bash
kubectl get secret pin-codes -o jsonpath='{.data.onetwothreefour}' | base64 -d
```

> [!note]- Extra details
> ## Using `stringData`
>
> When we create a Secret, we can skip base64: use `stringData` instead of `data`.
>
> ```yaml
> kind: Secret
> apiVersion: v1
> metadata:
>   name: pin-codes
> stringData:
>   onetwothreefour: "1234"
>   zerozerozerozero: "0000"
> ```
>
> `kubectl get -o yaml` still shows the values base64-encoded, under `data`.
>
> No `type` was given, so it defaults to `Opaque`.
>
> > [!warning] Correction
> > The original example did not quote `1234` and `0000`. YAML reads them as numbers,
> > and `kubectl apply` rejects the Secret: `stringData` values must be strings.

> [!note]- Extra details
> ## Encryption at rest
>
> You can [encrypt Secrets at rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
> in etcd. Then Secrets stay safe if someone:
>
> - steals our etcd servers;
> - steals our backups;
> - snoops the link between our etcd servers and their storage (an iSCSI link to a
>   SAN, for example).
>
> The API server reads its keys from an `EncryptionConfiguration` file, or asks a KMS
> (key management service) provider. Protect that file, or the key service, as well
> as the etcd data.
>
> > [!warning] Correction
> > The original page said that the API server then needs a human to provide the
> > keys at each start, and that this is only for "extremely regulated environments".
> > Neither is true today: the keys come from a file or a KMS, with no human step,
> > and many managed Kubernetes services encrypt Secrets at rest by default or as an
> > option.

> [!note]- Extra details
> ## Immutable ConfigMaps and Secrets
>
> Since Kubernetes 1.19 (stable in 1.21), a ConfigMap or a Secret can be marked as
> *immutable*:
>
> ```bash
> kubectl patch configmap xyz --patch='{"immutable": true}'
> ```
>
> This improves performance when there are many ConfigMaps and Secrets: tens of
> thousands. The kubelet stops watching them for changes.
>
> Once a ConfigMap or Secret is immutable:
>
> - its content cannot change anymore;
> - the `immutable` field cannot go back to `false` either;
> - the only way to change it is to delete it and create it again;
> - Pods that use it must be re-created too.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/secrets.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/secrets.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; the course's demo registry and its credentials replaced with
> placeholders; claims about Secret types, the downward API, `stringData` and
> encryption at rest corrected.

<!-- uplink -->
Part of [[kubernetes/configuration/index|Configuration and secrets]].
