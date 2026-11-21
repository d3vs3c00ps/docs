---
title: goldpinger
description: Continuous pod-to-pod connectivity checking — a DaemonSet that pings every peer and draws the result, for finding partial network failures
tags: [kubernetes, observability, networking, troubleshooting, monitoring]
type: howto
status: complete
---

# goldpinger

[goldpinger](https://github.com/bloomberg/goldpinger) is a DaemonSet where every
instance continuously calls every other instance, and reports the result as a graph
and as Prometheus metrics.

It exists for a specific and genuinely difficult failure: **partial** cluster network
failure. Everything is `Ready`, most traffic works, and some pod-to-pod paths do not.
Application symptoms are intermittent timeouts on a subset of requests, which is
almost impossible to attribute without a systematic probe.

> [!important] It answers a question no other tool does
> `kubectl get nodes` shows nodes as Ready. Node exporter shows healthy interfaces.
> The CNI reports no errors. Meanwhile node 7 cannot reach node 12 because of an
> asymmetric route, an MTU mismatch, a stale VXLAN FDB entry, or a security group
> applied to one subnet.
>
> goldpinger tests the **N×N mesh** directly, so the answer is a specific pair of
> nodes rather than a suspicion.

## Deploying

```bash
kubectl create namespace goldpinger
```

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: goldpinger
  namespace: goldpinger
spec:
  selector:
    matchLabels:
      app: goldpinger
  template:
    metadata:
      labels:
        app: goldpinger
    spec:
      serviceAccountName: goldpinger
      tolerations:
        - operator: Exists          # run on every node, including tainted ones
      containers:
        - name: goldpinger
          image: bloomberg/goldpinger:3.11.5
          env:
            - name: HOST
              value: "0.0.0.0"
            - name: PORT
              value: "8080"
            - name: HOSTNAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: PING_TIMEOUT
              value: "2s"
            - name: CHECK_TIMEOUT
              value: "5s"
            - name: CHECK_ALL_TIMEOUT
              value: "10s"
          ports:
            - containerPort: 8080
              name: http
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

> [!warning] Correction
> An earlier version of this page used the tag `v3.10.3`, which does not exist:
> goldpinger tags have no `v` prefix.

It needs RBAC to list its own pods, which is how instances discover each other: a
ServiceAccount, a ClusterRole, and a binding between them:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: goldpinger
  namespace: goldpinger
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: goldpinger
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: goldpinger
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: goldpinger
subjects:
  - kind: ServiceAccount
    name: goldpinger
    namespace: goldpinger
```

And a Service, for the web interface and for Prometheus:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: goldpinger
  namespace: goldpinger
spec:
  selector:
    app: goldpinger
  ports:
    - port: 8080
      targetPort: http
      name: http
```

`tolerations: [{operator: Exists}]` matters — without it, tainted nodes are excluded,
and those are frequently the ones with the network problem.

## The interface

```bash
kubectl port-forward -n goldpinger svc/goldpinger 8080:8080
```

`http://localhost:8080` shows a graph: nodes as vertices, connectivity as edges,
failures in red. A single unreachable pair is immediately visible, which is the whole
point.

The API behind it:

```bash
curl -s localhost:8080/check_all | jq -r '.. | objects | select(.OK == false) | .PodIP'
curl -s localhost:8080/healthz
```

`check_all` returns `hosts` (the list of instances) and `responses`: for each instance,
the result of its calls to every peer (`OK`, `PodIP`, `error`...). The jq filter looks at
every level and prints the address of each failed call: an instance that does not
answer at all, or a peer that one instance cannot reach. No output means a healthy
mesh.

## Metrics and alerting

The graph is for incidents; the metrics are for noticing before you have one.

```text
goldpinger_peers_response_time_s_bucket{call_type="ping",goldpinger_instance="...",host_ip="...",pod_ip="..."}
goldpinger_errors_total{goldpinger_instance="...",type="ping"}
goldpinger_stats_total{action="check",goldpinger_instance="...",group="made"}
goldpinger_kube_master_response_time_s_bucket
```

`goldpinger_errors_total` appears only after the first error.

```yaml
- alert: GoldpingerPeerUnreachable
  expr: |
    sum(rate(goldpinger_errors_total{type="ping"}[5m])) by (goldpinger_instance) > 0
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "{{ $labels.goldpinger_instance }} cannot reach some of its peers"

- alert: GoldpingerHighLatency
  expr: |
    histogram_quantile(0.99, sum(rate(goldpinger_peers_response_time_s_bucket{call_type="ping"}[5m])) by (le)) > 1
  for: 10m
  labels:
    severity: warning
```

> [!warning] Correction
> An earlier version of this page filtered `.hosts[]` on `OK` (that list has no `OK`
> field, so the filter never found anything) and used a `goldpinger_nodes_health_total`
> metric and `status_code`/`host` labels that goldpinger 3.11 does not export. The
> filter, the metric list and the first alert were rewritten from the real output.

See [[kubernetes/observability/prometheus]].

> [!tip] The latency histogram catches the problem before it becomes an outage
> An MTU mismatch or a saturated inter-node link usually shows first as rising
> pod-to-pod latency, long before anything fails outright. Alerting on the p99 across
> the mesh gives warning that connectivity is degrading, which the binary
> reachable/unreachable check does not.

## What it will not tell you

Being clear about scope:

- **It tests pod-to-pod on the cluster network only.** Not Services, not DNS, not
  Ingress, not egress. A working goldpinger mesh with broken Services means the
  problem is `kube-proxy` or the Service configuration, not the CNI — which is itself
  useful narrowing.
- **It does not test bandwidth**, only reachability and latency.
- **It cannot see NetworkPolicy** as a distinct cause. A policy blocking its traffic
  looks exactly like a network failure, so exempt it explicitly:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-goldpinger
  namespace: goldpinger
spec:
  podSelector:
    matchLabels:
      app: goldpinger
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: goldpinger
```

Otherwise a default-deny namespace produces a fully red graph and a very confusing
half hour. See [[kubernetes/networking/netpol]].

## When to reach for it

- Commissioning a cluster, to prove the network works before workloads arrive.
- Intermittent, unexplained timeouts between services.
- After a CNI change, an upgrade, or adding nodes in a new subnet or availability
  zone.
- Permanently, on any cluster spanning racks, zones or sites — where partial failure
  is most likely and least visible.

The cost is trivial: 10 millicores and 32 MiB per node.

## Where to go next

- [[kubernetes/networking/kubenet]] — how the pod network is meant to work
- [[kubernetes/networking/netpol]] — the policy that can confuse the results
- [[kubernetes/observability/prometheus]] — alerting on the metrics
- [[containers/containerd/troubleshooting]] — when the problem is below Kubernetes

<!-- uplink -->
Part of [[kubernetes/observability/index|Observability and scaling]].
