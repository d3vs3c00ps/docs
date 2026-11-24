---
title: "Networking"
description: "Packet filtering with Netfilter, through both its front-ends."
tags: [networking]
type: moc
status: complete
---

<!-- generated-moc -->

# Networking

Packet filtering with Netfilter, through both its front-ends.


| Note | | What it covers |
| --- | --- | --- |
| [[networking/iptables\|iptables]] | reference | Netfilter filtering with iptables — tables and hooks, a default-deny baseline, common attack mitigations and persistence |
| [[networking/nftables\|nftables]] | reference | Netfilter packet filtering with nftables — tables and chains, a host firewall, sets, NAT, persistence and monitoring |
| [[networking/sztp\|Secure Zero Touch Provisioning]] | concept | RFC 8572 — why DHCP-based bootstrapping is unauthenticated, how SZTP establishes trust before configuration, and where it fits alongside PXE and measured boot |
| [[networking/traffic-visualisation\|Visualising traffic and firewall rules]] | how-to | Turning packet captures into topology graphs with PcapViz, and iptables rulesets into flow diagrams with iptable_vis |
| [[networking/zero-trust-access\|Identity-based remote access]] | concept | Replacing the flat VPN with per-application access — Pangolin, how it compares to Tailscale and Cloudflare Tunnel, and what actually changes about your exposure |

Part of [[index|Ops Notes]].
