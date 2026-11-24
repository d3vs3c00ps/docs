---
title: Identity-based remote access
description: Replacing the flat VPN with per-application access — Pangolin, how it compares to Tailscale and Cloudflare Tunnel, and what actually changes about your exposure
tags: [networking, vpn, zero-trust, wireguard, security]
type: concept
status: complete
---

# Identity-based remote access

The traditional model is a VPN concentrator on the perimeter: authenticate once, get
an address on the internal network, and reach whatever the firewall permits — which
is usually far more than you needed.

The failure mode is well understood. A compromised laptop or a stolen credential
becomes network-level access to everything on that segment, and lateral movement
becomes trivial. Many intrusions that turn into breaches include exactly this step.

The alternative gives access to **specific applications**, decided per request against
an identity, with no network membership implied.

> [!note] Not tested locally
> A concept note: it has no commands or configuration to run.

| | Traditional VPN | Identity-based access |
| --- | --- | --- |
| Grants | An address on the network | Access to one application |
| Decision | Once, at connect | Per request |
| Lateral movement | Whatever the firewall allows | Nothing not explicitly granted |
| Inbound firewall rules | Required | None — the connector dials outward |
| Client software | Always | Often optional for HTTP |

## Pangolin

[Pangolin](https://pangolin.net) is an open-source implementation, built on WireGuard.
It combines a reverse proxy, an identity layer and tunnelling: a connector inside your
network dials **outward** to the Pangolin server, and the server publishes the
application.

- Access decided by identity and context, per application rather than per subnet.
- **Clientless browser access** for HTTP applications, alongside peer-to-peer tunnels
  for everything else.
- The connector sits behind any firewall with no inbound rules.
- Self-hostable, with a commercial licence option.

> [!important] The outbound connector is the structural change
> With no inbound rule, the application itself is **not reachable from the
> internet**. Its own port is not open, and [[security/offensive/naabu|a port scan]]
> of your network finds nothing.
>
> The exposed surface moves: the Pangolin server (or the provider's edge) listens
> on the internet and shows its own login page. The difference from a VPN
> concentrator is what a flaw there gives: a request to one application, not an
> address on your network. The concentrator has long been a favourite target
> because it is internet-facing and grants network access.

## The alternatives

| Tool | Model | Notes |
| --- | --- | --- |
| **Pangolin** | Self-hosted proxy + WireGuard tunnels | Open source, clientless HTTP access, own your control plane |
| **Tailscale** | WireGuard mesh, hosted coordination | Easiest to run. ACLs are per-service, but it is still a network overlay |
| **Headscale** | Self-hosted Tailscale coordination server | Tailscale's model without the hosted dependency |
| **Cloudflare Tunnel** | Outbound connector to Cloudflare's edge | Excellent for public HTTP; your traffic goes through Cloudflare |
| **Teleport** | Protocol-aware proxy for SSH, Kubernetes, databases | Session recording and per-protocol auditing. Heavier |
| **Plain WireGuard** | A tunnel | No identity layer, no per-application policy. Still the right answer sometimes |

> [!tip] Choose by where you want the control plane
> The functional differences are smaller than the operational ones. **Cloudflare
> Tunnel** means your traffic and availability depend on Cloudflare. **Tailscale**
> means the coordination server is theirs, though data is peer-to-peer.
> **Pangolin** and **Headscale** mean you run it, and you are responsible when it
> breaks.
>
> For an internal tool used by five people, hosted is almost certainly right. For
> something under a data-residency obligation, or where a third-party outage is
> unacceptable, self-hosting is worth the operational cost.

## What this does not solve

> [!warning] Per-application access is not per-action authorisation
> Reaching an application over an identity-aware tunnel says nothing about what you may
> do **inside** it. If the application's own authorisation is weak, an attacker who
> gets through the tunnel has the same access any legitimate user does.
>
> This replaces network-level trust with application-level reachability. The
> application still needs real authentication and authorisation — see
> [[kubernetes/security/authn-authz]] for the equivalent argument inside a cluster.

Two other honest limits: the connector is now a critical component in your network
with outbound access to the internet, and a compromise of the control plane is a
compromise of access to everything it fronts. Treat it as tier-0 infrastructure.

## Where to go next

- [[security/cryptography/tls-protocol]] — the transport underneath any of this
- [[kubernetes/networking/netpol]] — the same principle inside a cluster
- [[security/security-roadmap]] — where access control sits among other controls
- [[linux/ssh]] — the thing this is usually replacing

## Sources

- [Pangolin](https://pangolin.net)

<!-- uplink -->
Part of [[networking/index|Networking]].
