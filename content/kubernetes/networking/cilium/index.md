---
title: "Cilium"
description: "The eBPF CNI in depth — how the datapath and identity model work, installing it on Helm or RKE2, Hubble, WireGuard encryption, policy, and what to run when it will not come up."
tags: [cilium]
type: moc
status: complete
---

<!-- generated-moc -->

# Cilium

The eBPF CNI in depth — how the datapath and identity model work, installing it on Helm or RKE2, Hubble, WireGuard encryption, policy, and what to run when it will not come up.


| Note | | What it covers |
| --- | --- | --- |
| [[kubernetes/networking/cilium/basics\|How Cilium works]] | concept | The eBPF datapath, identity-based security, the routing and IPAM modes you have to choose between, and what replacing kube-proxy actually changes |
| [[kubernetes/networking/cilium/hubble\|Hubble]] | how-to | Flow-level observability from the eBPF datapath — the three components, the CLI queries worth knowing, Prometheus metrics, and the retention limit people trip over |
| [[kubernetes/networking/cilium/install\|Installing Cilium]] | how-to | Prerequisites, Helm and cilium-cli installs, the kube-proxy-free bootstrap, RKE2's bundled Cilium, and verifying the result before you trust it |
| [[kubernetes/networking/cilium/security\|Cilium network security]] | how-to | CiliumNetworkPolicy beyond the standard API — L7 and DNS rules, the three enforcement modes, audit before enforce, the host firewall, and where policy stops helping |
| [[kubernetes/networking/cilium/troubleshooting\|Cilium troubleshooting]] | reference | A triage order that works, the eBPF state worth inspecting, and the specific failures — crash-looping agents, stuck pods, MTU, identity churn — with what each actually looks like |
| [[kubernetes/networking/cilium/wireguard\|WireGuard transparent encryption]] | how-to | Encrypting pod traffic between nodes with WireGuard — enabling it, what node encryption adds, the MTU trap, and an honest comparison with IPsec |

Part of [[kubernetes/networking/index|Networking]].
