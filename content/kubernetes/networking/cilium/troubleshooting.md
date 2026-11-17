---
title: Cilium troubleshooting
description: A triage order that works, the eBPF state worth inspecting, and the specific failures — crash-looping agents, stuck pods, MTU, identity churn — with what each actually looks like
tags: [kubernetes, networking, cilium, troubleshooting, ebpf]
type: reference
status: complete
---

# Cilium troubleshooting

Cilium failures are usually one of five things. Working through them in this order
finds the cause faster than starting from the symptom.

## Triage order

```bash
# 1. Is the install healthy at all?
cilium status --wait

# 2. Does this specific node's datapath agree?
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose

# 3. Does real traffic work?
cilium connectivity test

# 4. What is being dropped, and why?
hubble observe --verdict DROPPED --last 200

# 5. Collect everything, for a bug report or a colleague
cilium sysdump
```

Remember the two CLIs: `cilium` is cilium-cli on your workstation, `cilium-dbg` runs
inside an agent pod and reports one node. See
[[kubernetes/networking/cilium/basics]].

## Inspecting the eBPF state

When the summary commands are not enough, the maps are the source of truth:

```bash
CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium \
  --field-selector spec.nodeName=<node> -o name | head -1)
K="kubectl -n kube-system exec $CILIUM_POD --"

$K cilium-dbg endpoint list          # every pod on this node, and its policy state
$K cilium-dbg identity list          # label sets to numeric identities
$K cilium-dbg service list           # Services as the datapath sees them
$K cilium-dbg bpf lb list            # load balancer map entries
$K cilium-dbg bpf tunnel list        # tunnel endpoints, in tunnel mode
$K cilium-dbg bpf ipcache list       # IP to identity mapping
$K cilium-dbg map list --verbose     # every map, with entry counts
$K cilium-dbg monitor -t drop        # live drop events on this node
```

`cilium-dbg monitor` is the lowest-level view available and shows drops with reason
codes that Hubble summarises. Use it when Hubble says a flow was dropped and you need
to know precisely where.

## The agent crash-loops

Check the logs first — the cause is almost always stated plainly:

```bash
kubectl -n kube-system logs ds/cilium -c cilium-agent --previous | tail -50
```

| Log says | Cause | Fix |
| --- | --- | --- |
| `Unable to contact k8s api-server` | `kubeProxyReplacement=true` without `k8sServiceHost` | Set `k8sServiceHost` / `k8sServicePort` |
| `BPF filesystem is not mounted` | `/sys/fs/bpf` missing and not creatable | Mount bpffs on the node |
| `Kernel version ... not supported` | Kernel too old for an enabled feature | Upgrade the kernel or disable the feature |
| `Failed to start: unable to init` + `CONFIG_...` | Missing kernel config | Check the required options for the feature |
| `Cannot allocate memory` on map creation | Memlock limit or map sizing | Raise limits, or reduce `bpf.mapDynamicSizeRatio` |

> [!important] The kube-proxy-free bootstrap deadlock
> This is the most common broken install, and it is self-inflicted every time.
>
> With `kubeProxyReplacement=true` and no kube-proxy, nothing implements the
> `kubernetes` Service — but that is exactly how the agent would find the API
> server. It cannot, so it never programs Services, so the Service never works.
>
> Break the loop by giving the agent a direct address:
>
> ```bash
> --set k8sServiceHost=<control-plane IP, VIP or LB>
> --set k8sServicePort=6443
> ```
>
> On RKE2 use `127.0.0.1`, which reaches its per-node API proxy.

## Pods stuck in ContainerCreating

Almost always CNI configuration or IPAM.

```bash
kubectl describe pod <pod> | tail -20
# "failed to setup network for sandbox ... plugin type=cilium-cni"
```

Check, in order:

```bash
# 1. Is there a CNI config, and is it Cilium's?
ls -l /etc/cni/net.d/
cat /etc/cni/net.d/05-cilium.conflist

# 2. Is there a leftover config from a previous CNI?
#    The FIRST file lexicographically wins, silently.

# 3. Is the agent running on THIS node?
kubectl -n kube-system get pod -l k8s-app=cilium -o wide | grep <node>

# 4. Has the node run out of pod addresses?
kubectl get ciliumnode <node> -o json | jq '.spec.ipam'
```

An exhausted per-node IPAM block is a quiet failure: existing pods are fine, new ones
never get an address. Widen `clusterPoolIPv4MaskSize` or the cluster CIDR — both
require care and, in practice, a rebuild.

## Connectivity works, but not always

The classic MTU signature: small requests succeed, large ones hang. TLS handshakes
stall partway. `curl` to `/healthz` is fine but a real API call is not.

```bash
# find the largest packet that survives
kubectl exec -it probe -- ping -M do -s 1372 <peer-pod-ip>
kubectl exec -it probe -- ping -M do -s 1400 <peer-pod-ip>
```

Every layer takes its cut — VXLAN roughly 50 bytes, WireGuard roughly 60 — and the
overheads stack. Set MTU explicitly:

```bash
--set MTU=1370
```

See [[kubernetes/networking/cilium/wireguard]] for the encryption case specifically,
where the node route MTU does not account for the tunnel.

## Policy is dropping traffic you expected to work

```bash
hubble observe --verdict DROPPED --type policy-verdict --last 100
```

The flow shows both identities and which direction was denied. Then check what the
endpoint's realised policy actually is — not what you think you applied:

```bash
$K cilium-dbg endpoint get <id> -o json | jq '.[0].status.policy.realized'
```

Common causes:

- **Egress policy without a DNS rule.** `toFQDNs` needs `rules.dns` on port 53 or it
  fails closed. See [[kubernetes/networking/cilium/security]].
- **Both an ingress and an egress policy are needed.** Denying at either end blocks
  the flow; people write one and test the other.
- **`world` vs a specific CIDR.** Traffic to an external address is identity `world`
  unless a CIDR rule gives it a narrower identity.
- **A default-deny arrived by accident.** Any policy selecting an endpoint makes it
  default-deny for that direction. An unrelated policy with a loose selector will do
  this cluster-wide.

## Services do not resolve or connect

```bash
$K cilium-dbg service list | grep <service-ip>
$K cilium-dbg bpf lb list | grep <service-ip>
```

If the Service is absent from the datapath, the agent is not seeing the API server or
the endpoints. If it is present with **no backends**, the problem is upstream of
Cilium — check the EndpointSlice:

```bash
kubectl get endpointslices -l kubernetes.io/service-name=<svc>
```

That distinction saves a lot of time: no backends is a Kubernetes problem, not a CNI
problem.

## Identity churn

Symptoms: the operator is busy, `cilium identity list` is very long, policy takes
noticeably long to converge.

Cause: a label that changes per pod — a hash, a timestamp, a pod name copied into a
label — so every pod gets a distinct identity instead of sharing one.

```bash
kubectl get ciliumidentities --no-headers | wc -l
kubectl get ciliumidentities -o json \
  | jq -r '.items[].security-labels | keys[]' | sort | uniq -c | sort -rn | head
```

Fix the label, or exclude it from identity computation:

```bash
--set labels="k8s:app k8s:io.kubernetes.pod.namespace k8s:tier"
```

Only the listed labels then contribute to identity. See
[[kubernetes/networking/cilium/basics]] on why identity count, not pod count, is what
matters.

## After an upgrade

```bash
kubectl -n kube-system rollout status ds/cilium
cilium status --wait
cilium connectivity test
```

If something regressed, check whether `--reuse-values` silently kept an old setting
or missed a new default — see [[kubernetes/networking/cilium/install]]. Cilium
supports one minor version step at a time; skipping minors is untested and a
plausible cause of otherwise inexplicable behaviour.

## Collecting everything

For a bug report, or before you start changing things:

```bash
cilium sysdump --output-filename cilium-sysdump-$(date +%Y%m%d)
```

It gathers agent and operator logs, eBPF map contents, endpoint and identity lists,
Kubernetes resources and node information into one archive.

> [!warning] A sysdump contains cluster detail
> Pod names, namespaces, labels, IPs, policies and often DNS names. Review it before
> attaching it to a public issue.

## Where to go next

- [[kubernetes/networking/cilium/basics]] — the model these commands are reporting on
- [[kubernetes/networking/cilium/install]] — the settings most often at fault
- [[kubernetes/networking/cilium/hubble]] — flow queries in more depth
- [[kubernetes/networking/cilium/security]] — policy semantics

<!-- uplink -->
Part of [[kubernetes/networking/cilium/index|Cilium]].
