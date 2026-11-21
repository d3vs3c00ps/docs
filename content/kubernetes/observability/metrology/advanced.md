---
title: Kubernetes metrology in depth
description: ServiceMonitor, PodMonitor and PrometheusRule for your own app, the key container, API server and etcd metrics, chart values for retention and storage, and scraping the control plane on kind and kubeadm
tags: [kubernetes, observability, monitoring, prometheus, promql]
type: reference
status: complete
---

# Kubernetes metrology in depth

This note starts where [[kubernetes/observability/metrology/quickstart]] stops: a
cluster with metrics-server and the `kube-prometheus-stack` chart (release
`kube-prometheus-stack`, namespace `monitoring`, chart 92.18.0). It covers:

- how to make Prometheus scrape your own application;
- recording rules and alerts;
- the metrics and queries that matter for a cluster;
- the chart values for retention, storage and scrape interval;
- how to scrape the control plane on kind and kubeadm.

For PromQL basics, see [[kubernetes/observability/prometheus]] and
[[observability/prometheus/quickstart]]. For requests and limits, see
[[kubernetes/observability/resource-limits]].

The commands that read Prometheus use the API server proxy
(`kubectl get --raw .../services/<name>:<port>/proxy/...`). It needs no port-forward,
so it works in scripts. The port-forward of the quickstart works too.

## Monitor your own application

With the Prometheus Operator, you do not edit `prometheus.yml`. You create a
**ServiceMonitor** (scrape the endpoints behind a Service) or a **PodMonitor** (scrape
pods directly). The operator turns them into scrape configuration and reloads
Prometheus. The `prometheus.io/scrape` annotations do nothing here.

A small application with a `/metrics` endpoint:
[podinfo](https://github.com/stefanprodan/podinfo) (images for amd64 and arm64).

```yaml
# podinfo.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
  labels:
    app: podinfo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: podinfo
  template:
    metadata:
      labels:
        app: podinfo
    spec:
      containers:
        - name: podinfo
          image: ghcr.io/stefanprodan/podinfo:6.17.0
          ports:
            - name: http
              containerPort: 9898
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: podinfo
  labels:
    app: podinfo
spec:
  selector:
    app: podinfo
  ports:
    - name: http
      port: 9898
      targetPort: http
```

```yaml
# podinfo-servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: podinfo
  labels:
    app: podinfo
    release: kube-prometheus-stack   # see "The release label trap" below
spec:
  selector:
    matchLabels:
      app: podinfo          # labels of the Service, not of the pods
  endpoints:
    - port: http            # the NAME of the Service port, not its number
      path: /metrics
      interval: 15s
```

```bash
kubectl apply -f podinfo.yaml -f podinfo-servicemonitor.yaml
```

With no `namespaceSelector`, a ServiceMonitor looks for Services in its own namespace
only. After about a minute (the operator writes the config, then a sidecar reloads
Prometheus), the targets are there:

```bash
kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/targets?state=active' |
  jq -r '.data.activeTargets[] | select(.labels.job == "podinfo") | "\(.scrapePool) \(.labels.pod) \(.health)"'
```

```text
serviceMonitor/demo/podinfo/0 podinfo-dfccd5b4b-pkl5r up
serviceMonitor/demo/podinfo/0 podinfo-dfccd5b4b-pt58x up
```

The operator adds the labels `namespace`, `service`, `pod`, `container` and
`endpoint`, and `job` is the Service name.

### The release label trap

The chart's Prometheus only reads ServiceMonitors, PodMonitors and PrometheusRules that
carry the label `release: <release name>`:

```bash
kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus \
  -o jsonpath='{.spec.serviceMonitorSelector}{"\n"}{.spec.podMonitorSelector}{"\n"}{.spec.ruleSelector}{"\n"}'
```

```text
{"matchLabels":{"release":"kube-prometheus-stack"}}
{"matchLabels":{"release":"kube-prometheus-stack"}}
{"matchLabels":{"release":"kube-prometheus-stack"}}
```

A ServiceMonitor without that label is accepted by the API server, and then ignored.
No error, no event, no target. This is the most common reason for "my app is not
scraped". Two fixes:

- add `release: kube-prometheus-stack` to each ServiceMonitor, PodMonitor and
  PrometheusRule, as above;
- or make the chart's Prometheus select all of them, in the Helm values:

```yaml
prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
```

With these values, the selectors become `{}`: every object in every namespace.

### PodMonitor

Use a PodMonitor when the pods have no Service (a DaemonSet agent, a Job, a sidecar):

```yaml
# podinfo-podmonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: podinfo-pods
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: podinfo          # labels of the pods
  podMetricsEndpoints:
    - port: http            # the name of the container port
      path: /metrics
```

Its targets appear under `podMonitor/<namespace>/podinfo-pods/0`, with `job` set to
`<namespace>/podinfo-pods`. Do not create both for the same pods in real life: each
sample would be stored twice.

## Recording rules and alerts: PrometheusRule

A PrometheusRule holds rule groups, like a Prometheus rule file. The same `release`
label applies.

```yaml
# podinfo-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: podinfo
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: podinfo
      rules:
        - record: namespace_job:http_requests:rate5m
          expr: sum by (namespace, job) (rate(http_requests_total{job="podinfo"}[5m]))
        - alert: PodinfoDown
          expr: absent(up{job="podinfo"} == 1)
          for: 1m
          labels:
            severity: warning
          annotations:
            summary: No podinfo target is up
```

```bash
kubectl apply -f podinfo-rules.yaml
```

- A **recording rule** stores the result of a query as a new series. Use it for
  queries that dashboards run often. The name follows `level:metric:operations`.
- An **alert** is *pending* while its expression returns something, and *firing* once
  it has returned something for the whole `for:` duration.
- `absent(up{job="podinfo"} == 1)` fires when no podinfo target is up, including
  when all pods are gone. `up{job="podinfo"} == 0` does not: with no pod, there is no
  `up` series at all. See [[kubernetes/observability/metrology/troubleshooting#An alert never fires]].

The chart installs an admission webhook that checks the PromQL. A broken rule is
refused at `kubectl apply`, not later in the Prometheus logs:

```text
The  "prometheusrules" is invalid: : 5:11: group "podinfo", rule 2, "PodinfoDown": could not parse expression: 1:30: parse error: unclosed left parenthesis
```

Check what Prometheus loaded:

```bash
kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/rules' |
  jq -r '.data.groups[] | select(.name == "podinfo") | .rules[] | "\(.type) \(.name) \(.health) \(.state // "")"'
```

```text
recording namespace_job:http_requests:rate5m ok
alerting PodinfoDown ok inactive
```

## Key metrics and queries

Two test pods make the numbers move: one burns CPU above its limit, one goes over its
memory limit.

```yaml
# hogs.yaml
apiVersion: v1
kind: Pod
metadata:
  name: cpu-hog
spec:
  containers:
    - name: hog
      image: busybox:1.37
      command: ["sh", "-c", "while true; do :; done"]
      resources:
        requests:
          cpu: 50m
        limits:
          cpu: 100m
---
apiVersion: v1
kind: Pod
metadata:
  name: mem-hog
spec:
  containers:
    - name: hog
      image: busybox:1.37
      command: ["sh", "-c", "tail /dev/zero"]   # reads forever, keeps it all in memory
      resources:
        limits:
          memory: 32Mi
```

```bash
kubectl apply -f hogs.yaml
```

### CPU usage

`container_cpu_usage_seconds_total` (from cAdvisor, in the kubelet) counts CPU seconds.
Its rate is in cores:

```promql
sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))
```

Always filter `container!=""`. cAdvisor also exports one series per pod cgroup (with
`container=""`) that already holds the sum of its containers.

### Memory: working set, not usage

```promql
sum by (namespace, pod) (container_memory_working_set_bytes{container!=""})
```

`container_memory_usage_bytes` includes the page cache: files the container read or
wrote, which the kernel can drop at any time. It is always at least as big as the
working set, and on a container that does file I/O it climbs to the limit and stays
there, without any problem. `container_memory_working_set_bytes` is usage minus the
inactive file cache. That is what the kubelet uses for evictions, what `kubectl top`
shows, and the best signal for an OOM kill to come. Compare it with the limit:

```promql
sum by (namespace, pod, container) (container_memory_working_set_bytes{container!=""})
  / on (namespace, pod, container)
  sum by (namespace, pod, container) (kube_pod_container_resource_limits{resource="memory"})
```

### CPU throttling

A container with a CPU limit gets a quota per period of 100 ms (the CFS bandwidth
control of the kernel). When it uses its quota before the end of the period, it waits:
it is *throttled*. Latency goes up, even when average CPU usage looks low. The share of
periods in which a container was throttled:

```promql
sum by (namespace, pod, container) (increase(container_cpu_cfs_throttled_periods_total{container!=""}[5m]))
  / sum by (namespace, pod, container) (increase(container_cpu_cfs_periods_total{container!=""}[5m]))
```

`cpu-hog` shows about `1`: throttled in every period. These series exist only for
containers with a CPU limit. Many teams set no CPU limit for this reason, and keep a
CPU request.

### Requests compared with usage

kube-state-metrics exports what each container *asked for*:
`kube_pod_container_resource_requests` and `kube_pod_container_resource_limits`, with
a `resource` label (`cpu`, `memory`). Usage divided by requests, per namespace:

```promql
sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))
  / sum by (namespace) (kube_pod_container_resource_requests{resource="cpu"})
```

```promql
sum by (namespace) (container_memory_working_set_bytes{container!=""})
  / sum by (namespace) (kube_pod_container_resource_requests{resource="memory"})
```

Far below 1: the namespace reserves capacity it does not use, and the scheduler cannot
give it to others. Above 1: pods use more than they asked for, and are the first to
suffer when the node is full. The scheduler places pods by requests, never by usage.

### OOMKilled containers

```promql
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
```

The series exists while the last termination of the container was an OOM kill. Pair it
with restarts to see repeated kills:

```promql
sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[1h]))
  and on (namespace, pod) (kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1)
```

### API server latency and errors

The 99th percentile of request duration, per verb. Leave out `WATCH` and `CONNECT`:
they are long-lived on purpose.

```promql
histogram_quantile(0.99,
  sum by (le, verb) (rate(apiserver_request_duration_seconds_bucket{job="apiserver", verb!~"WATCH|CONNECT"}[5m])))
```

The share of requests that end in a 5xx error:

```promql
sum(rate(apiserver_request_total{job="apiserver", code=~"5.."}[5m]))
  / sum(rate(apiserver_request_total{job="apiserver"}[5m]))
```

`sum by (code, verb, resource)` on `apiserver_request_total` shows who sends what. Many
`429` mean API Priority and Fairness is rejecting requests.

### etcd basics

The API server measures its own calls to etcd, so this works even when etcd itself is
not scraped:

```promql
histogram_quantile(0.99, sum by (le, operation) (rate(etcd_request_duration_seconds_bucket{job="apiserver"}[5m])))
```

```promql
apiserver_storage_size_bytes
```

When etcd is scraped (see [[#Scrape the control plane on kind and kubeadm]]), watch:

| Query | Healthy |
| --- | --- |
| `etcd_server_has_leader` | `1` on every member |
| `increase(etcd_server_leader_changes_seen_total[1h])` | `0` or close to it |
| `histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))` | under 10 ms; etcd needs fast disks |
| `histogram_quantile(0.99, rate(etcd_disk_backend_commit_duration_seconds_bucket[5m]))` | under 25 ms |
| `etcd_mvcc_db_total_size_in_bytes` | well under the quota (2 GiB by default) |

### Recording rules from the chart

The chart already records the common aggregations. They are cheaper to query than the
raw series, and the Grafana dashboards use them:

| Recording rule | Holds |
| --- | --- |
| `node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m` | CPU cores per container |
| `node_namespace_pod_container:container_memory_working_set_bytes` | working set per container |
| `namespace_cpu:kube_pod_container_resource_requests:sum` | CPU requests per namespace |
| `namespace_memory:kube_pod_container_resource_requests:sum` | memory requests per namespace |

## Tune the chart with Helm values

The defaults suit a demo: data in an `emptyDir`, 10 days of retention, no resource
requests. A values file for a small real cluster:

```yaml
# kps-values.yaml
prometheus:
  prometheusSpec:
    scrapeInterval: 30s        # the default; 15s doubles the samples and the memory
    evaluationInterval: 30s
    retention: 15d             # delete data older than this...
    retentionSize: 9GB         # ...or when the blocks pass this size; keep it below the volume
    resources:
      requests:
        cpu: 200m
        memory: 1Gi
      limits:
        memory: 2Gi
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 10Gi
alertmanager:
  alertmanagerSpec:
    retention: 120h
    resources:
      requests:
        cpu: 10m
        memory: 64Mi
grafana:
  resources:
    requests:
      cpu: 50m
      memory: 256Mi
```

```bash
helm upgrade --install kube-prometheus-stack kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts --version 92.18.0 \
  --namespace monitoring --create-namespace \
  -f kps-values.yaml --wait --timeout 10m
kubectl -n monitoring wait --for=condition=Available \
  prometheus/kube-prometheus-stack-prometheus --timeout=5m
```

Check what Prometheus really runs with:

```bash
kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/status/runtimeinfo' |
  jq '.data | {storageRetention}'
kubectl -n monitoring get pvc
```

```text
{
  "storageRetention": "15d or 9GiB"
}
```

Memory is the resource that matters. Prometheus needs about a few KiB per active
series, plus room for queries. Measure before you set the limit: see
[[kubernetes/observability/metrology/troubleshooting#Prometheus is OOMKilled or slow]].

Prometheus also scrapes less when you remove what you do not use. Every ServiceMonitor
of the chart has an `enabled` switch, and every scrape can drop series with
`metricRelabelings`.

## Scrape the control plane on kind and kubeadm

Right after the install, four jobs are down on kind and on any kubeadm cluster:

| Job | Port | Why it is down |
| --- | --- | --- |
| `kube-controller-manager` | 10257 (HTTPS) | kubeadm sets `--bind-address=127.0.0.1` |
| `kube-scheduler` | 10259 (HTTPS) | kubeadm sets `--bind-address=127.0.0.1` |
| `kube-etcd` | 2381 (HTTP) | kubeadm sets `--listen-metrics-urls=http://127.0.0.1:2381` |
| `kube-proxy` | 10249 (HTTP) | `metricsBindAddress` is empty, so `127.0.0.1:10249` |

Prometheus connects to the node IP, so it gets `connection refused`. The fix is to
listen on all addresses.

> [!warning] What this opens
> The controller manager and the scheduler check a token on `/metrics`, so the chart's
> Prometheus can read them and an anonymous client cannot. The etcd metrics port and
> the kube-proxy metrics port are plain HTTP with no authentication. They expose
> metrics only (not the etcd API), but block them from outside the cluster network.

### A new kind cluster

Set it at creation, with `kubeadmConfigPatches` (kubeadm `v1beta4`: `extraArgs` is a
list of `name`/`value`):

```yaml
# kind-metrics.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    controllerManager:
      extraArgs:
        - name: bind-address
          value: 0.0.0.0
    scheduler:
      extraArgs:
        - name: bind-address
          value: 0.0.0.0
    etcd:
      local:
        extraArgs:
          - name: listen-metrics-urls
            value: http://0.0.0.0:2381
  - |
    kind: KubeProxyConfiguration
    metricsBindAddress: 0.0.0.0:10249
nodes:
  - role: control-plane
  - role: worker
```

```bash
kind create cluster --name metrics --config kind-metrics.yaml
```

On a new kubeadm cluster, put the same `ClusterConfiguration` and
`KubeProxyConfiguration` in the file you pass to `kubeadm init --config`.

### An existing kind or kubeadm cluster

Start with kube-proxy. It reads its configuration from a ConfigMap; the new pods of
the restart read the new value:

```bash
kubectl -n kube-system get configmap kube-proxy -o yaml |
  sed 's/metricsBindAddress: ""/metricsBindAddress: 0.0.0.0:10249/' |
  kubectl replace -f -
kubectl -n kube-system rollout restart daemonset kube-proxy
kubectl -n kube-system rollout status daemonset kube-proxy
```

The rest of the control plane runs as static pods (see
[[kubernetes/cluster-setup/staticpods]]). Edit their manifests on each control-plane
node; the kubelet restarts the pod. On kind, a node is a container, so `docker exec`
does it. On kubeadm, run the same `sed` commands with `sudo` on each control-plane
node.

```bash
NODE=kind-control-plane
docker exec "$NODE" sed -i 's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/' \
  /etc/kubernetes/manifests/kube-controller-manager.yaml \
  /etc/kubernetes/manifests/kube-scheduler.yaml
docker exec "$NODE" sed -i 's|--listen-metrics-urls=http://127.0.0.1:2381|--listen-metrics-urls=http://0.0.0.0:2381|' \
  /etc/kubernetes/manifests/etcd.yaml
# Wait for the new etcd (it listens on all addresses), then for the API server
docker exec "$NODE" sh -c "until ss -ltn | grep -Eq '(\*|0\.0\.0\.0):2381 '; do sleep 2; done"
until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 2; done
```

etcd restarts, so the API server is unavailable for up to a minute. Change the
static pods last, and wait as above before you run other `kubectl` commands: during
the restart, requests fail or time out.

Within a minute, the four jobs are up:

```bash
kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/targets?state=active' |
  jq -r '.data.activeTargets[] | select(.labels.job | test("kube-(controller-manager|scheduler|etcd|proxy)")) | "\(.labels.job) \(.health)"' |
  sort | uniq -c
```

```text
      1 kube-controller-manager up
      1 kube-etcd up
      3 kube-proxy up
      1 kube-scheduler up
```

> [!warning] kubeadm upgrade rewrites the manifests
> `kubeadm upgrade` generates the static pod manifests again from the
> `ClusterConfiguration` stored in the `kubeadm-config` ConfigMap. Hand edits are
> lost. Put the same `extraArgs` in that ConfigMap
> (`kubectl -n kube-system edit configmap kubeadm-config`) so the next upgrade keeps
> them.

On a managed cluster (EKS, GKE, AKS), you cannot reach the control plane. Turn those
jobs off instead, see
[[kubernetes/observability/metrology/troubleshooting#Control-plane targets are down]].

<!-- uplink -->
Part of [[kubernetes/observability/metrology/index|Kubernetes metrology]].
