---
title: Troubleshooting Kubernetes metrology
description: Fixes for kubectl top errors, control-plane targets down on kubeadm and kind, ServiceMonitors that are ignored, CRDs too big for kubectl apply, Prometheus OOM and cardinality, full volumes, Grafana "No data" and alerts that never fire
tags: [kubernetes, observability, monitoring, prometheus, troubleshooting]
type: reference
status: complete
---

# Troubleshooting Kubernetes metrology

Symptoms and fixes for the setup of [[kubernetes/observability/metrology/quickstart]]:
metrics-server, and the `kube-prometheus-stack` chart 92.18.0 (release
`kube-prometheus-stack`, namespace `monitoring`). Each section starts with what you
see.

Most commands read Prometheus through the API server proxy, so they need no
port-forward. Define this once:

```bash
PROM=/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:http-web/proxy
```

## `kubectl top` fails

### error: Metrics API not available

`kubectl top` reads the `metrics.k8s.io` API, which metrics-server serves through the
API server. Look at the APIService first:

```bash
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl -n kube-system get pods -l app.kubernetes.io/name=metrics-server
kubectl -n kube-system logs deploy/metrics-server --tail=20
```

| `kubectl get apiservice` says | Meaning | Fix |
| --- | --- | --- |
| `NotFound` | metrics-server is not installed | install it, see [[kubernetes/observability/metrology/quickstart#Install metrics-server]] |
| `False (MissingEndpoints)` | the metrics-server pod is not ready, often because it cannot scrape any kubelet | read its logs (next section) |
| `False (FailedDiscoveryCheck)` | the API server cannot reach the pod. Right after an install, this lasts a few seconds | if it stays, check NetworkPolicies and firewalls between the control plane and the pod (port 10250) |
| `True` | the API works | wait: the first numbers need one or two scrapes (15 s each) |

### metrics-server cannot read the kubelets

In the metrics-server logs:

```text
"Failed to scrape node" err="Get \"https://172.19.0.3:10250/metrics/resource\": tls: failed to verify certificate: x509: cannot validate certificate for 172.19.0.3 because it doesn't contain any IP SANs"
```

The kubelet serving certificate is self-signed and holds only the node name, as on
kind and on a default kubeadm cluster. On a test cluster, add
`--kubelet-insecure-tls`. On a real cluster, use `serverTLSBootstrap: true` on the
kubelets and approve their certificates. Both are explained in
[[kubernetes/observability/metrology/quickstart#Kubelet certificates on kind]].

### A new pod has no metrics yet

```text
Error from server (NotFound): podmetrics.metrics.k8s.io "demo/fresh" not found
```

The pod started after the last scrape. Wait 30 seconds and try again.

## Control-plane targets are down

**Status → Target health** shows `kube-controller-manager`, `kube-scheduler`,
`kube-etcd` and `kube-proxy` down, with `connection refused`:

```bash
kubectl get --raw "$PROM/api/v1/targets?state=active" |
  jq -r '.data.activeTargets[] | select(.health != "up") | "\(.labels.job) \(.scrapeUrl) \(.lastError)"'
```

```text
kube-controller-manager https://172.19.0.2:10257/metrics Get "https://172.19.0.2:10257/metrics": dial tcp 172.19.0.2:10257: connect: connection refused
```

On kind and kubeadm, these components listen on `127.0.0.1` only:

```bash
kubectl -n kube-system get pod -l component=kube-scheduler -o yaml | grep -- --bind-address
```

```text
    - --bind-address=127.0.0.1
```

On a cluster you run, make them listen on all addresses:
[[kubernetes/observability/metrology/advanced#Scrape the control plane on kind and kubeadm]].

On a managed cluster (EKS, GKE, AKS), you cannot reach them. Turn the jobs off in the
Helm values, so they stop showing as down. Do the same for kube-proxy when your
network plugin replaces it (Cilium in kube-proxy-free mode, for example):

```yaml
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false
kubeProxy:
  enabled: false
```

## A ServiceMonitor is not picked up

The ServiceMonitor exists, but no target appears, and no error says why. Check these
points in order.

**1. Is it in the Prometheus configuration?** The operator writes one scrape job per
endpoint of each ServiceMonitor it selected, named
`serviceMonitor/<namespace>/<name>/<index>`:

```bash
kubectl get --raw "$PROM/api/v1/status/config" | jq -r .data.yaml | grep 'job_name: serviceMonitor/'
```

Not there: the operator did not select it (points 2 and 3). There, but no target:
the ServiceMonitor does not match a Service with endpoints (points 4 to 6).

**2. The `release` label.** The chart's Prometheus selects only objects with
`release: kube-prometheus-stack`:

```bash
kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus -o jsonpath='{.spec.serviceMonitorSelector}{"\n"}'
kubectl get servicemonitors --all-namespaces -L release
```

Add the label, or change the selector: see
[[kubernetes/observability/metrology/advanced#The release label trap]].

**3. Namespaces.** Two selectors play here. The Prometheus side,
`prometheus.prometheusSpec.serviceMonitorNamespaceSelector`, is empty in the chart,
so every namespace counts. The ServiceMonitor side, `spec.namespaceSelector`, is empty
by default too, but there it means *its own namespace only*. A ServiceMonitor in
`monitoring` that targets a Service in `demo` needs:

```yaml
spec:
  namespaceSelector:
    matchNames: [demo]
```

**4. The selector matches the Service labels**, not the pod labels:

```bash
kubectl get services --all-namespaces -l app=podinfo
```

**5. `port` is the name of a Service port**, not a number. With `port: "9898"`, the
job is in the configuration but has no target, because no Service port is *named*
`9898`. Use `targetPort: 9898` (the container port) if the Service port has no name.

**6. The Service has ready endpoints.** No ready pod, no target:

```bash
kubectl get endpointslices --all-namespaces -l kubernetes.io/service-name=podinfo
```

**7. RBAC.** Prometheus lists Services, EndpointSlices and Pods in the namespaces it
watches. The chart gives it a ClusterRole for that. With your own, narrower RBAC,
targets in a namespace it may not read stay missing, and the Prometheus logs show
`forbidden`. Check as the Prometheus ServiceAccount:

```bash
kubectl auth can-i list endpointslices.discovery.k8s.io -n demo \
  --as=system:serviceaccount:monitoring:kube-prometheus-stack-prometheus
```

## CRDs are missing or too big

### no matches for kind "ServiceMonitor"

```text
error: resource mapping not found for name: "podinfo" namespace: "" from "podinfo-servicemonitor.yaml": no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"
ensure CRDs are installed first
```

The Prometheus Operator CRDs are not installed: install the chart first, or install
only the CRDs (next block). A Helm chart of your application that ships a
ServiceMonitor fails the same way on a cluster without the operator. Many charts have
a `serviceMonitor.enabled` value for that reason.

### metadata.annotations: Too long

The CRDs are big (`prometheuses.monitoring.coreos.com` alone is about 840 KiB).
A client-side `kubectl apply` stores a copy of the object in the
`kubectl.kubernetes.io/last-applied-configuration` annotation, which is limited to
256 KiB:

```text
for: "crds.yaml": error when patching "crds.yaml": CustomResourceDefinition.apiextensions.k8s.io "prometheuses.monitoring.coreos.com" is invalid: metadata.annotations: Too long: may not be more than 262144 bytes
```

Use server-side apply, which keeps no such annotation. Helm installs the CRDs but
never upgrades them, so this is also how you upgrade them before a chart upgrade:

```bash
helm show crds kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts --version 92.18.0 |
  kubectl apply --server-side --force-conflicts -f -
```

`--force-conflicts` takes over the fields that Helm wrote at install. GitOps tools need
the same: in Argo CD, sync these CRDs with `ServerSideApply=true`.

## Prometheus is OOMKilled or slow

The pod restarts, queries time out, or the UI is slow:

```bash
kubectl -n monitoring get pod prometheus-kube-prometheus-stack-prometheus-0 \
  -o jsonpath='{.status.containerStatuses[?(@.name=="prometheus")].lastState.terminated.reason}{"\n"}'
```

```text
OOMKilled
```

Prometheus memory grows with the number of active series (*cardinality*): each
unique set of labels is one series. One label with unbounded values (a user ID, a
request ID, a full URL) can create millions. Find the culprits with the TSDB status
API:

```bash
kubectl get --raw "$PROM/api/v1/status/tsdb" |
  jq '{series: .data.headStats.numSeries, top_metrics: .data.seriesCountByMetricName[:5], top_labels: .data.labelValueCountByLabelName[:5]}'
```

Or with PromQL (an expensive query: run it once, not in a dashboard):

```promql
topk(10, count by (__name__) ({__name__=~".+"}))
```

And watch Prometheus itself:

```promql
prometheus_tsdb_head_series
```

```promql
process_resident_memory_bytes{job="kube-prometheus-stack-prometheus"}
```

Fixes, from the cheapest:

- **Drop what you do not use**, at scrape time, with `metricRelabelings` on the
  ServiceMonitor. Dropped series get no new samples once Prometheus has reloaded its
  configuration (about a minute). Their last samples stay visible in queries for up
  to 5 minutes. Their memory is freed later, when Prometheus compacts its in-memory
  head block (every two hours or so):

  ```yaml
  endpoints:
    - port: http
      metricRelabelings:
        - sourceLabels: [__name__]
          regex: http_request_duration_seconds_bucket
          action: drop
  ```

- **Cap a target** with `sampleLimit` on the ServiceMonitor: a scrape with more
  samples fails, and the target shows as down, instead of filling the memory.
- **Give it more memory**: `prometheus.prometheusSpec.resources` (see
  [[kubernetes/observability/metrology/advanced#Tune the chart with Helm values]]).
  A shorter retention saves disk, not much memory: memory goes to the recent data.

## The Prometheus volume is full

Prometheus stops writing, crash-loops, and logs `no space left on device`. Check how
much the blocks use:

```promql
prometheus_tsdb_storage_blocks_bytes
```

The kubelet exports the use of each PVC, which the **Kubernetes / Persistent Volumes**
dashboard and the `KubePersistentVolumeFillingUp` alert use:

```promql
kubelet_volume_stats_available_bytes{persistentvolumeclaim=~"prometheus-.*"}
```

On kind, this returns nothing: the `local-path` volumes are plain host folders, and
the kubelet has no statistics for them. On a CSI volume it works.

Fixes:

- set `retentionSize` below the volume size, so Prometheus deletes old blocks before
  the disk is full (10 to 20 % margin for the WAL and compaction);
- grow the PVC, if its StorageClass has `allowVolumeExpansion: true` (kind's
  `standard` class does not);
- reduce the number of series (previous section).

## Grafana shows "No data"

Work from Prometheus to Grafana:

1. **Run the query in Prometheus.** No result there: it is a scrape or PromQL
   problem, not Grafana.
2. **Check the data source.** With the Grafana port-forward and password of the
   quickstart:

   ```bash
   curl -s -u "admin:$GRAFANA_PASSWORD" localhost:3000/api/datasources/uid/prometheus/health | jq .
   ```

   ```text
   {
     "details": {
       "application": "Prometheus",
       "features": {
         "rulerApiEnabled": false
       }
     },
     "message": "Successfully queried the Prometheus API.",
     "status": "OK"
   }
   ```

3. **Run the query through Grafana**, with the data source proxy:

   ```bash
   curl -s -u "admin:$GRAFANA_PASSWORD" \
     'localhost:3000/api/datasources/proxy/uid/prometheus/api/v1/query?query=up' | jq '.data.result | length'
   ```

4. **Check the panel**: the time range (data older than the retention is gone), the
   dashboard variables at the top (an empty `namespace` or `cluster` variable
   selects nothing), and the rate window. `rate(x[1m])` with a 30 s scrape interval
   has too few samples: use `$__rate_interval`.

## An alert never fires

Look at the alert in Prometheus first:

```bash
kubectl get --raw "$PROM/api/v1/rules?type=alert" |
  jq -r '.data.groups[].rules[] | select(.name | test("^Podinfo")) | "\(.name) \(.state) \(.health)"'
```

| You see | Cause | Fix |
| --- | --- | --- |
| nothing | the rule is not loaded | the `release` label on the PrometheusRule, as for ServiceMonitors |
| `inactive` | the expression returns no series | run it in Prometheus; see `absent()` below |
| `pending` | the expression is true, for less than `for:` | wait, or shorten `for:` |
| `firing`, but no notification | Alertmanager does not send it anywhere | see below |

**`up == 0` does not fire when the target is gone.** When all pods of a job are
deleted, the `up` series disappears; it does not become 0. An expression that
compares a missing series returns nothing. Use `absent()`:

```yaml
- alert: PodinfoDown
  expr: absent(up{job="podinfo"} == 1)
  for: 1m
```

**`for:` delays the alert.** The alert stays `pending` until the expression has been
true at every evaluation for the whole duration (evaluations run every 30 s by
default). A short outage never reaches `firing`, which is the point.

**Alertmanager sends nothing by default.** The chart's Alertmanager configuration routes
every alert to a receiver named `null`, which has no destination:

```bash
kubectl -n monitoring get secret alertmanager-kube-prometheus-stack-alertmanager \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d
```

Configure receivers (email, Slack, PagerDuty, a webhook) in `alertmanager.config`, or
with `AlertmanagerConfig` objects. The chart's `Watchdog` alert always fires, on
purpose: it proves the whole pipeline works. If an external system stops receiving
it, alerting is broken.

## Useful commands

```bash
# Targets that are not up, with the error
kubectl get --raw "$PROM/api/v1/targets?state=active" |
  jq -r '.data.activeTargets[] | select(.health != "up") | "\(.labels.job) \(.lastError)"'

# Scrape jobs generated from ServiceMonitors and PodMonitors
kubectl get --raw "$PROM/api/v1/status/config" | jq -r .data.yaml | grep -E 'job_name: (serviceMonitor|podMonitor)/'

# Rules with errors
kubectl get --raw "$PROM/api/v1/rules" | jq -r '.data.groups[].rules[] | select(.health != "ok") | "\(.name) \(.lastError)"'

# Alerts that are pending or firing
kubectl get --raw "$PROM/api/v1/alerts" | jq -r '.data.alerts[] | "\(.labels.alertname) \(.state)"'

# Alerts that reached Alertmanager
kubectl get --raw /api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:http-web/proxy/api/v2/alerts |
  jq -r '.[].labels.alertname' | sort | uniq -c

# Retention, series count, storage
kubectl get --raw "$PROM/api/v1/status/runtimeinfo" | jq '.data | {storageRetention, reloadConfigSuccess}'
kubectl get --raw "$PROM/api/v1/status/tsdb" | jq .data.headStats

# Operator and Prometheus logs
kubectl -n monitoring logs deploy/kube-prometheus-stack-operator --tail=50
kubectl -n monitoring logs prometheus-kube-prometheus-stack-prometheus-0 -c prometheus --tail=50
```

<!-- uplink -->
Part of [[kubernetes/observability/metrology/index|Kubernetes metrology]].
