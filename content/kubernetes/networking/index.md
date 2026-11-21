---
title: "Networking"
description: "The pod network, Services, Ingress, and restricting traffic with network policies."
tags: [networking]
type: moc
status: complete
---

<!-- generated-moc -->

# Networking

The pod network, Services, Ingress, and restricting traffic with network policies.

## Sections

- [[kubernetes/networking/cilium/index|Cilium]]

## Notes in this section

| Note | | What it covers |
| --- | --- | --- |
| [[kubernetes/networking/accessinternal\|Accessing internal services]] | lab | Reaching a ClusterIP service from your machine without exposing it — kubectl proxy for HTTP, kubectl port-forward for any TCP |
| [[kubernetes/networking/cni-internals\|CNI internals]] | lab | How CNI plugins are really invoked — environment variables, JSON on stdin and stdout, plugin chains, and instrumenting a plugin to watch it happen |
| [[kubernetes/networking/cni\|The Container Network Interface]] | lab | How kubelet and the runtime find and invoke CNI plugins, conf vs conflist, and a kube-router walkthrough with BGP routing |
| [[kubernetes/networking/externaldns\|ExternalDNS]] | lab | DNS records created automatically from Services, Ingresses and HTTPRoutes — set up with the official Helm chart and a Linode token |
| [[kubernetes/networking/gateway-api\|The Gateway API]] | lab | The successor to Ingress — Gateways, HTTPRoutes, filters, weighted canary routing, and the permission model Ingress never had |
| [[kubernetes/networking/ingress-advanced\|Optimizing request flow]] | concept | Cutting hops between client and pod — traffic policies, DaemonSet controllers, and getting the real client IP through the stack |
| [[kubernetes/networking/ingress-canary\|Ingress and canary releases]] | concept | What a canary release is, a historical Traefik v1 weighted-routing example, and the Gateway API way to do it today |
| [[kubernetes/networking/ingress-setup\|Setting up an Ingress Controller]] | lab | Installing Traefik with Helm — LoadBalancer, hostPort, hostNetwork and dev-cluster strategies, plus the dashboard |
| [[kubernetes/networking/ingress-tls\|Ingress and TLS certificates]] | lab | TLS secrets referenced from Ingress resources — self-signed certs, certbot and the HTTP-01 challenge, and why production uses cert-manager |
| [[kubernetes/networking/ingress\|Exposing HTTP services with Ingress resources]] | lab | Layer-7 routing on a single IP — Ingress controllers, exact and prefix rules, virtual hosting, and why Gateway API is the successor |
| [[kubernetes/networking/k8gb\|K8GB]] | concept | DNS-based global load balancing across clusters — how delegation works, the Gslb resource, failover and geo strategies, and what DNS caching costs you |
| [[kubernetes/networking/kubenet\|Kubernetes network model]] | concept | One big flat IP network — what the model guarantees, what the CNI provides, and how to pick a network stack |
| [[kubernetes/networking/netpol\|Network policies]] | lab | Deny by default, then allow selectively — pod selectors, ingress and egress rules, and the traps around services and partial CNI support |
| [[kubernetes/networking/service-types\|Service types]] | lab | ClusterIP, NodePort, LoadBalancer, ExternalName — plus headless services, endpoints and traffic policies |

> [!info] Derived from container.training
> Pages in this section marked with a `source` in their frontmatter are
> derived from [container.training](https://github.com/jpetazzo/container.training)
> under CC BY 4.0, with changes. See [[attribution]].

Part of [[kubernetes/index|Kubernetes]].
