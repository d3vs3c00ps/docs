#!/usr/bin/env bash
# note: kubernetes/observability/metrics-server.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/observability/metrics-server
cd "$(mktemp -d)"
# Own cluster: the shared one may already serve the Metrics API.
C=notes-ms
kind_cluster "$C"
kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" >/dev/null 2>&1
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
run() { bash -ec "$1" 2>&1; }

section "Is metrics-server installed?"
check_output "not yet: 'Metrics API not available' (from the note)" 'Metrics API not available' \
  bash -c "$(note_block "$NOTE" 1) 2>&1; true"

section "Installing metrics-server"
assert_match "the note pins the tested chart" "--version $METRICS_SERVER_CHART" "$(note_block "$NOTE" 2)"
check "the note's helm command" run "$(note_block "$NOTE" 2) --wait --timeout 5m"
check_output "it runs a single Pod (from the note)" '^1$' \
  kubectl -n metrics-server get deploy metrics-server -o jsonpath='{.spec.replicas}'
check_output "served through the aggregation layer (from the note)" '^metrics-server/metrics-server$' \
  kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.spec.service.namespace}/{.spec.service.name}'
check_output "the --kubelet-insecure-tls arg is set" 'kubelet-insecure-tls=true' \
  kubectl -n metrics-server get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}'

section "Testing metrics-server"
retry 120 bash -c "kubectl top nodes >/dev/null 2>&1"
check_output "kubectl top nodes: CPU and memory per node (from the note)" "^$C-control-plane +[0-9]+m +[0-9]+% +[0-9]+Mi +[0-9]+%" \
  run "$(note_block "$NOTE" 3)"
retry 60 bash -c "kubectl top pods -A 2>/dev/null | grep -q coredns"
check_output "kubectl top pods --all-namespaces (from the note)" '^kube-system +coredns-\S+ +[0-9]+m +[0-9]+Mi' \
  run "$(note_block "$NOTE" 4)"
check_output "only CPU and RAM (from the note's cons)" '^NAME +CPU\(cores\) +CPU\(%\) +MEMORY\(bytes\) +MEMORY\(%\) *$' \
  bash -c "kubectl top nodes | head -1"
