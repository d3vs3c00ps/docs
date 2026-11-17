#!/usr/bin/env bash
# note: kubernetes/observability/metrology/advanced.md
# env: kind
# timeout: 2700
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
source "$NOTES_ROOT/tests/versions.env"
use_test_namespace

NOTE=kubernetes/observability/metrology/advanced
cd "$(mktemp -d)"
CP=$CLUSTER-control-plane
PROXY=/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:http-web/proxy
CP_CHANGED=0

# Put the shared cluster back as it was: the control-plane manifests and kube-proxy.
revert_control_plane() {
  ((CP_CHANGED)) || return 0
  local f
  kubectl -n kube-system get configmap kube-proxy -o yaml |
    sed 's/metricsBindAddress: 0.0.0.0:10249/metricsBindAddress: ""/' | kubectl replace -f - >/dev/null || true
  kubectl -n kube-system rollout restart daemonset kube-proxy >/dev/null || true
  kubectl -n kube-system rollout status daemonset kube-proxy --timeout=180s >/dev/null || true
  for f in kube-controller-manager kube-scheduler etcd; do
    docker exec "$CP" cp "/root/metrology-backup/$f.yaml" "/etc/kubernetes/manifests/$f.yaml" || true
  done
  docker exec "$CP" rm -rf /root/metrology-backup || true
  # Wait for the old etcd to be back (loopback only), then for the API server.
  retry 180 docker exec "$CP" sh -c "ss -ltn | grep -q '127.0.0.1:2381 ' && ! ss -ltn | grep -Eq '(\*|0\.0\.0\.0):2381 '" || true
  wait_api
  CP_CHANGED=0
}
wait_api() { retry 120 kubectl get --raw /readyz; }
cleanup() {
  revert_control_plane
  helm uninstall kube-prometheus-stack -n monitoring --wait >/dev/null 2>&1 || true
  kubectl -n kube-system delete service kube-prometheus-stack-kubelet --ignore-not-found >/dev/null 2>&1 || true
  kubectl get crd -o name | grep monitoring.coreos.com | xargs -r kubectl delete >/dev/null 2>&1 || true
  kubectl delete namespace monitoring --ignore-not-found >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT

# promq QUERY: one "labels value" line per series of an instant query.
promq() {
  kubectl get --raw "$PROXY/api/v1/query?query=$(jq -rn --arg q "$1" '$q|@uri')" |
    jq -r '.data.result[] | "\(.metric | tostring) \(.value[1])"'
}
promq_has() { local out; out=$(promq "$1") && grep -Eq -- "$2" <<<"$out"; }
# prom_above QUERY POD MIN: the series of POD has a value above MIN.
prom_above() { promq "$1" | grep "\"pod\":\"$2\"" | awk -v m="$3" '$NF > m { ok = 1 } END { exit !ok }'; }
# prom_config_has REGEX: the generated Prometheus configuration matches REGEX.
prom_config_has() { local c; c=$(kubectl get --raw "$PROXY/api/v1/status/config" | jq -r .data.yaml) && grep -Eq -- "$1" <<<"$c"; }
target_health() {
  kubectl get --raw "$PROXY/api/v1/targets?state=active" |
    jq -r --arg j "$1" '.data.activeTargets[] | select(.labels.job == $j) | .health' | sort -u | tr '\n' ' '
}
job_is() { [[ $(target_health "$1") == "$2 " ]]; }

section "A new kind cluster"
# A second, small cluster, deleted on exit: only the flags it gets are checked.
note_block "$NOTE" 'A new kind cluster' 1 >kind-metrics.yaml
extra=metro-$RANDOM
kind_cluster "$extra"
check "kind create cluster with kind-metrics.yaml (from the note)" kind create cluster --name "$extra" \
  --image "$KIND_NODE_IMAGE" --config kind-metrics.yaml --kubeconfig "$PWD/extra.kubeconfig" --wait 180s
check_output "the controller manager listens on 0.0.0.0" '--bind-address=0.0.0.0' \
  docker exec "$extra-control-plane" cat /etc/kubernetes/manifests/kube-controller-manager.yaml
check_output "the scheduler listens on 0.0.0.0" '--bind-address=0.0.0.0' \
  docker exec "$extra-control-plane" cat /etc/kubernetes/manifests/kube-scheduler.yaml
check_output "etcd serves metrics on 0.0.0.0:2381" '--listen-metrics-urls=http://0.0.0.0:2381' \
  docker exec "$extra-control-plane" cat /etc/kubernetes/manifests/etcd.yaml
check_output "kube-proxy metricsBindAddress is 0.0.0.0:10249" 'metricsBindAddress: 0.0.0.0:10249' \
  kubectl --kubeconfig "$PWD/extra.kubeconfig" -n kube-system get configmap kube-proxy -o yaml
kind delete cluster --name "$extra" >/dev/null 2>&1 || true

section "Tune the chart with Helm values"
note_block "$NOTE" 'Tune the chart with Helm values' 1 >kps-values.yaml
check "helm install with kps-values.yaml (from the note)" bash -ec "$(note_block "$NOTE" 'Tune the chart with Helm values' 2)"
check_output "retention is 15d or 9GiB (from the note)" '"storageRetention": "15d or 9GiB"' \
  bash -ec "$(note_block "$NOTE" 'Tune the chart with Helm values' 3)"
check_output "Prometheus data is on a 10Gi PVC" 'prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0 +Bound .* 10Gi' \
  kubectl -n monitoring get pvc
check "the global scrape interval is 30s" prom_config_has '^  scrape_interval: 30s'
check_output "Prometheus requests 200m CPU and 1Gi" '"cpu":"200m","memory":"1Gi"' \
  kubectl -n monitoring get pod prometheus-kube-prometheus-stack-prometheus-0 -o jsonpath='{.spec.containers[?(@.name=="prometheus")].resources.requests}'
check_output "Alertmanager keeps 120h" '^120h$' \
  kubectl -n monitoring get alertmanager kube-prometheus-stack-alertmanager -o jsonpath='{.spec.retention}'

section "Monitor your own application"
note_block "$NOTE" 'Monitor your own application' 1 >podinfo.yaml
note_block "$NOTE" 'Monitor your own application' 2 >podinfo-servicemonitor.yaml
note_block "$NOTE" 'PodMonitor' 1 >podinfo-podmonitor.yaml
kubectl apply -f podinfo.yaml >/dev/null
check "podinfo runs" kubectl rollout status deployment/podinfo --timeout=180s

section "The release label trap"
# The note's ServiceMonitor without its release label, next to the labelled PodMonitor:
# once the PodMonitor is in the config, the operator has had its chance with both.
grep -v 'release: kube-prometheus-stack' podinfo-servicemonitor.yaml | kubectl apply -f - >/dev/null
check "a labelled PodMonitor is picked up (from the note)" kubectl apply -f podinfo-podmonitor.yaml
check "its scrape pool appears in the config" retry 180 prom_config_has "job_name: podMonitor/$TEST_NS/podinfo-pods/0"
check_fails "the ServiceMonitor without the release label is ignored" prom_config_has "serviceMonitor/$TEST_NS/podinfo/"
check_output "the selectors want release: kube-prometheus-stack (from the note)" \
  '^\{"matchLabels":\{"release":"kube-prometheus-stack"\}\}$' bash -ec "$(note_block "$NOTE" 'The release label trap' 1)"
note_block "$NOTE" 'The release label trap' 3 >all.yaml
check_output "with the NilUsesHelmValues values set to false, the selectors are {}" '^ *serviceMonitorSelector: \{\}' \
  bash -c "helm template kube-prometheus-stack kube-prometheus-stack \
    --repo https://prometheus-community.github.io/helm-charts --version 92.18.0 -n monitoring -f all.yaml | grep -A1 'serviceMonitorSelector:'"
check "kubectl apply the labelled ServiceMonitor (from the note)" bash -ec "$(note_block "$NOTE" 'Monitor your own application' 3)"
check "the ServiceMonitor is now in the config" retry 180 prom_config_has "job_name: serviceMonitor/$TEST_NS/podinfo/0"
two_up() {
  [ "$(bash -ec "$(note_block "$NOTE" 'Monitor your own application' 4)" | grep -c "^serviceMonitor/$TEST_NS/podinfo/0 podinfo-.* up$")" -eq 2 ]
}
check "both podinfo pods are up (from the note)" retry 120 two_up
check_output "the operator adds namespace, service, pod, container, endpoint labels" \
  '"container":"podinfo".*"endpoint":"http".*"job":"podinfo","namespace":"'"$TEST_NS"'","pod":"podinfo-.*","service":"podinfo"' \
  promq "up{job=\"podinfo\", namespace=\"$TEST_NS\"}"
check "PodMonitor targets have job <namespace>/podinfo-pods" retry 60 promq_has "up{job=\"$TEST_NS/podinfo-pods\"}" ' 1$'

section "Recording rules and alerts: PrometheusRule"
note_block "$NOTE" 'Recording rules and alerts' 1 >podinfo-rules.yaml
check "kubectl apply the PrometheusRule (from the note)" bash -ec "$(note_block "$NOTE" 'Recording rules and alerts' 2)"
sed 's/up{job="podinfo"} == 1)/up{job="podinfo"} == 1/' podinfo-rules.yaml >broken.yaml
check_output "the admission webhook refuses a broken expression" 'could not parse expression.*unclosed left parenthesis' \
  bash -c 'kubectl apply -f broken.yaml 2>&1; true'
rules() { bash -ec "$(note_block "$NOTE" 'Recording rules and alerts' 4)"; }
alert_loaded() { rules | grep -qx 'alerting PodinfoDown ok inactive'; }
check "the rules are loaded, the alert is inactive (from the note)" retry 180 alert_loaded
check_output "the recording rule is loaded and healthy" '^recording namespace_job:http_requests:rate5m ok $' rules
check "the recording rule has a value" retry 120 promq_has "namespace_job:http_requests:rate5m{namespace=\"$TEST_NS\"}" '"job":"podinfo"'

section "Key metrics and queries"
note_block "$NOTE" 'Key metrics and queries' 1 >hogs.yaml
check "kubectl apply hogs.yaml (from the note)" bash -ec "$(note_block "$NOTE" 'Key metrics and queries' 2)"
q() { note_block "$NOTE" "$1" "${2:-1}" | sed "s/{container!=\"\"}/{container!=\"\", namespace=\"$TEST_NS\"}/g"; }
# Throttling needs 5 minutes of history to be close to 1; wait until it is clearly high.
check "CPU usage: cpu-hog uses CPU" retry 180 prom_above "$(q 'CPU usage')" cpu-hog 0.02
check "working set: one series per pod" retry 60 promq_has "$(q 'Memory: working set')" '"pod":"podinfo-'
check "working set / limit: podinfo is below its limit" retry 60 promq_has "$(q 'Memory: working set' 2)" '"container":"podinfo".* 0\.[0-9]+$'
check_output "usage is at least the working set, cluster-wide" '^\{\} 1$' \
  promq 'sum(container_memory_usage_bytes{container!=""}) >= bool sum(container_memory_working_set_bytes{container!=""})'
check "throttling: cpu-hog is throttled in most periods" retry 300 prom_above "$(q 'CPU throttling')" cpu-hog 0.6
check_fails "throttling: no series for podinfo, which has no CPU limit" promq_has "$(q 'CPU throttling')" '"pod":"podinfo-'
check "CPU usage / requests per namespace has a value" retry 60 promq_has "$(note_block "$NOTE" 'Requests compared with usage' 1)" "\"namespace\":\"$TEST_NS\""
check "memory usage / requests per namespace has a value" retry 60 promq_has "$(note_block "$NOTE" 'Requests compared with usage' 2)" "\"namespace\":\"$TEST_NS\""
check "OOMKilled: mem-hog is listed" retry 180 promq_has "$(note_block "$NOTE" 'OOMKilled containers' 1)" "\"pod\":\"mem-hog\""
check "OOMKilled and restarting: mem-hog is listed" retry 180 promq_has "$(note_block "$NOTE" 'OOMKilled containers' 2)" "\"pod\":\"mem-hog\""
check "API server p99 latency per verb" retry 60 promq_has "$(note_block "$NOTE" 'API server latency' 1)" '"verb":"(GET|LIST)"'
check_output "API server 5xx ratio is a number" '^\{\} [0-9.e+-]+$|^\{\} NaN$' promq "$(note_block "$NOTE" 'API server latency' 2)"
check "etcd request latency, seen from the API server" retry 60 promq_has "$(note_block "$NOTE" 'etcd basics' 1)" '"operation":"'
check "apiserver_storage_size_bytes" promq_has "$(note_block "$NOTE" 'etcd basics' 2)" '"job":"apiserver"'
for r in node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m \
  node_namespace_pod_container:container_memory_working_set_bytes \
  namespace_cpu:kube_pod_container_resource_requests:sum namespace_memory:kube_pod_container_resource_requests:sum; do
  check "recording rule $r has data" retry 60 promq_has "$r" '.'
done

section "Scrape the control plane on kind and kubeadm"
for j in kube-controller-manager kube-scheduler kube-etcd kube-proxy; do
  check "$j is down by default" retry 120 job_is "$j" down
done
check_output "with connection refused" 'connection refused' \
  bash -c "kubectl get --raw '$PROXY/api/v1/targets?state=active' | jq -r '.data.activeTargets[] | select(.labels.job == \"kube-scheduler\") | .lastError'"
docker exec "$CP" cp -r /etc/kubernetes/manifests /root/metrology-backup
CP_CHANGED=1
check "patch and restart kube-proxy (from the note)" bash -ec "$(note_block "$NOTE" 'An existing kind or kubeadm cluster' 1)"
check "edit the static pod manifests (from the note)" \
  bash -ec "$(note_block "$NOTE" 'An existing kind or kubeadm cluster' 2 | sed "s/^NODE=kind-control-plane/NODE=$CP/")"
for j in kube-controller-manager kube-scheduler kube-etcd kube-proxy; do
  check "$j is up" retry 180 job_is "$j" up
done
check_output "the four jobs, counted (from the note)" '1 kube-controller-manager up.*1 kube-etcd up.*3 kube-proxy up.*1 kube-scheduler up' \
  bash -c "$(note_block "$NOTE" 'An existing kind or kubeadm cluster' 3) | tr -s ' \n' ' '"
check_output "etcd_server_has_leader is 1" ' 1$' promq 'etcd_server_has_leader'
check "etcd WAL fsync p99 has a value" retry 120 promq_has 'histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))' '[0-9]'
check "etcd backend commit p99 has a value" retry 60 promq_has 'histogram_quantile(0.99, rate(etcd_disk_backend_commit_duration_seconds_bucket[5m]))' '[0-9]'
check "etcd_mvcc_db_total_size_in_bytes has a value" promq_has 'etcd_mvcc_db_total_size_in_bytes' ' [1-9][0-9]*$'
check "leader changes over 1h has a value" promq_has 'increase(etcd_server_leader_changes_seen_total[1h])' '[0-9]'
check_output "an anonymous client gets 401 from the scheduler" '401|403' \
  docker exec "$CP" curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:10259/metrics
revert_control_plane
check_output "reverted: the scheduler listens on 127.0.0.1 again" '--bind-address=127.0.0.1' \
  docker exec "$CP" cat /etc/kubernetes/manifests/kube-scheduler.yaml
