---
title: "Ingress and TLS certificates"
description: "TLS secrets referenced from Ingress resources — self-signed certs, certbot and the HTTP-01 challenge, and why production uses cert-manager"
tags: [kubernetes, networking, tls, ingress, security]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/ingress-tls.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Ingress and TLS certificates

> [!important] These labs expect the upstream repository
> Commands below reference files by their path in a local clone. Get it with:
>
> ```bash
> git clone https://github.com/jpetazzo/container.training
> ```
>
> The manifests can also be browsed at the pinned commit
> [`56563629`](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2).

Most Ingress controllers support TLS, in a way that is standard across
controllers: the key and certificate live in a **Secret**, and the Ingress
references it:

```yaml
spec:
  tls:
  - secretName: XXX
    hosts:
    - YYY
  rules:
  - ZZZ
```

## Obtaining a certificate

Keys and certificates usually come in
[PEM](https://en.wikipedia.org/wiki/Privacy-Enhanced_Mail) format:

```text
-----BEGIN CERTIFICATE-----
MIIDATCCAemg...
...
-----END CERTIFICATE-----
```

Three methods below: a **self-signed certificate** (easy and fast, but browsers
will not trust it), and two ways to get a real one from
[Let's Encrypt](https://letsencrypt.org/) with certbot (they require the
cluster to be reachable through a domain name).

> [!note] In production, use cert-manager
> The popular production answer is the
> [cert-manager](https://cert-manager.io/docs/) operator — flexible, modular,
> automated. The certbot methods here are for understanding how the sausage is
> made: they produce one-time certificates, with no automation and no renewal.
> See [[kubernetes/security/cert-manager]].

Pick a domain that points to your **Ingress controller** (in a training, the
instructor provides one). Without a domain, [nip.io](https://nip.io/) works:
with the controller on 1.2.3.4, use `whatever.1.2.3.4.nip.io`. The labs below
use `$DOMAIN`:

> [!example] Hands-on
> - Set the `DOMAIN` environment variable:
>   ```bash
>   export DOMAIN=...
>   ```

We suggest method 1 — simplest, fastest, no other components. Methods 2 and 3
need some hacks (port 80 must be available) and would not be used in
production anyway.

## Method 1: self-signed certificate

One `openssl` command:

> [!example] Hands-on
> - Generate a key and certificate:
>   ```bash
>   openssl req \
>     -newkey rsa -nodes -keyout privkey.pem \
>     -x509 -days 30 -subj /CN=$DOMAIN/ -out cert.pem
>   ```

This creates `privkey.pem` and `cert.pem`.

## Method 2: Let's Encrypt with certbot

`certbot` is an [ACME](https://tools.ietf.org/html/rfc8555) client (Automatic
Certificate Management Environment). It must listen on **port 80** to complete
the [HTTP-01 challenge](https://letsencrypt.org/docs/challenge-types/) — if the
Ingress controller already holds port 80, see method 3.

> [!note]- The HTTP-01 challenge
> certbot asks Let's Encrypt for a certificate for `$DOMAIN` and receives a
> token. Let's Encrypt then fetches
> `http://$DOMAIN/.well-known/acme-challenge/<token>`; that URL must reach
> certbot. When the response matches, the certificate is issued.

> [!example] Hands-on
> - Obtain a certificate, using the convenient `certbot/certbot` image and a
>   volume to retrieve the files:
>   ```bash
>   EMAIL=your.address@example.com
>   docker run --rm -p 80:80 -v $PWD/letsencrypt:/etc/letsencrypt \
>     certbot/certbot certonly \
>     -m $EMAIL \
>     --standalone --agree-tos -n \
>     --domain $DOMAIN \
>     --test-cert
>   ```
> - The files land in `letsencrypt/live/$DOMAIN`, owned by root; grant yourself
>   permissions and copy them here:
>   ```bash
>   sudo chown -R $USER letsencrypt
>   cp letsencrypt/live/$DOMAIN/{cert,privkey}.pem .
>   ```

`--test-cert` uses the staging environment; remove it for a real certificate.

## Method 3: certbot behind an Ingress

When port 80 is taken by the Ingress controller, or the nodes sit on an
internal network, route the HTTP-01 challenge **through** an Ingress instead.
Requests to `/.well-known/acme-challenge/*` must reach certbot. We run certbot
in a container on a node and route traffic to it manually — an excuse to tinker
with Endpoints resources:

- an **Endpoints** listing a hard-coded IP address and port (where certbot will
  listen) — Endpoints is always plural, even a single resource is a list;
- a **Service** corresponding to that Endpoints;
- an **Ingress** sending `/.well-known/acme-challenge/*` to that Service — no
  domain name needed in it.

> [!example] Hands-on
> - Edit `~/container.training/k8s/certbot.yaml`, replacing `A.B.C.D` with the
>   current node's address, and create the resources:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/certbot.yaml
>   ```
> - Run certbot listening on the port listed in the Endpoints (8000):
>   ```bash
>   EMAIL=your.address@example.com
>   docker run --rm -p 8000:80 -v $PWD/letsencrypt:/etc/letsencrypt \
>     certbot/certbot certonly \
>     -m $EMAIL \
>     --standalone --agree-tos -n \
>     --domain $DOMAIN \
>     --test-cert
>   ```
> - As before, grant yourself permissions and copy the files:
>   ```bash
>   sudo chown -R $USER letsencrypt
>   cp letsencrypt/live/$DOMAIN/{cert,privkey}.pem .
>   ```

## Creating the Secret

With `privkey.pem` and `cert.pem` in hand:

> [!example] Hands-on
> - Create the Secret:
>   ```bash
>   kubectl create secret tls $DOMAIN --cert=cert.pem --key=privkey.pem
>   ```

## Ingress with TLS

Add a `tls` section to the Ingress:

```yaml
spec:
  tls:
  - secretName: DOMAIN
    hosts:
    - DOMAIN
  rules: ...
```

The `hosts` list tells the controller which certificate to serve for which
[SNI](https://en.wikipedia.org/wiki/Server_Name_Indication) name. The secret's
name is free — matching the domain is just convenient.

`kubectl create ingress` can do it directly: append `,tls=secret-name` to a
rule, and the domain is inferred from the rule:

```bash
kubectl create ingress hello \
        --rule=hello.example.com/*=hello:80,tls=hello
```

> [!example] Hands-on
> - Add the `tls` section to an existing Ingress. To see what it should look
>   like: `kubectl explain ingress.spec.tls`,
>   `kubectl create ingress --dry-run=client -o yaml ...`, or
>   [`k8s/ingress.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/ingress.yaml).
> - Check that the URL now works over `https` — the controller can take a
>   minute to pick the Secret up.

> [!warning] With Traefik, the `tls` section alone is not enough
> Traefik's Ingress provider reads the `tls` section only to load the
> certificate into its store. The route itself stays plain HTTP, and `https://`
> requests answer **404**. Also tell Traefik to terminate TLS on that route:
>
> ```bash
> kubectl annotate ingress hello \
>         traefik.ingress.kubernetes.io/router.tls=true
> ```
>
> (Or enable TLS on the entrypoint: `--entrypoints.https.http.tls=true`.)
> ingress-nginx does not need this; it serves the `tls` section as-is.

> [!note]- The controller must be configured for Secrets
> Many Ingress controllers support several certificate "stores". Ours must be
> set up to read Kubernetes Secrets, as opposed to, say, obtaining certificates
> itself from Let's Encrypt.

## Security

TLS certificates live in Secrets, so the Ingress controller **must be able to
read Secrets** — and a vulnerability in the controller can be dramatic:
[CVE-2021-25742](https://github.com/kubernetes/ingress-nginx/issues/7837) is
the canonical example. Mitigation: RBAC rules can name specific resources, so
the controller only reads the Secrets it needs. The downside — every TLS secret
must be listed explicitly — beats a full cluster compromise.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/ingress-tls.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/ingress-tls.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, rewritten
> as prose, remark markup converted to Obsidian callouts, two path errors in the
> certbot labs corrected, referenced files inlined or linked.

<!-- uplink -->
Part of [[kubernetes/networking/index|Networking]].
