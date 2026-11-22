---
title: WireGuard transparent encryption
description: Encrypting pod traffic between nodes with WireGuard — enabling it, what node encryption adds, the MTU trap, and an honest comparison with IPsec
tags: [kubernetes, networking, cilium, wireguard, encryption, security]
type: howto
status: complete
---

# WireGuard transparent encryption

Pod-to-pod traffic between nodes is plaintext on the wire by default, whether or not
it is encapsulated — VXLAN is a wrapper, not encryption. Cilium can encrypt it
transparently, with no changes to workloads, using either **WireGuard** or **IPsec**.

WireGuard is the one to reach for. It is simpler to operate, needs no key
distribution of your own, and is fast.

For the cryptography underneath, see foundations.

## Prerequisites

- Linux **5.6 or newer** with WireGuard in the kernel (`CONFIG_WIREGUARD=m` or `=y`).
  Every currently supported distribution qualifies.
- UDP port **51871** open between nodes. If your nodes sit behind a security group or
  firewall, this is the step that gets forgotten.
- Kernel module available:

```bash
# on each node
zgrep CONFIG_WIREGUARD /proc/config.gz 2>/dev/null || \
  grep CONFIG_WIREGUARD /boot/config-$(uname -r)
```

## Enabling it

```bash
helm upgrade cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.0 --namespace kube-system --reuse-values \
  --set encryption.enabled=true \
  --set encryption.type=wireguard
```

Restart the agents, then confirm:

```bash
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium

kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i encryption
# Encryption:  Wireguard  [NodeEncryption: Disabled, cilium_wg0 (Pubkey: ..., Port: 51871, Peers: 2)]
```

`Peers: 2` on a three-node cluster is correct — each node peers with the others.
A peer count lower than `nodes - 1` means some nodes cannot reach each other on
51871.

**Key management is automatic.** Each agent generates a keypair on startup and
publishes its public key through the `CiliumNode` resource; peers pick it up from
there. There is nothing for you to distribute, rotate or store — and nothing to lose.

```bash
kubectl get ciliumnodes -o custom-columns=\
'NODE:.metadata.name,PUBKEY:.metadata.annotations.network\.cilium\.io/wg-pub-key'
```

## What is and is not encrypted

By default, Cilium encrypts **pod-to-pod traffic that crosses a node boundary**.
That leaves gaps:

| Traffic | Encrypted by default |
| --- | --- |
| Pod to pod, different nodes | **Yes** |
| Pod to pod, same node | No — it never leaves the node |
| Host-network pods (kubelet, agents) | No |
| Node to node (health checks, etcd) | No |
| Pod to outside the cluster | No |

To cover the host-network traffic as well:

```bash
--set encryption.nodeEncryption=true
```

This extends coverage to node-to-node, pod-to-node and node-to-pod traffic —
kubelet health checks, `hostNetwork: true` workloads, and similar.

> [!warning] Node encryption is only *eventually* consistent
> Coverage depends on node and endpoint information propagating into each agent's
> IPCache. During that window traffic can transit unencrypted, and the strict-mode
> ingress guarantee does not cover node-to-node traffic. It is a meaningful
> improvement, not a hard guarantee at every instant.
>
> If you need a hard guarantee, terminate encryption in the workloads themselves —
> mTLS — and treat this as defence in depth.

## The MTU trap

This is the failure people actually hit, and it does not look like an encryption
problem.

WireGuard adds around **60 bytes** of overhead. Combined with VXLAN's ~50, the space
left for payload shrinks. Cilium adjusts pod MTU for its own encapsulation, but the
node route MTU does **not** account for the WireGuard tunnel when node encryption is
enabled.

The symptom is characteristic: small requests work, large ones hang. `curl` to a
health endpoint is fine; a large HTTP POST or a TLS handshake with a big certificate
chain stalls. Fragments get dropped in the eBPF ingress path with
`DROP_FRAG_NOT_FOUND`.

Diagnose it by finding the largest packet that survives:

```bash
kubectl exec -it probe -- ping -M do -s 1372 <peer-pod-ip>
kubectl exec -it probe -- ping -M do -s 1400 <peer-pod-ip>   # fails at the boundary
```

Fix it by setting the MTU explicitly, below the underlay minus all overheads:

```bash
--set MTU=1370
```

Then confirm drops have stopped:

```bash
hubble observe --verdict DROPPED --last 200 | grep -i frag
```

> [!tip] Suspect MTU whenever "it works but big things hang"
> Every overlay-plus-encryption combination has this failure mode. It is worth
> checking before anything else, because the alternative explanations are all much
> harder to rule out.

## WireGuard or IPsec

Cilium supports both. They are not equivalent.

| | WireGuard | IPsec |
| --- | --- | --- |
| Key management | Automatic, per-node keypairs | You supply and rotate a secret |
| Setup | One Helm flag | Kubernetes Secret plus key rotation procedure |
| Algorithms | Fixed modern suite (ChaCha20-Poly1305, Curve25519) | Configurable, AES-GCM |
| FIPS 140 validation | Not available | Available |
| Operational burden | Very low | Real |

Choose **WireGuard** unless a compliance regime specifically requires FIPS-validated
cryptography, which is the main reason IPsec still exists here. WireGuard's fixed
algorithm choice is a feature — there is nothing to misconfigure, and no negotiation
to downgrade. See foundations on why a small fixed suite is
usually the safer design.

You cannot run both at once.

## Performance

Expect single-digit to low-double-digit percentage throughput cost on modern CPUs;
WireGuard's ChaCha20-Poly1305 is fast in software and does not need AES hardware
acceleration. The overhead is more noticeable on small packets, where per-packet cost
dominates, than on bulk transfer.

Measure it on your own hardware before assuming:

```bash
cilium connectivity perf
```

## Verifying it is actually on

Do not take the Helm values as evidence. Check the datapath, then check the wire:

```bash
# 1. the agent agrees
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status

# 2. the interface exists and has peers
kubectl -n kube-system exec ds/cilium -- ip -d link show cilium_wg0

# 3. capture on the node and confirm you see WireGuard, not readable payload
sudo tcpdump -ni any udp port 51871 -c 5
```

If step 3 shows plaintext pod traffic on the underlay interface alongside the
WireGuard flow, something is bypassing encryption — most often host-network traffic,
which needs `nodeEncryption=true`.

## Where to go next

- [[kubernetes/networking/cilium/security]] — policy, which is the other half of this
- [[kubernetes/networking/cilium/troubleshooting]] — when connectivity breaks after enabling it
- foundations — what ChaCha20-Poly1305 and Curve25519 are doing
- [[kubernetes/networking/cilium/install]] — where these Helm values belong

<!-- uplink -->
Part of [[kubernetes/networking/cilium/index|Cilium]].
