#!/usr/bin/env bash
# note: kubernetes/observability/metrology/backup.md
# env: kind
# timeout: 2400
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/observability/metrology/backup
cd "$(mktemp -d)"
# Random local ports: compose tests of other runs may hold 9090 and 3000 on this host.
PPORT=$((20000 + RANDOM % 20000))
GPORT=$((PPORT + 1))
PIDS=()
POD=prometheus-kube-prometheus-stack-prometheus-0
PVC=prometheus-kube-prometheus-stack-prometheus-db-$POD
stop_port_forwards() {
  local p
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  PIDS=()
}
cleanup() {
  stop_port_forwards
  helm uninstall kube-prometheus-stack -n monitoring --wait >/dev/null 2>&1 || true
  kubectl -n monitoring delete pod "$POD" tsdb-restore --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
  kubectl -n kube-system delete service kube-prometheus-stack-kubelet --ignore-not-found >/dev/null 2>&1 || true
  kubectl get crd -o name | grep monitoring.coreos.com | xargs -r kubectl delete >/dev/null 2>&1 || true
  kubectl delete namespace monitoring --ignore-not-found >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT

# block HEADING [N]: a block of the note, with local ports 9090 and 3000 moved.
block() { note_block "$NOTE" "$1" "${2:-1}" | sed "s/localhost:9090/localhost:$PPORT/g; s/ 9090:9090/ $PPORT:9090/; s/localhost:3000/localhost:$GPORT/g"; }
install_block() { note_block "$NOTE" 'Snapshot the Prometheus data' 2; }
query_at() {
  curl -s "localhost:$PPORT/api/v1/query" --data-urlencode "query=$1" --data-urlencode "time=$2" |
    jq -r '.data.result[0].value[1] // empty'
}

section "Snapshot the Prometheus data"
note_block "$NOTE" 'Snapshot the Prometheus data' 1 >kps-backup-values.yaml
check "install with the admin API and a PVC (from the note)" bash -ec "$(install_block)"
check_output "the admin API is on" '--web.enable-admin-api' \
  kubectl -n monitoring get pod "$POD" -o jsonpath='{.spec.containers[?(@.name=="prometheus")].args}'
check_output "the data is on a 5Gi PVC" "^$PVC +Bound .* 5Gi" kubectl -n monitoring get pvc

section "Keep the Helm values in git"
check "helm get values and helm list (from the note)" bash -ec "$(note_block "$NOTE" 'Keep the Helm values in git' 1)"
check_output "the recovered values hold the admin API setting" 'enableAdminAPI: true' cat kps-values.yaml
check_output "helm list shows the chart version" 'kube-prometheus-stack-92\.18\.0' helm -n monitoring list

section "Rules and monitors are code"
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: by-hand
  labels: {release: kube-prometheus-stack}
spec:
  groups:
    - name: by-hand
      rules: [{record: "by_hand:up:sum", expr: "sum(up)"}]
YAML
handmade=$(bash -ec "$(note_block "$NOTE" 'Rules and monitors are code' 1)" 2>&1)
assert_match "a rule made by hand is listed (from the note)" "^$TEST_NS +prometheusrule.monitoring.coreos.com/by-hand" "$handmade"
assert_no_match "the chart's own rules are not" 'kube-prometheus-stack-' "$handmade"
check_output "the chart has many rules of its own" '^[0-9]{2}$' \
  bash -c "kubectl -n monitoring get prometheusrules -l app.kubernetes.io/managed-by=Helm --no-headers | wc -l | tr -d ' '"

section "Dashboards as ConfigMaps"
check "create the dashboard ConfigMap (from the note)" bash -ec "$(note_block "$NOTE" 'Dashboards as ConfigMaps' 1)"
check_output "the ConfigMap has the label grafana_dashboard=1" '^1$' \
  kubectl get configmap podinfo-dashboard -o jsonpath='{.metadata.labels.grafana_dashboard}'
check_output "and podinfo.json as data" '"uid": "podinfo"' cat podinfo-dashboard.yaml
GRAFANA_PASSWORD=$(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
export GRAFANA_PASSWORD
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana "$GPORT:80" >/dev/null 2>&1 &
PIDS+=($!)
retry 30 curl -sf -o /dev/null "localhost:$GPORT/api/health"
check "Grafana loads it from the test namespace" \
  retry 60 curl -sf -u "admin:$GRAFANA_PASSWORD" "localhost:$GPORT/api/dashboards/uid/podinfo"
check_output "as a provisioned dashboard" '^true$' \
  bash -c "curl -s -u admin:\$GRAFANA_PASSWORD localhost:$GPORT/api/dashboards/uid/podinfo | jq .meta.provisioned"

section "Export the dashboards made in the UI"
# A dashboard made "in the UI": created with the API, so it lives only in grafana.db.
curl -s -u "admin:$GRAFANA_PASSWORD" -H 'Content-Type: application/json' "localhost:$GPORT/api/dashboards/db" \
  -d '{"dashboard": {"uid": "made-in-ui", "title": "Made in the UI", "panels": []}}' >/dev/null
check "the export loop (from the note)" bash -ec "$(block 'Export the dashboards made in the UI')"
check_output "it exports the UI dashboard" '"title": "Made in the UI"' cat grafana-export/made-in-ui.json
check_output "and the provisioned ones" '"title": "Podinfo requests"' cat grafana-export/podinfo.json
check_fails "without the database id" grep -q '"id":' grafana-export/made-in-ui.json
check_output "about 30 dashboards" '^(2[5-9]|3[0-9])$' bash -c "ls grafana-export | wc -l | tr -d ' '"

section "Grafana state"
check_output "grafana.db is in an emptyDir by default" '"emptyDir":\{\}' \
  kubectl -n monitoring get deployment kube-prometheus-stack-grafana -o jsonpath='{.spec.template.spec.volumes[?(@.name=="storage")]}'
check_output "grafana.persistence.enabled=true gives Grafana a PVC" 'name: kube-prometheus-stack-grafana$' \
  bash -c "helm template kube-prometheus-stack kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts \
    --version 92.18.0 -n monitoring --set grafana.persistence.enabled=true | grep -A3 '^kind: PersistentVolumeClaim'"

section "Take the snapshot"
bash -c "$(block 'Snapshot the Prometheus data' 3 | grep 'port-forward' | sed 's/ &$//')" >/dev/null 2>&1 &
PIDS+=($!)
retry 30 curl -sf -o /dev/null "localhost:$PPORT/-/ready"
# Wait for some data, then remember a time that the snapshot covers.
check "Prometheus has scraped for a while" retry 120 bash -c "[ \$(curl -s localhost:$PPORT/api/v1/query --data-urlencode 'query=count(up)' | jq -r '.data.result[0].value[1] // 0') -gt 5 ]"
sleep 30
T_DATA=$(date -u +%Y-%m-%dT%H:%M:%SZ)
before=$(query_at 'count(up)' "$T_DATA")
check_output "count(up) at $T_DATA before the backup" '^[0-9]+$' echo "$before"
snap_script=$(block 'Snapshot the Prometheus data' 3 | grep -v 'port-forward\|^sleep')
SNAPSHOT=$(bash -ec "$snap_script" 2>&1 | tail -1)
check_output "POST /api/v1/admin/tsdb/snapshot returns a name (from the note)" '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]+$' echo "$SNAPSHOT"
export SNAPSHOT

section "Copy the snapshot out of the pod"
check_output "kubectl cp fails: the image is distroless" 'executable file not found' \
  bash -c "kubectl -n monitoring cp -c prometheus $POD:/prometheus/snapshots ./x 2>&1; true"
check "add the ephemeral container (from the note)" bash -ec "$(note_block "$NOTE" 'Copy the snapshot out of the pod' 2)"
check "copy, clean up, stop (from the note)" bash -ec "$(note_block "$NOTE" 'Copy the snapshot out of the pod' 3)"
check "the copy holds a block with meta.json" bash -c "ls prom-snapshot-$SNAPSHOT/*/meta.json"
check "and chunks and index" bash -c "ls -d prom-snapshot-$SNAPSHOT/*/chunks prom-snapshot-$SNAPSHOT/*/index"
check "the ephemeral container has stopped" retry 60 bash -c \
  "kubectl -n monitoring get pod $POD -o jsonpath='{.status.ephemeralContainerStatuses[?(@.name==\"backup\")].state.terminated.exitCode}' | grep -qx 0"
check_output "the snapshot is gone from the volume" '^$' \
  bash -c "kubectl -n monitoring debug $POD --container=check --image=busybox:1.37 --profile=restricted --custom=debug-mount.yaml -- ls /data/prometheus-db/snapshots >/dev/null; \
    kubectl -n monitoring wait pod/$POD --for=jsonpath='{.status.ephemeralContainerStatuses[?(@.name==\"check\")].state.terminated}' --timeout=60s >/dev/null; \
    kubectl -n monitoring logs $POD -c check"

section "Restore into a fresh Prometheus"
# A fresh start: no release, no PVC, no namespace.
stop_port_forwards
helm uninstall kube-prometheus-stack -n monitoring --wait >/dev/null
kubectl -n monitoring wait --for=delete pod/"$POD" --timeout=120s >/dev/null 2>&1 || true
kubectl delete namespace monitoring --wait --timeout=180s >/dev/null
check_fails "the old PVC is gone" kubectl -n monitoring get pvc "$PVC"
note_block "$NOTE" 'Restore into a fresh Prometheus' 1 >tsdb-restore.yaml
check "copy the blocks into a new PVC (from the note)" bash -ec "$(note_block "$NOTE" 'Restore into a fresh Prometheus' 2)"
check "install the chart again, same values (from the note)" bash -ec "$(install_block)"
check_output "Prometheus uses the restored PVC" "^$PVC +Bound" kubectl -n monitoring get pvc
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus "$PPORT:9090" >/dev/null 2>&1 &
PIDS+=($!)
retry 60 curl -sf -o /dev/null "localhost:$PPORT/-/ready"
check_output "the old data is back: count(up) at $T_DATA (from the note)" "\"$before\"" \
  bash -ec "$(block 'Restore into a fresh Prometheus' 3 | sed "s|\$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)|$T_DATA|")"

section "Turn the admin API off again"
check "helm upgrade with enableAdminAPI=false (from the note)" bash -ec "$(note_block "$NOTE" 'Turn the admin API off again' 1)"
stop_port_forwards
kubectl -n monitoring rollout status statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=300s >/dev/null
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus "$PPORT:9090" >/dev/null 2>&1 &
PIDS+=($!)
retry 60 curl -sf -o /dev/null "localhost:$PPORT/-/ready"
check_output "a snapshot is now refused" 'admin APIs disabled' curl -s -X POST "localhost:$PPORT/api/v1/admin/tsdb/snapshot"

section "Long-term storage with remote_write"
check_output "prometheus.prometheusSpec.remoteWrite is a chart value" '^    remoteWrite: \[\]' \
  helm show values kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version 92.18.0
skip "sending samples with remote_write" "needs a remote store (Thanos, Mimir...)"
