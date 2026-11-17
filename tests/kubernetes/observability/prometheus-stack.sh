#!/usr/bin/env bash
# note: kubernetes/observability/prometheus-stack.md
# env: kind
# timeout: 1500
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"
use_test_namespace

NOTE=kubernetes/observability/prometheus-stack
NS=kube-prometheus-stack
cd "$(mktemp -d)"
GPORT=$((20000 + RANDOM % 20000))
PF=
cleanup() {
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  helm uninstall kube-prometheus-stack -n "$NS" --wait >/dev/null 2>&1 || true
  kubectl -n kube-system delete service kube-prometheus-stack-kubelet --ignore-not-found >/dev/null 2>&1 || true
  kubectl get crd -o name | grep monitoring.coreos.com | xargs -r kubectl delete >/dev/null 2>&1 || true
  kubectl delete namespace "$NS" --ignore-not-found >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
run() { bash -ec "$1" 2>&1; }

section "Installing kube-prometheus-stack"
assert_match "the note pins the tested chart" "--version $KUBE_PROMETHEUS_STACK_CHART" "$(note_block "$NOTE" 1)"
check "helm upgrade --install from the repo URL (from the note)" run "$(note_block "$NOTE" 1) --wait --timeout 10m"
all=$(run "$(note_block "$NOTE" 2)")
for o in deployment.apps/kube-prometheus-stack-grafana deployment.apps/kube-prometheus-stack-operator \
  statefulset.apps/prometheus-kube-prometheus-stack-prometheus daemonset.apps/kube-prometheus-stack-prometheus-node-exporter; do
  assert_match "kubectl get all shows $o (from the note)" "^$o " "$all"
done

section "Exposing Grafana"
check_output "the Ingress command is valid (client dry run; no domain here)" \
  'ingress.networking.k8s.io/grafana created \(dry run\)' run "$(note_block "$NOTE" 3) --dry-run=client"
check_output "(host and backend from the note)" 'grafana.example.com.*kube-prometheus-stack-grafana' bash -c \
  "$(note_block "$NOTE" 3) --dry-run=client -o jsonpath='{.spec.rules[0].host} {.spec.rules[0].http.paths[0].backend.service.name}'"

section "Exposing Grafana without Ingress"
check "the answer: --set grafana.service.type=NodePort" run "$(note_block "$NOTE" 4) --wait --timeout 5m"
check_output "the Service is a NodePort now" '^NodePort$' kubectl -n "$NS" get svc kube-prometheus-stack-grafana -o jsonpath='{.spec.type}'

section "Grafana credentials"
check_output "the Secret is there (from the note)" '^kube-prometheus-stack-grafana ' run "$(note_block "$NOTE" 5)"
creds=$(run "$(note_block "$NOTE" 6)")
check_output "jq decodes it: admin-user is admin (from the note)" '"admin-user": "admin"' echo "$creds"
pw=$(jq -r '."admin-password"' <<<"$creds")
check_output "the password is random, not prom-operator (the correction)" '^.{20,}$' echo "$pw"
kubectl -n "$NS" port-forward svc/kube-prometheus-stack-grafana "$GPORT:80" >/dev/null 2>&1 &
PF=$!
retry 60 curl -sf "localhost:$GPORT/api/health"
check_output "admin/prom-operator is refused" '^401$' \
  curl -s -o /dev/null -w '%{http_code}' -u admin:prom-operator "localhost:$GPORT/api/search"
check_output "admin and the Secret's password work" '^200$' \
  curl -s -o /dev/null -w '%{http_code}' -u "admin:$pw" "localhost:$GPORT/api/search"

section "Grafana dashboards"
check_output "Kubernetes / Compute Resources / Cluster exists (from the note)" '^Kubernetes / Compute Resources / Cluster$' \
  bash -c "curl -s -u 'admin:$pw' 'localhost:$GPORT/api/search?type=dash-db' | jq -r '.[].title'"
