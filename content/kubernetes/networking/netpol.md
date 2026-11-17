---
title: "Network policies"
description: "Deny by default, then allow selectively — pod selectors, ingress and egress rules, and the traps around services and partial CNI support"
tags: [kubernetes, networking, network-policy, security]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/netpol.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Network policies

Namespaces help to *organize* resources, but they do not isolate anything. By
default, every pod can contact every other pod, and every service accepts traffic
from anyone. To change that, you need *network policies*.

## What a network policy is

A network policy is defined by three things:

- A **pod selector**: which pods it applies to — for example, "all pods in
  namespace `blue` with the label `zone=internal`".
- A list of **ingress rules**: which inbound traffic is allowed — for example,
  "TCP connections to ports 8000 and 8080, from pods labelled `zone=dmz` and from
  the subnet 4.42.6.0/24, except 4.42.6.5".
- A list of **egress rules**: which outbound traffic is allowed.

A policy can provide ingress rules, egress rules, or both.

## How policies apply

- A pod can be selected by any number of policies.
- A pod selected by **no** policy has unrestricted traffic. With no network
  policies at all, everything is allowed.
- As soon as **one** policy selects a pod, all traffic to or from that pod is
  blocked, except what a policy explicitly allows.

This is the "deny all, then allow selectively" model: it is much harder to leave
holes than with "allow all, then block selectively". It also means a selector that
is too broad switches well-secured pods into deny-all without meaning to — scope
selectors precisely.

> [!note]- Filtering is flow-oriented, not packet-oriented
> Policies deal with *connections*. To allow HTTP to pod A you only need an
> ingress rule; no matching egress rule is needed for the responses. The same
> holds for UDP — allowing DNS takes a single rule. Implementations use stateful
> connection tracking.

For traffic from pod A to pod B, **both** ends must allow the connection: A must
be unrestricted or allow it as egress, and B must be unrestricted or allow it as
ingress. A policy in one namespace can therefore never override a restriction
made in another — which stops someone with rights in namespace A from granting
themselves access to namespace B.

## A first network policy

The plan: run a web server, block all access to it, then allow access from
specific pods only.

> [!example] Hands-on
> - Run a web server and find its address:
>   ```bash
>   kubectl create deployment testweb --image=nginx
>   kubectl get pods -o wide -l app=testweb
>   IP=$(kubectl get pods -l app=testweb -o json | jq -r .items[0].status.podIP)
>   ```
>
> - Check that it answers — `curl $IP` shows the "Welcome to nginx!" page:
>   ```bash
>   curl $IP
>   ```

### Deny everything to the web server

The policy selects pods labelled `app=testweb` and specifies an **empty** list of
ingress rules — which matches nothing, so nothing is allowed:

```yaml
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: deny-all-for-testweb
spec:
  podSelector:
    matchLabels:
      app: testweb
  ingress: []
```
<small>Source: [`k8s/netpol-deny-all-for-testweb.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/netpol-deny-all-for-testweb.yaml)</small>

> [!example] Hands-on
> - Apply it, and check that `curl $IP` now times out:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/netpol-deny-all-for-testweb.yaml
>   curl -m3 $IP
>   ```

### Allow specific pods back in

The second policy allows traffic from pods labelled `run=testcurl` — the label
`kubectl run testcurl ...` applies automatically:

```yaml
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: allow-testcurl-for-testweb
spec:
  podSelector:
    matchLabels:
      app: testweb
  ingress:
  - from:
    - podSelector:
        matchLabels:
          run: testcurl
```
<small>Source: [`k8s/netpol-allow-testcurl-for-testweb.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/netpol-allow-testcurl-for-testweb.yaml)</small>

> [!example] Hands-on
> - Apply the policy, then connect from a pod with the right label, and from one
>   without it:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/netpol-allow-testcurl-for-testweb.yaml
>   kubectl run testcurl --rm -i --restart=Never --image=alpine -- wget -qO- -T3 $IP
>   kubectl run testkurl --rm -i --restart=Never --image=alpine -- wget -qO- -T3 $IP
>   ```

The first command shows the nginx page. The second times out after 3 seconds.

> [!note] Correction
> The original lab used `--image=centos -- curl -m3`. CentOS images stopped
> getting updates in 2024; a 300 MB pull to run one `curl` is also no fun on a
> slow link. Alpine's busybox `wget` does the same job (`-T3` is the timeout).
> `--restart=Never` makes the command's exit code reflect the probe: without it
> the pod restarts on failure instead of reporting it.

## An important warning

Some network plugins only support network policies partially:

- Weave added egress support only in 2.4 (July 2018) and `ipBlock` in 2.5.
- Before 2023, AWS EKS did not install a network policy controller at all.

Unsupported features may be **silently ignored** — making you believe you are
secure when you are not. Test your policies; do not just apply them.

## Policies, pods and services

Policies apply to *pods*, but a service balances traffic across several pods. If
some of a service's pods accept your traffic and others do not, connections to
the service will randomly pass or fail, depending on which pod was picked.

## Isolating a whole namespace

A good strategy: let all pods in a namespace talk together, block other
namespaces, and open external access explicitly. Two policies are enough.

Block traffic from other namespaces — select all pods (`podSelector: {}` means
"all pods"), allow only traffic from pods of the same namespace:

```yaml
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: deny-from-other-namespaces
spec:
  podSelector: {}
  ingress:
  - from:
    - podSelector: {}
```

Then re-open the frontend to everyone (an empty `from` list means "all
sources"):

```yaml
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: allow-webui
spec:
  podSelector:
    matchLabels:
      app: webui
  ingress:
  - from: []
```

Both are in [`k8s/netpol-dockercoins.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/netpol-dockercoins.yaml),
written for the upstream DockerCoins demo app: the web UI stays reachable from
outside, while `rng` and `hasher` stop answering on their ClusterIPs from other
namespaces.

> [!tip] `kubectl port-forward` ignores network policies
> `kubectl proxy` and `kubectl port-forward` tunnel through the API server and the
> kubelet, so they connect regardless of network policies. That is a feature for
> debugging — no need to poke holes in the firewall — and a reminder that network
> policies do not protect against someone who already has kubectl access.

Clean up afterwards, or every later exercise in the namespace fails:

```bash
kubectl delete networkpolicies --all
```

## Protecting the control plane?

Blocking pod access to the control plane (API server, etcd) with network
policies seems attractive, but it should not be necessary, and it can hurt:

- not all network plugins support network policies;
- the control plane is already secured, mostly by mutual TLS;
- code in pods can legitimately contact the API, safely, thanks to the
  [[kubernetes/security/authn-authz|API permission model]].

Blocking it may disrupt legitimate workloads without improving security.

## Tools and resources

- [Cilium Network Policy Editor](https://editor.cilium.io/)
- [[kubernetes/networking/cilium/security]] — `CiliumNetworkPolicy`, which adds L7 and
  DNS-based rules, deny rules and an audit mode to what this note describes
- [Tufin Network Policy Viewer](https://orca.tufin.io/netpol/)
- [`kubectl np-viewer`](https://github.com/runoncloud/kubectl-np-viewer) (kubectl plugin)
- By [Ahmet Alp Balkan](https://ahmet.im/): a [talk on network policies](https://www.youtube.com/watch?list=PLj6h78yzYM2P-3-xqvmWaZbbI1sW-ulZb&v=3gGpMmYeEO8)
  (KubeCon NA 2017) and [ready-to-use recipes](https://github.com/ahmetb/kubernetes-network-policy-recipes)
- The [Kubernetes documentation](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/netpol.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/netpol.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, rewritten as
> prose, remark markup converted to Obsidian callouts, lab images modernised,
> referenced files inlined or linked.

<!-- uplink -->
Part of [[kubernetes/networking/index|Networking]].
