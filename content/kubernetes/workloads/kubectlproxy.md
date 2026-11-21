---
title: "Accessing the API with `kubectl proxy`"
description: "Using kubectl proxy to reach the Kubernetes API, and Services, without handling credentials"
tags: [kubernetes, kubectl]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kubectlproxy.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Accessing the API with `kubectl proxy`

The API requires us to authenticate[^1]. There are many authentication methods,
including:

- TLS client certificates (that is what we have used so far);
- various token mechanisms (see the
  [documentation](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#authentication-strategies)).

> [!warning] Correction
> The original also listed "HTTP basic password authentication, from a static file;
> not recommended". It was removed in Kubernetes 1.19: the API server no longer has
> the `--basic-auth-file` option.

[^1]: OK, we lied. If you do not authenticate, you are the user `system:anonymous`.
    By default, that user can only read a few public paths: `/version`, `/healthz`,
    `/livez` and `/readyz`. On clusters set up with kubeadm, it can also read the
    `cluster-info` ConfigMap in `kube-public`. Nothing else.

## Accessing the API directly

Let's see what happens if we try to access the API directly with `curl`.

> [!example] Hands-on
> - Get the ClusterIP allocated to the `kubernetes` Service:
>   ```bash
>   kubectl get svc kubernetes
>   ```
>
> - Replace the IP below and try to connect with `curl`:
>   ```bash
>   curl -k https://10.96.0.1/
>   ```

The API tells us that user `system:anonymous` cannot access this path. (The ClusterIP
only answers from inside the cluster. From outside, use the address of the API server
from your kubeconfig.)

## Authenticating to the API

To talk to the API ourselves, we would need to:

- extract our TLS key and certificate from `~/.kube/config` (they are in PEM format,
  encoded in base64);
- use them to present our certificate when we connect (for instance with
  `curl --cert ... --key ...`, or `openssl s_client -key ... -cert ... -connect ...`);
- work out exactly which credentials to use, once we juggle several clusters;
- change that whole process if we use another authentication method.

There has to be a better way!

## Using `kubectl proxy` for authentication

`kubectl proxy` runs a proxy in the foreground. This proxy:

- lets us access the Kubernetes API without authenticating: `kubectl proxy` adds our
  credentials to each request;
- lets us access the Kubernetes API over plain HTTP.

It is a great tool to learn and experiment with the Kubernetes API. It is also fine for
serious uses, such as one-shot scripts. For unattended use, it is better to create a
[service account](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/).

## Trying `kubectl proxy`

Let's start `kubectl proxy`, then send a simple request with `curl`.

> [!example] Hands-on
> - Start `kubectl proxy` in the background:
>   ```bash
>   kubectl proxy &
>   ```
>
> - Access the API's default route:
>   ```bash
>   curl localhost:8001
>   ```
>
> - Stop the proxy:
>   ```bash
>   kill %1
>   ```

The output is a list of the available API paths.

## OpenAPI (fka Swagger)

The Kubernetes API serves an OpenAPI specification. (OpenAPI was formerly known as
Swagger.) It is at `/openapi/v2`, and, per API group, under `/openapi/v3`.

OpenAPI has many advantages: we can generate client library code, test code, and so on.

For us, it means that we can explore the API with
[Swagger UI](https://swagger.io/tools/swagger-ui/) (for instance with the
[Swagger UI add-on for Firefox](https://addons.mozilla.org/en-US/firefox/addon/swagger-ui-ff/)).

## `kubectl proxy` is intended for local use

- By default, the proxy listens on port 8001. This can be changed with `--port`, and
  `--port=0` lets `kubectl proxy` pick a free port.
- By default, the proxy binds to `127.0.0.1`. So other machines cannot reach it, for
  security reasons.
- By default, the proxy only accepts requests whose `Host` header matches
  `^localhost$,^127\.0\.0\.1$,^\[::1\]$`.

This is great when we run `kubectl proxy` locally. It is not so great when we want to
connect to the proxy from another machine.

> [!note]- Extra details
> ## Running `kubectl proxy` on a remote machine
>
> To connect to the proxy from another machine, we would need to:
>
> - bind to `INADDR_ANY` (all addresses) instead of `127.0.0.1`;
> - accept connections from any host.
>
> This is done with:
> ```
> kubectl proxy --port=8888 --address=0.0.0.0 --accept-hosts=.*
> ```
>
> > [!warning]
> > Do not do this on a real cluster: it opens full, unauthenticated access!

> [!note]- Extra details
> ## Security considerations
>
> Running `kubectl proxy` openly is a huge security risk. It is slightly better to run
> the proxy where you need it (and copy credentials, such as `~/.kube/config`, to that
> place). It is even better to use a limited account with fewer permissions.

## Good to know ...

`kubectl proxy` also gives access to all internal Services. They are exposed at:
```
/api/v1/namespaces/<namespace>/services/<service>/proxy
```

So we can use `kubectl proxy` to reach an internal Service in a pinch. For services
that do not speak HTTP, use `kubectl port-forward`.

This is not very useful when we run `kubectl` on the cluster itself, since we could
connect to the Services directly. But it is very powerful as soon as we run `kubectl`
from a remote machine.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/kubectlproxy.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kubectlproxy.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; removed basic authentication flagged, OpenAPI paths and
> anonymous access detailed.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
