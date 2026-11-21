---
title: Hubble
description: Flow-level observability from the eBPF datapath — the three components, the CLI queries worth knowing, Prometheus metrics, and the retention limit people trip over
tags: [kubernetes, networking, cilium, hubble, observability]
type: howto
status: complete
---

# Hubble

Hubble is Cilium's observability layer. Because the eBPF datapath already sees every
packet and already knows each endpoint's **identity**, Hubble can report flows
labelled with what the workloads *are* rather than which IPs they had.

That is the difference from `tcpdump`: a Hubble flow says
`frontend → backend: HTTP GET /api, FORWARDED`, not `10.42.1.7 → 10.42.2.19`.

## The three components

| Component | Runs as | Scope |
| --- | --- | --- |
| **Hubble observer** | Inside each cilium-agent | That node's flows only |
| **hubble-relay** | Deployment | Aggregates every node into one API |
| **Hubble UI** | Deployment | Service map and flow browser in a web UI |

You want Relay. Without it, `hubble observe` only sees the node whose agent you are
talking to, which is rarely the one where the problem is.

## Enabling it

```bash
helm upgrade cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.0 --namespace kube-system --reuse-values \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
```

Or with cilium-cli:

```bash
cilium hubble enable --ui
```

On RKE2, add it to the `HelmChartConfig` instead — see
[[kubernetes/networking/cilium/install]].

Then install the CLI:

```bash
HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
CLI_ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
curl -sSL --fail --remote-name-all \
  "https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-${CLI_ARCH}.tar.gz{,.sha256sum}"
sha256sum --check "hubble-linux-${CLI_ARCH}.tar.gz.sha256sum"
sudo tar xzvfC "hubble-linux-${CLI_ARCH}.tar.gz" /usr/local/bin
```

## Connecting

Relay listens on port **4245**. Forward it:

```bash
cilium hubble port-forward &
# or, by hand:
# kubectl -n kube-system port-forward service/hubble-relay 4245:80

hubble status
```

`hubble status` reporting the expected number of connected nodes is the check that
Relay is actually aggregating rather than serving one agent.

> [!tip] Port-forward to 4245 specifically
> The CLI defaults to `localhost:4245`. Forward to any other port and every command
> needs `--server` or `HUBBLE_SERVER`. Not worth the friction.

For the UI:

```bash
cilium hubble ui        # opens http://localhost:12000
```

## Querying flows

This is where Hubble earns its place. `hubble observe` is a filtered live tail of the
datapath.

```bash
# everything, live
hubble observe -f

# only what was dropped — the single most useful query
hubble observe --verdict DROPPED

# a specific workload, either direction
hubble observe --pod default/frontend

# between two workloads
hubble observe --from-pod default/frontend --to-pod default/backend

# by label, which is more stable than pod names
hubble observe --from-label app=frontend --to-label app=backend

# traffic leaving the cluster
hubble observe --to-identity world

# DNS lookups
hubble observe --protocol dns

# L7 HTTP, if L7 policy or visibility is enabled
hubble observe --protocol http --http-status 500

# what a policy denied, with the reason
hubble observe --verdict DROPPED --type policy-verdict
```

Verdicts you will see: `FORWARDED`, `DROPPED`, `ERROR`, `AUDIT`. `AUDIT` appears when
policy is in audit mode — the flow was allowed but *would* have been dropped.

Add `-o json` and pipe to `jq` for anything analytical:

```bash
hubble observe --verdict DROPPED -o json --last 500 \
  | jq -r '.flow | "\(.source.namespace)/\(.source.pod_name) -> \(.destination.namespace)/\(.destination.pod_name) \(.l4.TCP.destination_port // "")"' \
  | sort | uniq -c | sort -rn
```

That one command answers "what is being dropped in this cluster, most-frequent
first", which is usually the question.

## The retention limit

> [!warning] Hubble's buffer is small, in memory, and per node
> Flows live in a **ring buffer** in each agent — 4095 events by default. On a busy
> node that is seconds of history. Restarting the agent loses all of it.
>
> Hubble is a live debugging tool, not a log store. If you need to answer questions
> about last Tuesday, export the flows.

Raise the buffer if you need a slightly longer window:

```bash
--set hubble.eventBufferCapacity=16383
```

For real retention, enable flow export and ship it somewhere:

```bash
--set hubble.export.fileMaxSizeMb=50 \
--set hubble.export.static.enabled=true \
--set hubble.export.static.filePath=/var/run/cilium/hubble/events.log
```

Then collect that file with whatever you already run — see
[[kubernetes/observability/index|Observability]].

## Metrics

Hubble exposes Prometheus metrics derived from flows, which is the part that belongs
in dashboards rather than in a terminal:

```bash
--set hubble.metrics.enabled="{dns,drop,tcp,flow,port-distribution,icmp,httpV2}" \
--set hubble.metrics.enableOpenMetrics=true \
--set prometheus.enabled=true \
--set operator.prometheus.enabled=true
```

The `drop` metric is the one worth alerting on: a rising
`hubble_drop_total{reason="Policy denied"}` after a deployment means someone shipped
a workload the policy does not allow.

> [!note] Metric cardinality
> Enabling `httpV2` with pod-level labels on a large cluster produces a lot of
> series. Start with `drop`, `dns` and `tcp`, and add the rest deliberately.

## Security of the flow data

Hubble flows contain source and destination identities, DNS names, and HTTP paths
and methods. That is a meaningful amount of information about your cluster.

- Relay's API is **not** exposed outside the cluster by default. Keep it that way;
  use `port-forward` rather than an Ingress.
- Enable mTLS between agents and Relay with `hubble.tls.enabled=true` (the default in
  recent charts) — verify rather than assume.
- The UI has **no authentication of its own**. If you expose it, put authentication
  in front of it. See [[kubernetes/networking/ingress-tls]].
- L7 visibility means HTTP paths appear in flows. Check that your paths do not carry
  tokens or identifiers you would rather not log.

## Where to go next

- [[kubernetes/networking/cilium/security]] — the policies whose verdicts you are watching
- [[kubernetes/networking/cilium/troubleshooting]] — using Hubble to diagnose drops
- [[kubernetes/networking/cilium/basics]] — why flows carry identities
- [[kubernetes/observability/index|Observability]] — where the metrics and logs should land

<!-- uplink -->
Part of [[kubernetes/networking/cilium/index|Cilium]].
