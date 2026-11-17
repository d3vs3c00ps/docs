---
title: Cilium network security
description: CiliumNetworkPolicy beyond the standard API — L7 and DNS rules, the three enforcement modes, audit before enforce, the host firewall, and where policy stops helping
tags: [kubernetes, networking, cilium, security, networkpolicy]
type: howto
status: complete
---

# Cilium network security

Cilium implements the standard Kubernetes `NetworkPolicy` API, and adds two resources
of its own that go further: `CiliumNetworkPolicy` (namespaced) and
`CiliumClusterwideNetworkPolicy`.

For the standard API and the default-deny model it implies, see
[[kubernetes/networking/netpol]]. This note is what Cilium adds.

## What the Cilium policies add

| Capability | `NetworkPolicy` | `CiliumNetworkPolicy` |
| --- | --- | --- |
| L3/L4 by pod selector | yes | yes |
| **L7 rules** (HTTP method and path, Kafka, gRPC) | no | yes |
| **DNS-based egress** (`toFQDNs`) | no | yes |
| Cluster-scoped policy | no | yes (`CiliumClusterwideNetworkPolicy`) |
| Node/host firewall | no | yes |
| Deny rules | no | yes |
| Entity selectors (`world`, `host`, `kube-apiserver`) | no | yes |

Start with standard `NetworkPolicy`. It is portable, and most of what you need is
L3/L4. Reach for `CiliumNetworkPolicy` when you specifically need something above.

## L7: policy on requests, not just connections

An L4 policy can say "frontend may reach backend on 8080". An L7 policy can say
"frontend may `GET /api/products` on backend, and nothing else".

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: frontend-to-backend
  namespace: shop
spec:
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: GET
                path: "/api/products.*"
              - method: POST
                path: "/api/orders"
```

Requests that match the L4 rule but not an L7 rule get an **HTTP 403**, not a dropped
packet — the connection is allowed, the request is refused. That difference matters
when debugging: the client sees a clean rejection rather than a timeout.

> [!note] L7 policy means a proxy
> Matching HTTP requires parsing them, so matched traffic is redirected through
> cilium-envoy. That adds latency and a failure domain. Use L7 rules where the
> control is worth it — a sensitive internal API — not everywhere.

## DNS-based egress

The most practically useful Cilium-only feature. Allowing egress to a third-party API
by IP is fragile; their addresses change without notice.

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: egress-to-api
  namespace: shop
spec:
  endpointSelector:
    matchLabels:
      app: payments
  egress:
    # DNS must be allowed, and must be visible to Cilium, for toFQDNs to work
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s:k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
    - toFQDNs:
        - matchName: "api.stripe.com"
        - matchPattern: "*.googleapis.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

Cilium watches the pod's DNS responses and allows the addresses that were returned
for names the policy permits.

> [!warning] The DNS rule is not optional
> `toFQDNs` works by observing DNS answers. If the policy does not also allow DNS
> **with a `rules.dns` block**, Cilium never sees the response and every FQDN rule
> fails closed. This is the number-one reason a `toFQDNs` policy "does not work".
>
> An application that caches DNS answers for longer than the TTL, or resolves at
> startup only, can also outlive the allowed entry. Long-lived connections are kept,
> but new ones to a stale address are denied.

## Enforcement modes

Cluster-wide, set with `--set policyEnforcementMode=`:

| Mode | Behaviour |
| --- | --- |
| **default** | An endpoint is default-deny only once some policy selects it. Standard Kubernetes semantics |
| **always** | Every endpoint is default-deny from the start. Nothing talks until allowed |
| **never** | Policy is not enforced at all. Rules are still evaluated for visibility |

`default` is right for almost everyone. `always` is a genuine hardening step for a
cluster where you are confident the policy set is complete — and a reliable way to
break a cluster where you are not.

## Audit before you enforce

The single most useful safety mechanism here, and the reason to prefer Cilium
policies when rolling out a restrictive posture.

```bash
# cluster-wide, as a Helm value
--set policyAuditMode=true

# or for one endpoint, inside the agent on that endpoint's node
# (temporary: it resets when the agent restarts)
cilium-dbg endpoint config <endpoint-id> PolicyAuditMode=Enabled
```

> [!warning] Correction
> An earlier version showed a per-policy annotation (`io.cilium.policy.audit-mode`).
> No such annotation exists. Audit mode is set for the whole daemon or per
> endpoint, as above — not per policy.

In audit mode the policy is evaluated and violations are **reported but allowed**.
Flows appear in Hubble with verdict `AUDIT`:

```bash
hubble observe --verdict AUDIT --last 500 \
  | awk '{print $3, "->", $5}' | sort | uniq -c | sort -rn
```

Run that for a full business cycle — including the batch jobs that only run at
night — then remove the annotation once the list is empty. Going straight to enforce
on a cluster you inherited is how you find out about the reporting job nobody
mentioned.

## Deny rules

Standard `NetworkPolicy` is allow-only; anything not permitted is denied. Cilium adds
explicit deny, which takes precedence over any allow:

```yaml
spec:
  endpointSelector: {}
  egressDeny:
    - toCIDR:
        - 169.254.169.254/32     # cloud instance metadata
```

Blocking the metadata endpoint cluster-wide is worth doing on day one. On most cloud
providers, a pod that can reach it can often obtain the node's IAM credentials — a
container escape that needs no kernel bug. Use a
`CiliumClusterwideNetworkPolicy` so it cannot be forgotten per namespace.

## Host firewall

Cilium can also police traffic to the **nodes** themselves, not just pods:

```bash
--set hostFirewall.enabled=true
```

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: control-plane-access
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/control-plane: ""
  ingress:
    - fromCIDR:
        - 10.0.0.0/8
      toPorts:
        - ports:
            - port: "6443"
              protocol: TCP
    - fromEntities:
        - health
        - remote-node
```

> [!danger] Lock yourself out carefully
> A host policy that omits SSH, the kubelet port, or `remote-node` traffic will cut
> you off from the node and can break the cluster. Always start in audit mode, and
> always have console access before you enforce.

## What policy does not solve

Being honest about the boundary is more useful than a longer feature list:

- **Traffic within a node between pods on the same node** is still subject to policy,
  but nothing crosses the wire — encryption is irrelevant there.
- **A compromised pod with a legitimate identity** is allowed everything its identity
  permits. Policy limits blast radius; it does not detect misuse. That is what
  runtime security tooling is for — see neuvector, and Cilium's sibling
  project **Tetragon** for eBPF-based runtime enforcement.
- **Encryption is a separate control.** Policy says who may talk; it does not make
  the traffic confidential. See [[kubernetes/networking/cilium/wireguard]].
- **Identity is derived from labels**, so anyone who can set labels on a pod can
  choose its identity. Restrict who can create workloads — see
  [[kubernetes/security/index|Kubernetes security]].

## Verifying policy does what you think

```bash
# which policies select this endpoint
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint get <id> -o json \
  | jq '.[0].status.policy.realized'

# watch verdicts live while you reproduce
hubble observe --verdict DROPPED --type policy-verdict -f

# the standard-API view
kubectl describe cnp -A
kubectl get cnp,ccnp -A
```

The [Cilium policy editor](https://editor.cilium.io/) is genuinely useful for getting
the YAML shape right before applying it.

## Where to go next

- [[kubernetes/networking/netpol]] — the standard NetworkPolicy API and default-deny
- [[kubernetes/networking/cilium/hubble]] — watching verdicts, which is how you tune policy
- [[kubernetes/networking/cilium/wireguard]] — confidentiality, the other half
- [[kubernetes/security/index|Kubernetes security]] — authn, authz and the control plane
- security-roadmap — where this sits among everything else

<!-- uplink -->
Part of [[kubernetes/networking/cilium/index|Cilium]].
