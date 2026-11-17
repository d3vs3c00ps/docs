#!/usr/bin/env bash
# note: kubernetes/mlops/bento-hpa.md
# env: kind
# timeout: 1800
# Own cluster (KEDA installs CRDs and an APIService), in the default namespace as in the note.
# A stand-in "ollama" Deployment: scaling does not depend on the image. Bento is not run here.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/mlops/bento-hpa
cd "$(mktemp -d)"
C=notes-keda
kind_cluster "$C"
kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" >/dev/null 2>&1
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
run() { bash -ec "$1" 2>&1; }
export -f retry
replicas() { kubectl get deploy ollama -o jsonpath='{.spec.replicas}'; }
kubectl create deployment ollama --image=busybox:1.37 -- sleep 36000 >/dev/null
kubectl create deployment redis --image=redis:8.4 >/dev/null
kubectl expose deployment redis --port 6379 >/dev/null
kubectl rollout status deploy/redis --timeout=180s >/dev/null

section "HPAv1 in practice"
check_output "--max is required (from the note)" 'required flag\(s\) "max" not set' bash -c "kubectl autoscale deployment ollama 2>&1; true"
check "kubectl autoscale --max=1000 (from the note)" run "$(note_block "$NOTE" 1)"
check_output "kubectl describe hpa: a CPU target of 80% by default (from the note)" 'resource cpu on pods +\(as a percentage of request\): +<unknown> / 80%' run "$(note_block "$NOTE" 2)"
kubectl delete hpa ollama >/dev/null

section "Installing KEDA"
assert_match "the note pins the tested chart" "--version $KEDA_CHART" "$(note_block "$NOTE" 3)"
check "helm upgrade --install keda (from the note)" run "$(note_block "$NOTE" 3) --wait --timeout 10m"
check_output "KEDA serves external metrics, through the aggregation layer" '^v1beta1.external.metrics.k8s.io +keda-system/keda-operator-metrics-apiserver +True' \
  bash -c "retry 120 bash -c \"kubectl get apiservice v1beta1.external.metrics.k8s.io | grep -q True\"; kubectl get apiservice v1beta1.external.metrics.k8s.io --no-headers"

section "Scaling according to Redis"
check "the ScaledObject (from the note)" bash -c "printf '%s\n' \"\$1\" | kubectl apply -f -" _ "$(note_block "$NOTE" 4)"
check "KEDA creates an HPA v2 with an External metric" retry 120 bash -c \
  "kubectl get hpa keda-hpa-ollama -o jsonpath='{.spec.metrics[0].type}' | grep -qx External"
check_output "the target is listLength: 10 messages per replica (the correction)" '"averageValue":"10"' \
  kubectl get hpa keda-hpa-ollama -o jsonpath='{.spec.metrics[0].external.target}'
kubectl exec deploy/redis -- sh -c 'for i in $(seq 35); do redis-cli RPUSH cities "city-$i" >/dev/null; done'
check "35 messages: 4 replicas, messages / 10 rounded up (from the note)" retry 180 bash -c "[ \"\$(kubectl get deploy ollama -o jsonpath='{.spec.replicas}')\" = 4 ]"
check_output "(not messages / 100, as the original said)" '^4$' replicas
kubectl exec deploy/redis -- redis-cli DEL cities >/dev/null
check "an empty list: KEDA scales to zero after the 5 minute cooldown (the correction)" retry 480 bash -c \
  "[ \"\$(kubectl get deploy ollama -o jsonpath='{.spec.replicas}')\" = 0 ]"
