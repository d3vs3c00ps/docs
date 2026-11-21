---
title: Back up a Kubernetes monitoring stack
description: What to back up in kube-prometheus-stack — rules and dashboards as code, Helm values, a Prometheus TSDB snapshot copied out of a distroless pod and restored into a fresh Prometheus, Grafana state
tags: [kubernetes, observability, monitoring, prometheus, grafana, backup]
type: howto
status: complete
---

# Back up a Kubernetes monitoring stack

A monitoring stack holds two kinds of things:

- **configuration**: scrape targets, rules, alerts, dashboards, chart values. You
  wrote it, it is small, and you cannot get it back if it is lost;
- **data**: the time series. They are big, and they come back by themselves as soon
  as Prometheus scrapes again. You lose only the history.

So the first backup is git. A copy of the time series is a second, optional step.

This note uses the setup of [[kubernetes/observability/metrology/quickstart]]: the
`kube-prometheus-stack` chart 92.18.0, release `kube-prometheus-stack`, namespace
`monitoring`. Backing up the cluster itself (etcd, Velero) is in
[[kubernetes/cluster-setup/cluster-backup]]. Prometheus and Grafana outside
Kubernetes: [[observability/prometheus/quickstart]], [[observability/grafana/quickstart]].

## What to back up

| What | Where it lives | How to keep it |
| --- | --- | --- |
| Chart version and values | the Helm release | a values file in git; `helm get values` to recover it |
| ServiceMonitors, PodMonitors | CRs in the cluster | YAML in git, next to the application |
| Recording rules and alerts | `PrometheusRule` CRs | YAML in git |
| Grafana dashboards | ConfigMaps with the label `grafana_dashboard` | YAML in git; export the ones made in the UI |
| Grafana users, folders, preferences | `grafana.db`, in an `emptyDir` by default | nothing to back up if Grafana is stateless (see below) |
| Time series | the Prometheus TSDB, on a volume | a TSDB snapshot, or `remote_write` to long-term storage |

## Keep the Helm values in git

Everything you changed in the chart is in one values file. If the release was
installed with `--set` and nobody kept the file, Helm still knows the values:

```bash
helm -n monitoring get values kube-prometheus-stack -o yaml > kps-values.yaml
helm -n monitoring list
```

`helm list` shows the chart version (`kube-prometheus-stack-92.18.0`). Keep both: the
same values with another chart version can give another result.

## Rules and monitors are code

Write PrometheusRules, ServiceMonitors and PodMonitors as YAML files, in git, and
apply them with the application (examples in
[[kubernetes/observability/metrology/advanced]]). Then a lost cluster is one
`kubectl apply` away.

To find the ones someone created by hand, list those that Helm does not manage. The
chart's own objects carry `app.kubernetes.io/managed-by=Helm`:

```bash
kubectl get prometheusrules,servicemonitors,podmonitors --all-namespaces \
  -l 'app.kubernetes.io/managed-by!=Helm'
```

Deleting the chart's CRDs deletes all of these objects, in every namespace. That is
one more reason to keep them in git.

## Dashboards as ConfigMaps

Grafana in this chart runs a sidecar container that watches ConfigMaps with the label
`grafana_dashboard: "1"`, in every namespace, and loads them as dashboards. So a
dashboard is a JSON file in git, shipped as a ConfigMap:

```bash
cat > podinfo.json <<'EOF'
{
  "uid": "podinfo",
  "title": "Podinfo requests",
  "schemaVersion": 41,
  "panels": [
    {
      "type": "timeseries",
      "title": "Requests per second",
      "gridPos": {"x": 0, "y": 0, "w": 24, "h": 8},
      "targets": [{"expr": "sum by (namespace) (rate(http_requests_total[5m]))"}]
    }
  ]
}
EOF
kubectl create configmap podinfo-dashboard --from-file=podinfo.json --dry-run=client -o yaml |
  kubectl label --local -f - grafana_dashboard=1 -o yaml > podinfo-dashboard.yaml
kubectl apply -f podinfo-dashboard.yaml
```

Commit `podinfo-dashboard.yaml`. The dashboard shows up in Grafana within seconds.
It is *provisioned*: a change saved in the UI is lost when the sidecar loads the
ConfigMap again. Edit the JSON, not the UI.

### Export the dashboards made in the UI

Dashboards created in the UI live only in the Grafana database. Export them with the
HTTP API, then turn each file into a ConfigMap as above. With the port-forward and the
password of [[kubernetes/observability/metrology/quickstart#Open Grafana]]:

```bash
mkdir -p grafana-export
for uid in $(curl -s -u "admin:$GRAFANA_PASSWORD" 'localhost:3000/api/search?type=dash-db' | jq -r '.[].uid'); do
  curl -s -u "admin:$GRAFANA_PASSWORD" "localhost:3000/api/dashboards/uid/$uid" |
    jq '.dashboard | del(.id)' > "grafana-export/$uid.json"
done
ls grafana-export
```

`del(.id)` removes the database id, which differs on each Grafana.

### Grafana state

By default the chart keeps the Grafana database (`grafana.db`, SQLite) in an
`emptyDir` volume. Users, folders, preferences and dashboards made in the UI are lost
when the pod restarts. That is fine, and even good, when Grafana is **stateless**: the
data sources and dashboards come from the chart and from ConfigMaps, and people log in
through single sign-on. Then there is nothing to back up.

If you need Grafana state (local users, Grafana-managed alerts, UI dashboards), set
`grafana.persistence.enabled: true`, or better, point Grafana at a PostgreSQL or MySQL
database, and back up that database with its own tools.

## Snapshot the Prometheus data

A snapshot is a consistent copy of the TSDB, made by Prometheus itself, in a
`snapshots/` folder next to the data. It uses hard links, so it is fast and takes no
space at first. It needs two things the chart does not set by default: the admin API,
and a volume worth backing up (the default `emptyDir` disappears with the pod).

```yaml
# kps-backup-values.yaml
prometheus:
  prometheusSpec:
    enableAdminAPI: true
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 5Gi
```

```bash
helm upgrade --install kube-prometheus-stack kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts --version 92.18.0 \
  --namespace monitoring --create-namespace \
  -f kps-backup-values.yaml --wait --timeout 10m
kubectl -n monitoring wait --for=condition=Available \
  prometheus/kube-prometheus-stack-prometheus --timeout=5m
```

Take the snapshot through a port-forward:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
sleep 2
SNAPSHOT=$(curl -s -X POST localhost:9090/api/v1/admin/tsdb/snapshot | jq -r .data.name)
echo "$SNAPSHOT"
```

```text
20261105T131027Z-5de9f3204a937ebb
```

### Copy the snapshot out of the pod

`kubectl cp` runs `tar` in the container. The Prometheus image of this chart is a
*distroless* image: it has no shell and no `tar`, so `kubectl cp` and
`kubectl exec ... ls` fail:

```text
exec: "tar": executable file not found in $PATH
```

Add an *ephemeral container* with the tools, which mounts the data volume. The
`--custom` file adds the volume mount. An ephemeral container cannot use `subPath`, so
mount the whole volume: the operator keeps the TSDB in its `prometheus-db` folder.

```bash
cat > debug-mount.yaml <<'EOF'
volumeMounts:
  - name: prometheus-kube-prometheus-stack-prometheus-db
    mountPath: /data
EOF
kubectl -n monitoring debug prometheus-kube-prometheus-stack-prometheus-0 \
  --container=backup --image=busybox:1.37 --profile=restricted --custom=debug-mount.yaml \
  -- sh -c 'trap "exit 0" TERM; sleep 3600 & wait'
kubectl -n monitoring wait pod/prometheus-kube-prometheus-stack-prometheus-0 \
  --for=jsonpath='{.status.ephemeralContainerStatuses[?(@.name=="backup")].state.running}' --timeout=120s
```

Copy the snapshot, remove it from the volume, and stop the ephemeral container:

```bash
kubectl -n monitoring cp -c backup \
  "prometheus-kube-prometheus-stack-prometheus-0:/data/prometheus-db/snapshots/$SNAPSHOT" "prom-snapshot-$SNAPSHOT"
kubectl -n monitoring exec prometheus-kube-prometheus-stack-prometheus-0 -c backup -- \
  rm -rf "/data/prometheus-db/snapshots/$SNAPSHOT"
kubectl -n monitoring exec prometheus-kube-prometheus-stack-prometheus-0 -c backup -- kill 1
ls "prom-snapshot-$SNAPSHOT"
```

The snapshot holds one folder per TSDB block, each with `chunks/`, `index` and
`meta.json`. Archive it and store it outside the cluster.

> [!warning] Stop the ephemeral container
> An ephemeral container stays in the pod until it exits. `sleep` as PID 1 ignores
> `SIGTERM`, and the Prometheus pod has a 600-second grace period, so a debug container
> running plain `sleep 3600` blocks the deletion of the pod for ten minutes. The
> `trap` above makes it exit on `SIGTERM`, and `kill 1` stops it at once.

## Restore into a fresh Prometheus

The operator runs Prometheus as a StatefulSet. Its PersistentVolumeClaim has a fixed
name: `<volume name>-<pod name>`, here
`prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0`.
A StatefulSet uses an existing PVC with that name instead of creating one. So restore
**before** you install the chart: create the PVC, copy the blocks into it, then
install.

```yaml
# tsdb-restore.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
  namespace: monitoring
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: tsdb-restore
  namespace: monitoring
spec:
  securityContext:          # the user and group Prometheus runs as
    runAsUser: 1000
    runAsGroup: 2000
    fsGroup: 2000
  containers:
    - name: restore
      image: busybox:1.37
      command: ["sh", "-c", "trap 'exit 0' TERM; sleep 3600 & wait"]
      volumeMounts:
        - name: db
          mountPath: /data
  volumes:
    - name: db
      persistentVolumeClaim:
        claimName: prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
```

```bash
kubectl create namespace monitoring
kubectl apply -f tsdb-restore.yaml
kubectl -n monitoring wait --for=condition=Ready pod/tsdb-restore --timeout=180s
kubectl -n monitoring cp "prom-snapshot-$SNAPSHOT" tsdb-restore:/data/prometheus-db
kubectl -n monitoring delete pod tsdb-restore
```

`/data/prometheus-db` does not exist yet, so `kubectl cp` creates it with the blocks
inside, owned by user 1000. Then install the chart with the same values file as
before (the `helm upgrade --install` command above). Prometheus finds the blocks at
start, and the old data is back:

```bash
curl -s localhost:9090/api/v1/query --data-urlencode 'query=count(up)' \
  --data-urlencode "time=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)" | jq '.data.result'
```

(Use a time inside the snapshot. `date -d` is GNU date; on macOS use
`date -u -v-1H +%Y-%m-%dT%H:%M:%SZ`.)

Retention applies to restored blocks too. Restore an old snapshot only into a
Prometheus whose `retention` covers it, or Prometheus deletes the old blocks.

### Turn the admin API off again

The admin API can also delete series (`/api/v1/admin/tsdb/delete_series`), and
anyone who reaches port 9090 can call it: there is no authentication. Enable it for
the backup, then turn it off:

```bash
helm upgrade kube-prometheus-stack kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts --version 92.18.0 \
  --namespace monitoring --reuse-values \
  --set prometheus.prometheusSpec.enableAdminAPI=false --wait
```

## Long-term storage with remote_write

Snapshots are a cold copy. For a long history, or to survive the loss of the cluster
without a restore step, let Prometheus send every sample as it scrapes to a
long-term store: Thanos, Grafana Mimir, Cortex, VictoriaMetrics, or a managed service.
In this chart, that is the `prometheus.prometheusSpec.remoteWrite` list (one entry per
destination: `url`, authentication, and optional `writeRelabelConfigs` to send only
some series). Prometheus keeps a short local retention, and the remote store keeps
months or years, with its own backups. Not tested here: it needs a remote store.

<!-- uplink -->
Part of [[kubernetes/observability/metrology/index|Kubernetes metrology]].
