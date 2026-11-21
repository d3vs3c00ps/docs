#!/usr/bin/env bash
# note: kubernetes/observability/goldpinger.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"
use_test_namespace

NOTE=kubernetes/observability/goldpinger
cd "$(mktemp -d)"
P=$((20000 + RANDOM % 20000))
PF=
cleanup() {
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  kubectl delete namespace goldpinger --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete clusterrole,clusterrolebinding goldpinger --ignore-not-found >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
apply() { note_block "$NOTE" "$1" | kubectl apply -f - 2>&1; }
# unhealthy: the note's check_all filter (block 6, first line): the peers someone cannot reach.
UNHEALTHY=$(note_block "$NOTE" 6 | sed -n 1p | sed "s/localhost:8080/localhost:$P/")
unhealthy() { bash -c "$UNHEALTHY"; }
export UNHEALTHY
export -f unhealthy

section "Deploying"
check "kubectl create namespace goldpinger (from the note)" bash -c "$(note_block "$NOTE" 1)"
check "the DaemonSet (from the note)" apply 2
check "the ServiceAccount and RBAC (from the note)" apply 3
check "the Service (from the note)" apply 4
check "it rolls out" kubectl -n goldpinger rollout status ds/goldpinger --timeout=180s
nodes=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
check_output "one pod per node, the tainted control plane too (tolerations: Exists)" "^$nodes\$" \
  kubectl -n goldpinger get ds goldpinger -o jsonpath='{.status.numberReady}'

section "The interface"
bash -c "$(note_block "$NOTE" 5 | sed "s/ 8080:8080/ $P:8080/")" >/dev/null 2>&1 &
PF=$!
retry 60 curl -sf "localhost:$P/healthz"
check "curl localhost:8080/healthz (from the note)" curl -sf "localhost:$P/healthz"
retry 60 bash -c "[ \"\$(curl -s localhost:$P/check_all | jq '.hosts | length')\" = $nodes ]"
check_output "check_all lists every instance" "^$nodes\$" bash -c "curl -s localhost:$P/check_all | jq '.hosts | length'"
# Peers that are still starting refuse connections for a few seconds.
retry 60 bash -c '[ -z "$(unhealthy)" ]' || true
check_output "the note's jq filter: no failing peer on a healthy cluster" '^$' unhealthy

section "Metrics and alerting"
# Pings run on a timer: wait for the first ping results.
retry 90 bash -c "curl -s localhost:$P/metrics | grep -q '^goldpinger_peers_response_time_s_bucket{call_type=\"ping\"'" || true
metrics=$(curl -s "localhost:$P/metrics")
while read -r m; do
  [[ -n $m && $m != goldpinger_errors_total* ]] && assert_match "metric ${m%%\{*} is exported (from the note)" "^${m%%\{*}" "$metrics"
done <<<"$(note_block "$NOTE" 7)"
check_output "the labels on the latency histogram (from the note)" 'call_type="ping",goldpinger_instance=".+",host_ip=".+",pod_ip=".+",le=".+"' \
  bash -c "grep '^goldpinger_peers_response_time_s_bucket{call_type=\"ping\"' <<<\"\$1\" | head -1" _ "$metrics"
printf 'groups:\n- name: goldpinger\n  rules:\n%s\n' "$(note_block "$NOTE" 8 | sed 's/^/  /')" >rules.yaml
check_output "the alert rules are valid (promtool check rules)" 'SUCCESS: 2 rules found' \
  bash -c "docker run --rm -i --entrypoint sh prom/prometheus:$PROMETHEUS_VERSION -c 'cat >/tmp/r.yaml; promtool check rules /tmp/r.yaml' <rules.yaml"

section "NetworkPolicy looks like a network failure"
kubectl -n goldpinger apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny}
spec: {podSelector: {}, policyTypes: [Ingress]}
EOF
check "a default-deny policy: the instances cannot reach each other (the note's filter sees it)" \
  retry 90 bash -c 'unhealthy | grep -qE "^10\.[0-9.]+$"'
retry 90 bash -c "curl -s localhost:$P/metrics | grep -q '^goldpinger_errors_total'" || true
check_output "(and goldpinger_errors_total appears)" '^goldpinger_errors_total\{.*type="ping"' bash -c \
  "curl -s localhost:$P/metrics | grep '^goldpinger_errors_total'"
check "the note's allow-goldpinger policy" apply 9
check "makes the mesh healthy again (from the note)" retry 90 bash -c '[ -z "$(unhealthy)" ]'
