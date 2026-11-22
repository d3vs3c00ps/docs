#!/usr/bin/env bash
# note: kubernetes/observability/prometheus.md
# env: kind
# timeout: 1500
# Own cluster: the chart's node exporter takes host port 9100, like kube-prometheus-stack
# in the metrology tests on the shared cluster.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/observability/prometheus
cd "$(mktemp -d)"
C=notes-prom
kind_cluster "$C"
printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes: [{role: control-plane}, {role: worker}]\n' >kind.yaml
out=$(kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" --config kind.yaml 2>&1) || { echo "$out"; kind_diag; exit 1; }
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
run() { bash -ec "$1" 2>&1; }
PROMPORT=$((20000 + RANDOM % 20000))
# promql QUERY: one "labels value" line per series.
promql() {
  curl -s "localhost:$PROMPORT/api/v1/query" --data-urlencode "query=$1" |
    jq -r '.data.result[] | "\(.metric | tostring) \(.value[1])"'
}
# promtool_config YAML: promtool check config, in the Prometheus image.
promtool_config() {
  docker run --rm -i --entrypoint sh "prom/prometheus:$PROMETHEUS_VERSION" \
    -c 'cat >/tmp/p.yml; promtool check config --syntax-only /tmp/p.yml' <<<"$1" 2>&1
}

section "Defining scrape targets"
check_output "the simplest configuration is valid (from the note)" 'SUCCESS' promtool_config "$(note_block "$NOTE" 1)"
check_output "the DNS service discovery job is valid (from the note, without its '- ...' line)" 'SUCCESS' \
  promtool_config "$(note_block "$NOTE" 2 | grep -v '^  - \.\.\.$')"

section "Installing Prometheus"
check_output "the get-helm-4 script exists (Helm is already in the runner)" '^200$' \
  curl -s -o /dev/null -w '%{http_code}' "$(note_block "$NOTE" 4 | grep -o 'https://[^ ]*')"
assert_match "the note pins the tested chart" "--version $PROMETHEUS_CHART" "$(note_block "$NOTE" 5)"
check "helm upgrade --install (from the note)" run "$(note_block "$NOTE" 5) --wait --timeout 10m"
check "and again: it is idempotent (from the note)" run "$(note_block "$NOTE" 5) --wait --timeout 10m"
check_output "kubectl get svc | grep prometheus-server: NodePort 30090 (from the note)" 'prometheus-server +NodePort .*80:30090/TCP' \
  run "$(note_block "$NOTE" 6)"
sel=$(run "$(note_block "$NOTE" 3)")
check_output "the note's check finds the prometheus-server Service" '^prometheus +prometheus-server +NodePort' echo "$sel"
check_output "(the original selector, app=prometheus, finds nothing with this chart: the correction)" '^No resources found' \
  bash -c "kubectl get svc -A --selector=app=prometheus 2>&1"
check_output "scrape every minute by default (from the note)" 'scrape_interval: 1m' \
  kubectl -n prometheus get configmap prometheus-server -o jsonpath='{.data.prometheus\.yml}'

section "Querying some metrics"
kubectl create deployment worker --image=busybox:1.37 --replicas=2 -- sh -c 'while :; do :; done' >/dev/null
kubectl set resources deployment worker --limits=cpu=100m >/dev/null
kubectl rollout status deploy/worker --timeout=180s >/dev/null
kubectl -n prometheus port-forward svc/prometheus-server "$PROMPORT:80" >/dev/null 2>&1 &
trap '_k8s_rc=$?; kill %1 2>/dev/null || true; _k8s_exit' EXIT
q=$(note_block "$NOTE" 7 | tr -s ' \n' ' ')
retry 300 bash -c "curl -s localhost:$PROMPORT/api/v1/query --data-urlencode 'query=$q' | jq -e '.data.result | length > 0' >/dev/null"
check_output "the note's query: CPU of worker pods, per instance" '^\{"instance":"notes-prom-worker"\} 0\.[0-9]' promql "$q"
check_output "container_cpu_usage_seconds_total has tags (from the note)" '"container":"busybox".*"pod":"worker-' \
  promql "$(note_block "$NOTE" 9)"
check_output "100*irate(...) is a CPU % (about 10% with the 100m limit)" ' ([5-9]|1[0-9])(\.[0-9]+)?$' promql "$(note_block "$NOTE" 10)"
check_output "instance is the node the container runs on (from the note)" '^\{"instance":"notes-prom-worker"\}' \
  promql "$(note_block "$NOTE" 11)"

section "Querying labels"
sleep 90
check_output "with no labels allowlisted, kube-state-metrics has no kube_pod_labels (the correction)" '^$' bash -c \
  "curl -s localhost:$PROMPORT/api/v1/label/__name__/values | jq -r '.data[]' | grep -x kube_pod_labels || true"
check "allowlist the pod labels, as in the correction" run \
  "$(note_block "$NOTE" 5) --reuse-values --set 'kube-state-metrics.metricLabelsAllowlist[0]=pods=[*]' --wait --timeout 10m"
retry 300 bash -c "curl -s localhost:$PROMPORT/api/v1/query --data-urlencode 'query=kube_pod_labels{pod=~\"worker.*\"}' | jq -e '.data.result | length > 0' >/dev/null"
check_output "now kube_pod_labels exists, one series per pod with value 1 (from the note)" '"pod":"worker-.* 1$' \
  promql 'kube_pod_labels{pod=~"worker.*"}'
check_output "with the pod labels as label_* tags" '"label_app":"worker"' promql 'kube_pod_labels{pod=~"worker.*"}'
check_output "Services annotated prometheus.io/scrape are scraped (kubernetes-service-endpoints job)" '"job":"kubernetes-service-endpoints"' \
  promql 'up{job="kubernetes-service-endpoints"}'
