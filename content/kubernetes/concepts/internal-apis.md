---
title: "Kubernetes Internal APIs"
description: "The health, metrics and internal API ports of etcd, the kubelet, kube-proxy, the controller manager and the scheduler"
tags: [kubernetes, architecture]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/internal-apis.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Kubernetes Internal APIs

Almost every Kubernetes component has an internal API. Some components have several
APIs, on different ports.

- At the very least, you can use these APIs for health checks. Do it if you deploy and
  operate Kubernetes yourself.
- Kubernetes uses some of them itself. For example, the API server gets container logs
  from the kubelet.

This page reviews these APIs. The ports are the defaults of a cluster built with
`kubeadm`, such as a [[kubernetes/cluster-setup/kind|kind]] cluster.

## API hunting guide

This is how these APIs were found:

1. Look for open ports on the nodes (worker nodes and control plane nodes).
2. Check which process owns each port.
3. Probe the port, with `curl` or other tools.
4. Read the source code of that process, in particular to find the API routes.

On a node, this lists the listening TCP ports and their processes:

```bash
ss -ltnp
```

`ss` cuts process names to 15 characters, so `kube-controller-manager` shows as
`kube-controller`. Most health ports listen on `127.0.0.1` only: run the probes on the
node itself.

## etcd

| Port | Use | Protocol |
| --- | --- | --- |
| 2379/tcp | etcd clients | HTTPS, requires mTLS (mutual TLS) authentication |
| 2380/tcp | etcd peers | HTTPS, requires mTLS authentication |
| 2381/tcp | etcd health check | HTTP, no authentication |

Port 2381 has two API routes, `/health` and `/metrics`:

```bash
curl http://127.0.0.1:2381/health
```

It answers `{"health":"true","reason":""}`.

## kubelet

| Port | Use | Protocol |
| --- | --- | --- |
| 10248/tcp | health check | HTTP, no authentication |
| 10250/tcp | internal API | HTTPS, requires authentication |

Port 10248 has a single API route, `/healthz`, that returns `ok`:

```bash
curl http://127.0.0.1:10248/healthz
```

The API server uses port 10250 to get logs, and to run `kubectl exec`,
`kubectl attach` and `kubectl port-forward`. Without a client certificate, it answers
`Unauthorized`.

> [!note]- Extra details
> ## kubelet API
>
> You can authenticate with a client certificate, for example your admin certificate.
> These routes are available:
>
> - `/healthz`
> - `/configz` (the kubelet configuration)
> - `/metrics`
> - `/pods` (the *desired state*)
> - `/runningpods/` (the *current state*, from the container runtime)
> - `/logs/` (serves the files in `/var/log`)
> - `/containerLogs/<namespace>/<podname>/<containername>` (add `?tail=10`, for example)
> - `/run`, `/exec`, `/attach`, `/portForward`
>
> See the [kubelet source code](https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/server/server.go)
> for details.
>
> You do not need a certificate on the node to reach these routes: the API server can
> proxy them for you. `NODE` is a node name from `kubectl get nodes`:
>
> ```bash
> kubectl get --raw /api/v1/nodes/NODE/proxy/healthz
> kubectl get --raw /api/v1/nodes/NODE/proxy/configz
> ```

> [!note]- Extra details
> ## Trying the kubelet API
>
> This example works on a cluster deployed with `kubeadm`.
>
> 1. Get the key and certificate of the `cluster-admin` user. With `kubeadm`, they are
>    in `/etc/kubernetes/admin.conf`. From your kubeconfig:
>    ```bash
>    kubectl config view --raw --minify \
>        -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d >admin.crt
>    kubectl config view --raw --minify \
>        -o jsonpath='{.users[0].user.client-key-data}' | base64 -d >admin.key
>    ```
> 2. Log into a node.
> 3. Copy the key and certificate to the node.
> 4. Find the name of the `kube-proxy` Pod that runs on that node.
> 5. Run this command, with your Pod name instead of `kube-proxy-xy123`:
>    ```bash
>    curl -k --cert admin.crt --key admin.key -X POST \
>        "https://localhost:10250/run/kube-system/kube-proxy-xy123/kube-proxy?cmd=kube-proxy%20--version"
>    ```
>
> It runs `kube-proxy --version` in the Pod and prints, for example,
> `Kubernetes v1.37.0`.
>
> > [!warning] In the URL, not the body
> > Current kubelets read `cmd` from the URL query only: with `-d cmd=...` in the
> > request body, the command is empty and the call fails. Do not put the Pod name in
> > backquotes, or the shell runs it as a command. The `kube-proxy` image has no `ls`,
> > so the example runs `kube-proxy --version`.

## kube-proxy

| Port | Use | Protocol |
| --- | --- | --- |
| 10249/tcp | health check and metrics | HTTP, no authentication |
| 10256/tcp | another health check | HTTP, no authentication |

Port 10249 has a few API routes: `/healthz` (returns `ok`), `/configz` and `/metrics`.
Port 10256 has a `/healthz` route too, but this one answers with a JSON document that
contains timestamps:

```bash
curl http://127.0.0.1:10249/healthz
curl http://127.0.0.1:10256/healthz
```

## kube-controller-manager and kube-scheduler

| Port | Component | Protocol |
| --- | --- | --- |
| 10257/tcp | kube-controller-manager | HTTPS, optional mTLS authentication |
| 10259/tcp | kube-scheduler | HTTPS, optional mTLS authentication |

Both have the same routes. `/healthz` needs no authentication. `/configz` and
`/metrics` do: use the admin key and certificate, for example.

```bash
curl -k https://127.0.0.1:10257/healthz
curl -k --cert admin.crt --key admin.key https://127.0.0.1:10257/metrics
```

Without the certificate, `/metrics` answers `403 Forbidden` for the user
`system:anonymous`.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/internal-apis.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/internal-apis.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose and tables, with probe commands and a corrected kubelet `/run` example.

<!-- uplink -->
Part of [[kubernetes/concepts/index|Concepts]].
