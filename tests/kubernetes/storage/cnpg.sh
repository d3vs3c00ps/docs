#!/usr/bin/env bash
# note: kubernetes/storage/cnpg.md
# env: kind
# timeout: 1500
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/storage/cnpg
use_test_namespace
HOME=$(mktemp -d)
export HOME
BIN=$(mktemp -d)
export PATH=$BIN:$PATH
cd "$HOME"
CORDONED=
cleanup() {
  [[ -n $CORDONED ]] && kubectl uncordon "$CORDONED" >/dev/null 2>&1
  kubectl delete cluster.postgresql.cnpg.io --all --wait=true --timeout=120s >/dev/null 2>&1 || true
  helm uninstall cloudnative-pg -n cnpg-system --wait >/dev/null 2>&1 || true
  kubectl get crd -o name | grep 'cnpg\.io' | xargs -r kubectl delete >/dev/null 2>&1 || true
  kubectl delete namespace cnpg-system --ignore-not-found --wait=false >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
run() { bash -ec "$1" 2>&1; }
primary() { kubectl get cluster.postgresql.cnpg.io minimal -o jsonpath='{.status.currentPrimary}'; }
healthy() { kubectl wait --for=condition=Ready cluster.postgresql.cnpg.io/minimal --timeout="${1:-600}s" >/dev/null; }

section "CNPG installation"
assert_match "the note pins the chart version the tests use" "--version $CNPG_CHART" "$(note_block "$NOTE" 1)"
check "the note's helm command" run "$(note_block "$NOTE" 1)"
check "the operator runs" kubectl -n cnpg-system rollout status deploy/cloudnative-pg --timeout=300s
check_output "chart $CNPG_CHART installs operator $CNPG_VERSION" ":$CNPG_VERSION\$" \
  kubectl -n cnpg-system get deploy cloudnative-pg -o jsonpath='{.spec.template.spec.containers[0].image}'
check_output "the old --version 1.25.1 is not a chart version (the correction)" 'not found' bash -c \
  'helm show chart --repo https://cloudnative-pg.io/charts/ cloudnative-pg --version 1.25.1 2>&1 || true'
# The Prometheus Operator options are real values of the chart (rendered only, no Prometheus here).
opts=$(note_block "$NOTE" 2 | tr '\n' ' ')
check_output "the monitoring options render a PodMonitor and a dashboard ConfigMap" 'kind: PodMonitor' \
  bash -c "helm template x --repo https://cloudnative-pg.io/charts/ cloudnative-pg --version $CNPG_CHART $opts"
check_output "(the dashboard goes to prom-system)" 'namespace: prom-system' \
  bash -c "helm template x --repo https://cloudnative-pg.io/charts/ cloudnative-pg --version $CNPG_CHART $opts"

section "Minimal Postgres cluster"
retry 60 bash -c "kubectl -n cnpg-system get endpointslices -l kubernetes.io/service-name=cnpg-webhook-service -o jsonpath='{..addresses[0]}' | grep -q ."
note_block "$NOTE" 3 >minimal.yaml
check "create the note's minimal cluster" kubectl apply -f minimal.yaml
check "it becomes healthy" healthy 900
check_output "2 instances: a primary and a replica" '^minimal-1 minimal-2$' \
  bash -c "kubectl get pods -l cnpg.io/cluster=minimal -o jsonpath='{.items[*].metadata.name}' | xargs -n1 | sort | xargs"
check_output "each with a 10G volume" '^10G 10G$' \
  kubectl get pvc -l cnpg.io/cluster=minimal -o jsonpath='{.items[*].spec.resources.requests.storage}'

section "kubectl plugin"
arch=$(uname -m)
[[ $arch == aarch64 ]] && arch=arm64
check "install kubectl-cnpg from the release assets" bash -ec \
  "curl -fsSL https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v$CNPG_VERSION/kubectl-cnpg_${CNPG_VERSION}_linux_$arch.tar.gz | tar -xz -C $BIN kubectl-cnpg"
check_output "k cnpg status" 'Primary instance: +minimal-1' kubectl cnpg status minimal
check_output "k cnpg psql" '^ *1$' kubectl cnpg psql minimal -- -tAc 'select 1'

section "Benchmarking"
bench=$(sed -n 's/^  `\(kubectl exec minimal-1 -- pgbench [^`]*\)`$/\1/p' "$NOTES_ROOT/content/$NOTE.md")
check_output "the note has the two commands" '^2$' bash -c "wc -l <<<'$bench' | tr -d ' '"
check "step 1: pgbench -i -s 10 in the primary (from the note)" run "$(sed -n 1p <<<"$bench")"
check_output "step 2: the benchmark reports progress every second (from the note)" 'progress: 10\.0 s' \
  run "$(sed -n 2p <<<"$bench")"
check_output "and gives transactions per second" '^tps = [0-9.]+' run "$(sed -n 2p <<<"$bench" | sed 's/-T60/-T5/')"

section "Automated switchover"
check_output "a PodDisruptionBudget protects the primary" 'minimal-primary' kubectl get pdb -o name
CORDONED=$(kubectl get pod minimal-1 -o jsonpath='{.spec.nodeName}')
other=$(kubectl get pod minimal-2 -o jsonpath='{.spec.nodeName}')
if [[ $CORDONED == "$other" ]]; then
  skip "cordon = maintenance: switchover" "both instances landed on $CORDONED; the replica would be on the cordoned node too"
else
  kubectl cordon "$CORDONED" >/dev/null
  retry 300 bash -c "[ \"\$(kubectl get cluster.postgresql.cnpg.io minimal -o jsonpath='{.status.currentPrimary}')\" = minimal-2 ]" || true
  check_output "cordoning the primary's node makes CNPG switch over to the replica" '^minimal-2$' primary
  kubectl uncordon "$CORDONED" >/dev/null
  CORDONED=
fi
healthy 600 || true
check "k cnpg promote: back to minimal-1" kubectl cnpg promote minimal minimal-1
retry 300 bash -c "[ \"\$(kubectl get cluster.postgresql.cnpg.io minimal -o jsonpath='{.status.currentPrimary}')\" = minimal-1 ]" || true
check_output "(minimal-1 is primary again)" '^minimal-1$' primary

section "Production clusters, backups (CNPG lab 2)"
skip "cluster-production.yaml, k cnpg backup" "need an S3-compatible object store"
