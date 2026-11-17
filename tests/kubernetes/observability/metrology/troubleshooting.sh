#!/usr/bin/env bash
# note: kubernetes/observability/metrology/troubleshooting.md
# env: kind
# timeout: 2700
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/observability/metrology/troubleshooting
QS=kubernetes/observability/metrology/quickstart
ADV=kubernetes/observability/metrology/advanced
cd "$(mktemp -d)"
GPORT=$((20000 + RANDOM % 20000))
PIDS=()
OWN_MS=0
cleanup() {
  local p
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  helm uninstall kube-prometheus-stack -n monitoring --wait >/dev/null 2>&1 || true
  kubectl -n kube-system delete service kube-prometheus-stack-kubelet --ignore-not-found >/dev/null 2>&1 || true
  kubectl get crd -o name | grep monitoring.coreos.com | xargs -r kubectl delete >/dev/null 2>&1 || true
  kubectl delete namespace monitoring --ignore-not-found >/dev/null 2>&1 || true
  ((OWN_MS)) && { helm uninstall metrics-server -n kube-system >/dev/null 2>&1 || true; }
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT

eval "$(note_block "$NOTE" 'Troubleshooting Kubernetes metrology' 1)" # PROM=...
# run HEADING [N]: run a block of the note, with PROM set and the test namespace for "demo".
run() { PROM=$PROM bash -ec "$(note_block "$NOTE" "$1" "${2:-1}" | sed "s/-n demo/-n $TEST_NS/g; s/\[demo\]/[$TEST_NS]/")"; }
promq() {
  kubectl get --raw "$PROM/api/v1/query?query=$(jq -rn --arg q "$1" '$q|@uri')" |
    jq -r '.data.result[] | "\(.metric | tostring) \(.value[1])"'
}
promq_has() { local out; out=$(promq "$1") && grep -Eq -- "$2" <<<"$out"; }
prom_config_has() { local c; c=$(kubectl get --raw "$PROM/api/v1/status/config" | jq -r .data.yaml) && grep -Eq -- "$1" <<<"$c"; }
alert_state() {
  kubectl get --raw "$PROM/api/v1/rules?type=alert" |
    jq -r --arg a "$1" '.data.groups[].rules[] | select(.name == $a) | .state'
}
state_is() { [[ $(alert_state "$1") == "$2" ]]; }

section "error: Metrics API not available"
if kubectl get apiservice v1beta1.metrics.k8s.io >/dev/null 2>&1; then
  skip "NotFound before metrics-server is installed" "another release already serves the Metrics API here"
  skip "MissingEndpoints while metrics-server cannot scrape" "another release already serves the Metrics API here"
else
  OWN_MS=1
  check_output "no metrics-server: the APIService is NotFound (from the note)" 'NotFound' \
    bash -c "$(note_block "$NOTE" 'error: Metrics API not available' 1 | head -1) 2>&1; true"
  # The quickstart's install without --kubelet-insecure-tls: the pod never gets ready.
  bash -ec "$(note_block "$QS" 'Install metrics-server' 1 | grep -v 'kubelet-insecure-tls' | sed 's/--wait --timeout 5m//')" >/dev/null
  check "the logs show the IP SANs error" retry 120 bash -c \
    "kubectl -n kube-system logs deploy/metrics-server --tail=20 2>&1 | grep -q \"doesn't contain any IP SANs\""
  check "the APIService is False (MissingEndpoints)" bash -c \
    "kubectl get apiservice v1beta1.metrics.k8s.io | grep -q 'False (MissingEndpoints)'"
  check "the three commands of the note run" run 'error: Metrics API not available' 1

  section "metrics-server cannot read the kubelets"
  check_output "the error of the note is in the logs (from the note)" \
    "$(note_block "$NOTE" 'metrics-server cannot read the kubelets' 1 | grep -o "tls: failed to verify certificate: x509: cannot validate certificate for [0-9.]+" | sed 's/[0-9.]*$//')" \
    kubectl -n kube-system logs deploy/metrics-server --tail=20
  check "with --kubelet-insecure-tls (quickstart) it works" bash -ec "$(note_block "$QS" 'Install metrics-server' 1)"
  check "the APIService becomes True" kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=120s
fi

section "A new pod has no metrics yet"
kubectl run fresh --image=busybox:1.37 -- sleep 3600 >/dev/null
kubectl wait --for=condition=Ready pod/fresh --timeout=120s >/dev/null
fresh_out=$(kubectl top pod fresh 2>&1 || true)
if grep -q 'not found' <<<"$fresh_out"; then
  assert_match "kubectl top on a fresh pod: podmetrics not found" "podmetrics.metrics.k8s.io \"$TEST_NS/fresh\" not found" "$fresh_out"
else
  skip "kubectl top on a fresh pod: podmetrics not found" "a scrape happened right after the pod started: $fresh_out"
fi
check "after a while, it has metrics" retry 90 kubectl top pod fresh

section "CRDs are missing or too big"
note_block "$ADV" 'Monitor your own application' 2 >podinfo-servicemonitor.yaml
note_block "$ADV" 'Monitor your own application' 1 >podinfo.yaml
check_output "no CRD: no matches for kind ServiceMonitor" 'no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"' \
  bash -c 'kubectl apply -f podinfo-servicemonitor.yaml 2>&1; true'
check_output "with the hint to install the CRDs first" 'ensure CRDs are installed first' \
  bash -c 'kubectl apply -f podinfo-servicemonitor.yaml 2>&1; true'

check "install kube-prometheus-stack (quickstart)" bash -ec "$(note_block "$QS" 'Install kube-prometheus-stack' 1)"
helm show crds kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version 92.18.0 >crds.yaml
check_output "prometheuses CRD is about 840 KiB" '^8[0-9]{2}$' \
  gawk 'BEGIN { RS = "\n---\n" } /name: prometheuses\.monitoring\.coreos\.com/ { print int(length($0) / 1024) }' crds.yaml
check_output "client-side apply: metadata.annotations: Too long" \
  'CustomResourceDefinition.apiextensions.k8s.io "prometheuses.monitoring.coreos.com" is invalid: metadata.annotations: Too long: may not be more than 262144 bytes' \
  bash -c 'kubectl apply -f crds.yaml 2>&1; true'
check "server-side apply works (from the note)" run 'metadata.annotations: Too long' 2
# Helm never upgrades CRDs: change one, helm upgrade, the change stays.
kubectl annotate crd servicemonitors.monitoring.coreos.com operator.prometheus.io/version=0.0.1 --overwrite >/dev/null
helm upgrade kube-prometheus-stack kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts \
  --version 92.18.0 -n monitoring --reuse-values --wait --timeout 10m >/dev/null
check_output "helm upgrade does not touch the CRDs" '^0\.0\.1$' \
  kubectl get crd servicemonitors.monitoring.coreos.com -o jsonpath='{.metadata.annotations.operator\.prometheus\.io/version}'
run 'metadata.annotations: Too long' 2 >/dev/null
check_output "the server-side apply of the note upgrades them" '^0\.94\.2$' \
  kubectl get crd servicemonitors.monitoring.coreos.com -o jsonpath='{.metadata.annotations.operator\.prometheus\.io/version}'
kubectl -n monitoring wait --for=condition=Available prometheus/kube-prometheus-stack-prometheus --timeout=300s >/dev/null

section "Control-plane targets are down"
sched_down() { run 'Control-plane targets are down' 1 | grep -q '^kube-scheduler '; }
check "kube-scheduler is down" retry 120 sched_down
down=$(run 'Control-plane targets are down' 1)
assert_match "kube-controller-manager: connection refused (from the note)" '^kube-controller-manager https://[0-9.]+:10257/metrics .*connect: connection refused' "$down"
for j in kube-scheduler kube-etcd kube-proxy; do assert_match "$j is down too" "^$j " "$down"; done
check_output "the scheduler binds 127.0.0.1 (from the note)" '^ +- --bind-address=127\.0\.0\.1$' run 'Control-plane targets are down' 3
note_block "$NOTE" 'Control-plane targets are down' 5 >managed.yaml
rendered=$(helm template kube-prometheus-stack kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts \
  --version 92.18.0 -n monitoring -f managed.yaml)
for sm in kube-controller-manager kube-scheduler kube-etcd kube-proxy; do
  assert_no_match "with the managed-cluster values, no $sm ServiceMonitor" "name: kube-prometheus-stack-$sm\$" "$rendered"
done
assert_match "the other ServiceMonitors stay" 'name: kube-prometheus-stack-apiserver$' "$rendered"

section "A ServiceMonitor is not picked up"
kubectl apply -f podinfo.yaml >/dev/null
kubectl rollout status deployment/podinfo --timeout=180s >/dev/null
# Without the release label first.
grep -v 'release: kube-prometheus-stack' podinfo-servicemonitor.yaml | kubectl apply -f - >/dev/null
# A labelled ServiceMonitor with a port number: in the config, but no target.
sed 's/name: podinfo$/name: podinfo-portnumber/; s/- port: http/- port: "9898"/' podinfo-servicemonitor.yaml | kubectl apply -f - >/dev/null
check "the port-number ServiceMonitor is in the config" retry 180 prom_config_has "job_name: serviceMonitor/$TEST_NS/podinfo-portnumber/0"
jobs=$(run 'A ServiceMonitor is not picked up' 1)
assert_match "point 1 lists the generated jobs (from the note)" "serviceMonitor/$TEST_NS/podinfo-portnumber/0" "$jobs"
assert_no_match "the ServiceMonitor without release label is not there" "serviceMonitor/$TEST_NS/podinfo/0" "$jobs"
labels=$(run 'A ServiceMonitor is not picked up' 2)
assert_match "point 2 shows the selector (from the note)" '"release":"kube-prometheus-stack"' "$labels"
assert_match "and the release label of each ServiceMonitor" "^$TEST_NS +podinfo +[0-9a-z]+ *$" "$labels"
assert_match "the labelled one shows its release" "^$TEST_NS +podinfo-portnumber +[0-9a-z]+ +kube-prometheus-stack" "$labels"
check_output "the port-number job has no target" '^0$' \
  bash -c "kubectl get --raw '$PROM/api/v1/targets?state=active' | jq '[.data.activeTargets[] | select(.scrapePool == \"serviceMonitor/$TEST_NS/podinfo-portnumber/0\")] | length'"
# A ServiceMonitor in monitoring that targets the test namespace, with the note's spec part.
{
  printf 'apiVersion: monitoring.coreos.com/v1\nkind: ServiceMonitor\n'
  printf 'metadata: {name: podinfo-remote, namespace: monitoring, labels: {release: kube-prometheus-stack}}\n'
  note_block "$NOTE" 'A ServiceMonitor is not picked up' 3 | sed "s/\[demo\]/[$TEST_NS]/"
  printf '  selector: {matchLabels: {app: podinfo}}\n  endpoints: [{port: http}]\n'
} >remote.yaml
kubectl apply -f remote.yaml >/dev/null
check "a ServiceMonitor in monitoring with namespaceSelector (from the note) finds the pods" \
  retry 180 bash -c "kubectl get --raw '$PROM/api/v1/targets?state=active' | jq -e '.data.activeTargets[] | select(.scrapePool == \"serviceMonitor/monitoring/podinfo-remote/0\" and .health == \"up\")'"
check_output "point 4: the Service carries the labels (from the note)" "^$TEST_NS +podinfo " run 'A ServiceMonitor is not picked up' 4
check_output "point 6: the Service has EndpointSlices (from the note)" "^$TEST_NS +podinfo-[a-z0-9]+ +IPv4 +9898" run 'A ServiceMonitor is not picked up' 5
check_output "point 7: the chart's Prometheus may list EndpointSlices (from the note)" '^yes$' run 'A ServiceMonitor is not picked up' 6
check "Prometheus discovers targets through Kubernetes service discovery" prom_config_has 'role: endpoint'
kubectl delete servicemonitor podinfo-portnumber >/dev/null
kubectl -n monitoring delete servicemonitor podinfo-remote >/dev/null
kubectl apply -f podinfo-servicemonitor.yaml >/dev/null

section "Grafana shows No data"
GRAFANA_PASSWORD=$(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
export GRAFANA_PASSWORD
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana "$GPORT:80" >/dev/null 2>&1 &
PIDS+=($!)
retry 30 curl -sf -o /dev/null "localhost:$GPORT/api/health"
gblock() { note_block "$NOTE" 'Grafana shows "No data"' "$1" | sed "s/localhost:3000/localhost:$GPORT/"; }
check_output "the data source health (from the note)" '"status": "OK"' bash -ec "$(gblock 1)"
check_output "with the message of the note" 'Successfully queried the Prometheus API' bash -ec "$(gblock 1)"
check_output "a query through the Grafana proxy returns series (from the note)" '^[1-9][0-9]*$' bash -ec "$(gblock 3)"

section "Prometheus is OOMKilled or slow"
tsdb=$(run 'Prometheus is OOMKilled or slow' 3)
assert_match "the TSDB status gives the series count (from the note)" '"series": [0-9]+' "$tsdb"
assert_match "and the top metrics" '"name": "[a-z_:]+"' "$tsdb"
check "topk by metric name (from the note)" retry 30 promq_has "$(note_block "$NOTE" 'Prometheus is OOMKilled or slow' 4)" '"__name__":"[a-z_]+"'
check "prometheus_tsdb_head_series (from the note)" promq_has "$(note_block "$NOTE" 'Prometheus is OOMKilled or slow' 5)" ' [1-9][0-9]*$'
check "process_resident_memory_bytes of Prometheus (from the note)" promq_has "$(note_block "$NOTE" 'Prometheus is OOMKilled or slow' 6)" ' [1-9][0-9.e+]*$'
# fresh_buckets: podinfo bucket samples newer than 30 s, so still being scraped.
fresh_buckets() { promq_has "count(timestamp(http_request_duration_seconds_bucket{namespace=\"$TEST_NS\"}) > time() - 30)" ' [1-9]'; }
check "podinfo histogram buckets are scraped" retry 120 fresh_buckets
# The note's metricRelabelings, added to the podinfo ServiceMonitor.
note_block "$NOTE" 'Prometheus is OOMKilled or slow' 7 | sed '1d' >relabel.yaml
awk '/- port: http/ { while ((getline l < "relabel.yaml") > 0) print l; next } { print }' podinfo-servicemonitor.yaml >dropped.yaml
check "the ServiceMonitor with metricRelabelings applies" kubectl apply -f dropped.yaml
not_fresh() { ! fresh_buckets; }
check "the dropped series get no new samples" retry 300 not_fresh
check "other podinfo series stay" promq_has "http_requests_total{namespace=\"$TEST_NS\"}" '.'
# sampleLimit: a scrape with more samples fails, and the target is down.
sed 's/^spec:/spec:\n  sampleLimit: 10/' podinfo-servicemonitor.yaml | kubectl apply -f - >/dev/null
limited() {
  kubectl get --raw "$PROM/api/v1/targets?state=active" |
    jq -e --arg p "serviceMonitor/$TEST_NS/podinfo/0" '.data.activeTargets[] | select(.scrapePool == $p and .health == "down" and (.lastError | test("sample limit")))'
}
check "with sampleLimit: 10, the target is down with 'sample limit exceeded'" retry 240 limited
kubectl apply -f podinfo-servicemonitor.yaml >/dev/null

section "The Prometheus volume is full"
check "prometheus_tsdb_storage_blocks_bytes (from the note)" promq_has "$(note_block "$NOTE" 'The Prometheus volume is full' 1)" ' [0-9]+$'
# A Prometheus PVC on kind, to show that the kubelet has no stats for local-path volumes.
kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: prometheus-test-data}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: pvc-user}
spec:
  containers: [{name: c, image: busybox:1.37, command: ["sleep", "3600"], volumeMounts: [{name: d, mountPath: /d}]}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: prometheus-test-data}}]
YAML
kubectl wait --for=condition=Ready pod/pvc-user --timeout=120s >/dev/null
# The kubelet collects volume stats every minute.
sleep 90
check_output "on kind, kubelet_volume_stats_available_bytes returns nothing (from the note)" '^$' \
  promq "$(note_block "$NOTE" 'The Prometheus volume is full' 2)"
check_output "kind's standard StorageClass cannot grow volumes" '^$|^false$' \
  kubectl get storageclass standard -o jsonpath='{.allowVolumeExpansion}'

section "An alert never fires"
cat >rules.yaml <<YAML
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: podinfo
  labels: {release: kube-prometheus-stack}
spec:
  groups:
    - name: podinfo
      rules:
$(note_block "$NOTE" 'An alert never fires' 2 | sed 's/^/        /')
        - alert: PodinfoDownWrong
          expr: up{job="podinfo"} == 0
          for: 1m
YAML
kubectl apply -f rules.yaml >/dev/null
check "the rules are loaded and inactive while podinfo runs" retry 180 state_is PodinfoDown inactive
check_output "the note's command lists them" '^PodinfoDown inactive ok' run 'An alert never fires' 1
check_output "evaluations run every 30s" '^30s$' kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus -o jsonpath='{.spec.evaluationInterval}'
kubectl scale deployment podinfo --replicas=0 >/dev/null
check "absent(): PodinfoDown goes pending first" retry 180 state_is PodinfoDown pending
check "then firing, after for: 1m" retry 180 state_is PodinfoDown firing
check_output "up == 0 never fires when the pods are gone" '^inactive$' alert_state PodinfoDownWrong
check_output "the note's command shows it firing" '^PodinfoDown firing ok' run 'An alert never fires' 1
am=$(run 'An alert never fires' 3)
assert_match "Alertmanager routes to the receiver null by default (from the note)" "receiver: \"?null\"?" "$am"
check "Watchdog always fires, and reaches Alertmanager" retry 120 bash -c \
  "kubectl get --raw /api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:http-web/proxy/api/v2/alerts | jq -e '.[] | select(.labels.alertname == \"Watchdog\")'"

section "Useful commands"
check "all the useful commands run (from the note)" run 'Useful commands' 1
out=$(run 'Useful commands' 1 2>&1 || true)
assert_match "targets not up: kube-scheduler" '^kube-scheduler ' "$out"
assert_match "generated jobs: podinfo" "serviceMonitor/$TEST_NS/podinfo/0" "$out"
assert_match "alerts: PodinfoDown firing" '^PodinfoDown firing' "$out"
assert_match "Alertmanager has PodinfoDown" ' +[0-9]+ PodinfoDown$' "$out"
assert_match "runtime info" '"reloadConfigSuccess": true' "$out"

section "Prometheus is OOMKilled (reproduced)"
# Not from the note: a 40Mi limit makes Prometheus run out of memory, to check the command.
helm upgrade kube-prometheus-stack kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts \
  --version 92.18.0 -n monitoring --reuse-values --set prometheus.prometheusSpec.resources.limits.memory=40Mi >/dev/null
oom() { [[ $(run 'Prometheus is OOMKilled or slow' 1) == OOMKilled ]]; }
check "the note's command shows OOMKilled" retry 240 oom
