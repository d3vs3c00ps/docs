#!/usr/bin/env bash
# note: kubernetes/mlops/ollama-reqlim.md
# env: kind
# timeout: 300
# A stand-in "ollama" Deployment (busybox, with a sidecar): the commands do not depend on
# the image. kubectl top and the cluster autoscaler status are not tested here.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/mlops/ollama-reqlim
run() { bash -ec "$1" 2>&1; }

section "In practice"
cores=$(kubectl get nodes -o jsonpath='{.items[0].status.capacity.cpu}')
out=$(run "$(note_block "$NOTE" 2)")
check_output "jq .items[].status.capacity.cpu: one quoted number per node (from the note)" "^\"$cores\"$" bash -c "head -1 <<<\"\$1\"" _ "$out"
check_output "custom-columns NAME and CPU (from the note)" "^NAME +CPU$" bash -c "grep -m1 '^NAME' <<<\"\$1\"" _ "$out"

section "Setting resources for Ollama"
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: ollama}
spec:
  selector: {matchLabels: {app: ollama}}
  template:
    metadata: {labels: {app: ollama}}
    spec:
      containers:
      - {name: ollama, image: busybox:1.37, command: [sleep, "3600"]}
      - {name: haproxy, image: busybox:1.37, command: [sleep, "3600"]}
EOF
check "kubectl set resources (from the note)" run "$(note_block "$NOTE" 3)"
check_output "the ollama container gets the requests and limits (from the note)" \
  '^\{"limits":\{"cpu":"3","memory":"2G"\},"requests":\{"cpu":"1500m","memory":"2G"\}\}$' \
  kubectl get deploy ollama -o jsonpath='{.spec.template.spec.containers[0].resources}'
check_output "and so does the sidecar (the note's warning)" '"cpu":"1500m"' \
  kubectl get deploy ollama -o jsonpath='{.spec.template.spec.containers[1].resources}'
check "-c NAME limits the change to one container" \
  kubectl set resources deployment ollama -c haproxy --requests=cpu=10m,memory=16Mi --limits=cpu=100m,memory=16Mi
check_output "(Burstable QoS: CPU requests and limits differ)" '^Burstable$' bash -c \
  "kubectl rollout status deploy/ollama --timeout=5s >/dev/null 2>&1; kubectl get pods -l app=ollama --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].status.qosClass}'"
