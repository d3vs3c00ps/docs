---
title: Kubernetes metrology quickstart
description: Measure a Kubernetes cluster in minutes — metrics-server and kubectl top, then kube-prometheus-stack with Prometheus, Grafana and the first PromQL queries
tags: [kubernetes, observability, monitoring, prometheus, grafana, metrics-server]
type: howto
status: complete
---

# Kubernetes metrology quickstart

*Metrology* is the science of measurement. For a cluster, it means: know how much CPU
and memory each node and pod uses, know the state of every object, and keep a history
so you can see trends.

This note installs the two usual tools on a [[kubernetes/cluster-setup/kind-in-practice|kind]]
cluster, step by step. [[kubernetes/observability/metrology/advanced]] covers your own
applications, alerts and the key queries.
[[kubernetes/observability/metrology/troubleshooting]] covers what breaks.

Background notes:
[[kubernetes/observability/metrics-server]], [[kubernetes/observability/prometheus]],
[[kubernetes/observability/prometheus-stack]]. Prometheus and Grafana outside
Kubernetes: [[observability/prometheus/quickstart]], [[observability/grafana/quickstart]].

Tested with Kubernetes 1.37 (kind), Helm 4.3, the `metrics-server` chart 3.14.0
(metrics-server 0.9.0) and the `kube-prometheus-stack` chart 92.18.0 (Prometheus
3.15, Grafana 13.3, Prometheus Operator 0.94).

## Three layers of metrics

| Layer | Component | What it measures | Who uses it |
| --- | --- | --- | --- |
| Resource metrics | **metrics-server** | CPU and memory of nodes and pods, now. No history | `kubectl top`, the Horizontal Pod Autoscaler, the Vertical Pod Autoscaler |
| Object state | **kube-state-metrics** | The state of API objects: pod phase, restarts, readiness, requests and limits, replicas | Prometheus |
| Machines and containers | **node-exporter** (one pod per node) and **cAdvisor** (built into the kubelet) | Node CPU, memory, disk, network; CPU, memory and throttling per container | Prometheus |

metrics-server is small and has no storage. It answers "how much now?". The other
layers feed Prometheus, which stores a history and answers "how much, when, and how
did it change?". You usually want both: the autoscalers need metrics-server, and
Prometheus does not replace it (see [[kubernetes/observability/hpa-v2]]).

## Install metrics-server

Install the chart from its own repository, with a pinned version:

```bash
helm upgrade --install metrics-server metrics-server \
  --repo https://kubernetes-sigs.github.io/metrics-server/ --version 3.14.0 \
  --namespace kube-system \
  --set 'args={--kubelet-insecure-tls}' \
  --wait --timeout 5m
```

### Kubelet certificates on kind

metrics-server reads the metrics of each node from the kubelet, over HTTPS, on port
10250. It connects to the node **IP address**. On kind (and on a default kubeadm
cluster), each kubelet uses a self-signed serving certificate. That certificate is
signed by a small CA of its own, not by the cluster CA, and it holds only the node
**name**:

```bash
docker exec kind-worker openssl x509 -in /var/lib/kubelet/pki/kubelet.crt \
  -noout -issuer -ext subjectAltName
```

```text
issuer=CN=kind-worker-ca@1793883176
X509v3 Subject Alternative Name:
    DNS:kind-worker
```

So without the flag, metrics-server refuses every kubelet, and its logs say:

```text
"Failed to scrape node" err="Get \"https://172.19.0.3:10250/metrics/resource\": tls: failed to verify certificate: x509: cannot validate certificate for 172.19.0.3 because it doesn't contain any IP SANs"
```

`--kubelet-insecure-tls` skips the check of the kubelet certificate. This is fine on
a local test cluster. On a real cluster, fix the certificates instead: set
`serverTLSBootstrap: true` in the kubelet configuration, so each kubelet asks the
cluster CA for a certificate with its IP, and approve those certificate requests (by
hand with `kubectl certificate approve`, or with an approver such as
kubelet-csr-approver). GKE and AKS install metrics-server for you; on EKS it is an add-on.

## Use `kubectl top`

The rollout is ready before the API is. Wait until the API server says the Metrics
API is available (this takes 15 to 60 seconds):

```bash
kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=120s
```

Then:

```bash
kubectl top nodes
kubectl top pods --all-namespaces --sort-by=memory
```

```text
NAME                 CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
kind-control-plane   114m         1%       755Mi           4%
kind-worker          15m          0%       154Mi           0%
kind-worker2         27m          0%       193Mi           1%
```

`kubectl top` reads the Metrics API. This API is not part of the API server: the API
server forwards `metrics.k8s.io` requests to metrics-server (the *aggregation layer*).
You can read it directly:

```bash
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes | jq '.items[] | {name: .metadata.name, usage}'
kubectl get --raw "/apis/metrics.k8s.io/v1beta1/namespaces/kube-system/pods" | jq -r '.items[].metadata.name'
```

CPU is in nanocores (`113315576n` is 113m) and memory in KiB. The memory value is the
*working set*, the same number the kubelet uses to decide evictions.

## Install kube-prometheus-stack

[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
installs, in one release:

- the Prometheus Operator and its CustomResourceDefinitions (CRDs): `Prometheus`,
  `ServiceMonitor`, `PodMonitor`, `PrometheusRule`, `Alertmanager`...;
- one Prometheus and one Alertmanager, run by the operator;
- kube-state-metrics and node-exporter (a DaemonSet);
- ServiceMonitors for the kubelet (with cAdvisor), the API server, CoreDNS and the
  control plane;
- Grafana, with a Prometheus data source and about 30 dashboards;
- recording rules and alerts from the
  [kubernetes-mixin](https://github.com/kubernetes-monitoring/kubernetes-mixin) project.

```bash
helm upgrade --install kube-prometheus-stack kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts --version 92.18.0 \
  --namespace monitoring --create-namespace \
  --wait --timeout 10m
kubectl -n monitoring wait --for=condition=Available \
  prometheus/kube-prometheus-stack-prometheus --timeout=5m
```

`--wait` waits for the objects of the chart. The Prometheus pod is not one of them: the
operator creates it after Helm is done, from the `Prometheus` object. So the second
command waits for it. It all takes one or two minutes on kind. Then:

```bash
kubectl -n monitoring get pods
```

```text
NAME                                                        READY   STATUS    RESTARTS   AGE
alertmanager-kube-prometheus-stack-alertmanager-0           2/2     Running   0          70s
kube-prometheus-stack-grafana-fcdf8cc56-d6jr6               3/3     Running   0          78s
kube-prometheus-stack-kube-state-metrics-645c589fb6-f8wfc   1/1     Running   0          78s
kube-prometheus-stack-operator-7cdc8864dd-rtbl7             1/1     Running   0          78s
kube-prometheus-stack-prometheus-node-exporter-82hjg        1/1     Running   0          78s
kube-prometheus-stack-prometheus-node-exporter-jq77g        1/1     Running   0          78s
kube-prometheus-stack-prometheus-node-exporter-jrtjm        1/1     Running   0          78s
prometheus-kube-prometheus-stack-prometheus-0               2/2     Running   0          70s
```

Name the release `kube-prometheus-stack`, like the chart. With another name, every
object gets a longer name (`kps-kube-prometheus-stack-prometheus`), and the label that
selects ServiceMonitors changes (`release: <release name>`, see
[[kubernetes/observability/metrology/advanced#The release label trap]]).

By default, Prometheus keeps 10 days of data in an `emptyDir` volume: a pod restart
loses it. [[kubernetes/observability/metrology/advanced#Tune the chart with Helm values]]
adds a PersistentVolumeClaim.

## Open Prometheus

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Open <http://localhost:9090>. **Status → Target health** lists everything Prometheus
scrapes. On kind, a few control-plane targets are red: that is expected, see
[[kubernetes/observability/metrology/troubleshooting#Control-plane targets are down]].

The same data is in the HTTP API, useful in scripts:

```bash
curl -s localhost:9090/api/v1/query --data-urlencode 'query=up' |
  jq -r '.data.result[] | "\(.metric.job) \(.metric.instance) \(.value[1])"' | sort
```

## Open Grafana

The chart creates a random admin password and stores it in a Secret:

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

> [!warning] No more `prom-operator`
> Older chart versions set the password to `prom-operator`. Chart 92.18.0 does not
> set it, so Grafana gets a random one, and `admin`/`prom-operator` is refused.
> [[kubernetes/observability/prometheus-stack]] still shows the old one. Set your own
> with `grafana.adminPassword`, or better, `grafana.admin.existingSecret`.

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Open <http://localhost:3000>, log in as `admin`, then **Dashboards**. Good first
dashboards:

| Dashboard | Shows |
| --- | --- |
| Kubernetes / Compute Resources / Cluster | CPU and memory per namespace: usage, requests, limits |
| Kubernetes / Compute Resources / Namespace (Pods) | the same per pod, in one namespace |
| Kubernetes / Compute Resources / Node (Pods) | which pods use a node |
| Node Exporter / Nodes | CPU, memory, disk and network of one node |
| Kubernetes / API server | request rate, errors and latency of the API server |
| Kubernetes / Persistent Volumes | how full each PersistentVolumeClaim is |

The API answers with the same password, for scripts:

```bash
GRAFANA_PASSWORD=$(kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d)
curl -s -u "admin:$GRAFANA_PASSWORD" 'localhost:3000/api/search?query=Compute%20Resources' |
  jq -r '.[].title'
```

## First PromQL queries for a cluster

Paste these in Prometheus (**Query**) or in Grafana (**Explore**). A query with
`rate(...[5m])` needs two scrapes in the window, so it returns nothing during the
first minute.

Node CPU usage, in percent:

```promql
100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))
```

Node memory usage, in percent:

```promql
100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
```

> [!note] node-exporter on kind
> kind nodes are containers on one machine. node-exporter reads the kernel, so every
> kind node shows the CPU and memory of the whole Docker host (or Docker VM). The
> container metrics (cAdvisor) and `kubectl top` are per node.

CPU used by the pods of each namespace, in cores:

```promql
sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))
```

`container!=""` removes the pod-level cgroup series, which would count each pod twice.

Containers that restarted in the last hour:

```promql
sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[1h])) > 0
```

Pods that run but are not ready, and pods stuck in `Pending`:

```promql
(kube_pod_status_ready{condition="false"} == 1)
  and on (namespace, pod) (kube_pod_status_phase{phase="Running"} == 1)
```

```promql
kube_pod_status_phase{phase="Pending"} == 1
```

The first query keeps only `Running` pods. Without that, every completed Job pod
shows as "not ready" too.

From a script, through the port-forward of [[#Open Prometheus]]:

```bash
curl -s localhost:9090/api/v1/query \
  --data-urlencode 'query=sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))' |
  jq -r '.data.result[] | "\(.metric.namespace) \(.value[1])"'
```

## Clean up

`helm uninstall` leaves three things behind: the CRDs (Helm never deletes CRDs), the
`kube-prometheus-stack-kubelet` Service that the operator created in `kube-system`,
and the namespace.

```bash
helm uninstall kube-prometheus-stack --namespace monitoring --wait
kubectl -n kube-system delete service kube-prometheus-stack-kubelet
kubectl get crd -o name | grep monitoring.coreos.com | xargs kubectl delete
kubectl delete namespace monitoring
helm uninstall metrics-server --namespace kube-system
```

Deleting the CRDs deletes every ServiceMonitor, PodMonitor and PrometheusRule in the
cluster, including yours. Keep them in git (see [[kubernetes/observability/metrology/backup]]).

<!-- uplink -->
Part of [[kubernetes/observability/metrology/index|Kubernetes metrology]].
