---
title: "ExternalDNS"
description: "DNS records created automatically from Services, Ingresses and HTTPRoutes — set up with the official Helm chart and a Linode token"
tags: [kubernetes, networking, dns]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/externaldns.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# ExternalDNS

> [!note] Not tested locally
> The lab needs a real domain name and an API token for a public DNS provider
> (Linode here). Neither exists in the local test harness.

[ExternalDNS](https://github.com/kubernetes-sigs/external-dns) is an open
source controller that "configures external DNS servers dynamically from
Kubernetes resources". Own `example.com`, create an Ingress for
`dev.example.com`, and ExternalDNS creates the `dev.example.com` record
pointing at your Ingress controller — automatically.

Its **sources** — the resources it watches — include Services, Ingresses,
HTTPRoutes (Gateway API), Nodes, [and much more][externaldns-sources]. On the
other side, [more than 25 DNS providers are supported in-tree][externaldns-intree]
and [at least as many through a webhook system][externaldns-webhooks]:

- cloud DNS: Route53, Cloudflare, Exoscale, Linode, OVHcloud, Scaleway...
- self-hosted DNS: PowerDNS, CoreDNS...
- DNS in routers and appliances: Mikrotik, Pi-hole...
- the generic dynamic-update protocol of [RFC2136].

[externaldns-sources]: https://kubernetes-sigs.github.io/external-dns/latest/docs/sources/about/
[externaldns-intree]: https://kubernetes-sigs.github.io/external-dns/latest/docs/providers/
[externaldns-webhooks]: https://kubernetes-sigs.github.io/external-dns/latest/#new-providers
[RFC2136]: https://datatracker.ietf.org/doc/html/rfc2136

## Order of operations

1. Have a domain name — cheap ones at [Porkbun], [Infomaniak] or [BookMyName]
   (no affiliation, just happy customers).
2. Point the domain at a DNS provider — the **NS records** must be right. The
   lab uses Linode DNS; anything works.
3. Install and configure ExternalDNS.
4. Create resources: a Service annotated with
   `external-dns.alpha.kubernetes.io/hostname`, or an Ingress naming hosts.

Pro-tip: lower the domain's default TTL to about 300 seconds before testing —
it limits the pain of *negative caching* when you query an entry that does not
exist yet.

[Porkbun]: https://porkbun.com
[Infomaniak]: https://infomaniak.com/en/domains
[BookMyName]: https://bookmyname.com

## Deploying ExternalDNS

Three options:

1. the container image `registry.k8s.io/external-dns/external-dns`, with your
   own Deployment, RBAC and flags;
2. the [official Helm chart](https://artifacthub.io/packages/helm/external-dns/external-dns)
   — set `provider.name`, pass credentials through `env` (used below);
3. the Bitnami chart — **not recommended since Broadcom's licensing changes**.

The provider token goes in a separate Secret referenced from the chart values,
so it could be managed by another process —
[External Secrets Operator][eso] or
[[kubernetes/configuration/sealed-secrets|Sealed Secrets]].

[eso]: https://external-secrets.io/latest/

> [!example] Hands-on
> - Install the chart first — it creates the `external-dns` Namespace that the
>   Secret goes into:
>   ```bash
>   helm upgrade --install external-dns external-dns \
>     --repo https://kubernetes-sigs.github.io/external-dns/ \
>     --namespace external-dns --create-namespace \
>     --set provider.name=linode \
>     --set env[0].name=LINODE_TOKEN \
>     --set env[0].valueFrom.secretKeyRef.name=external-dns \
>     --set env[0].valueFrom.secretKeyRef.key=LINODE_TOKEN \
>     #
>   ```
> - Create an API token on Linode
>   ([on this page](https://cloud.linode.com/profile/tokens), "Create A
>   Personal Access Token"), and put it in the Secret:
>   ```bash
>   kubectl create secret generic external-dns --namespace external-dns \
>     --from-literal=LINODE_TOKEN=...
>   ```
> - Check the pods:
>   ```bash
>   kubectl get pods --namespace=external-dns
>   ```

Startup can take a minute: the Secret did not exist when the chart deployed,
so the pod sits in `CreateContainerConfigError` until it does. Give it a
minute, or `kubectl describe` it.

## Testing ExternalDNS

Assuming the domain is `example.com`:

```bash
# a record with the ExternalIP of a LoadBalancer Service
kubectl annotate service web \
  external-dns.alpha.kubernetes.io/hostname=demo-public.example.com

# a record with the ClusterIP of a ClusterIP Service
kubectl annotate service web \
  external-dns.alpha.kubernetes.io/internal-hostname=demo-private.example.com
```

The records show up in the provider's web interface; the logs tell the story:

```bash
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns
```

> [!note]- With Ingress resources, watch the ADDRESS field
> ExternalDNS reads the Ingress's `ADDRESS` field to know which IP to publish.
> The Ingress controller is supposed to fill it in; some do not, without extra
> configuration — for Traefik, look at the `publishedService` option.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/externaldns.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/externaldns.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, rewritten
> as prose, remark markup converted to Obsidian callouts, referenced files
> inlined or linked.

<!-- uplink -->
Part of [[kubernetes/networking/index|Networking]].
