#!/usr/bin/env bash
# note: kubernetes/observability/cluster-autoscaler.md
# env: kind
# timeout: 900
# kind has no cluster autoscaler: the lab runs up to the Pending Pod. Own one-node
# cluster, because the lab fills all its CPUs on purpose.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/observability/cluster-autoscaler
cd "$(mktemp -d)"
C=notes-ca
kind_cluster "$C"
kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" >/dev/null 2>&1
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
run() { bash -ec "$1" 2>&1; }

section "Checking available resources"
alloc=$(run "$(note_block "$NOTE" 1)")
check_output "allocatable CPU per node (from the note)" '^[0-9]+m?$' echo "$alloc"
cores=${alloc%m}
[[ $alloc == *m ]] && cores=$((cores / 1000))
# "Adjust the numbers if necessary": one more 1-CPU pod than the node has cores.
N=$((cores + 1))

section "Creating our test Deployment"
check "kubectl create deployment blue (from the note)" run "$(note_block "$NOTE" 2)"
check_output "(its container is named color, as the patch expects)" '^color$' \
  kubectl get deploy blue -o jsonpath='{.spec.template.spec.containers[0].name}'
check "the note's patch: a request for 1 CPU" run "$(note_block "$NOTE" 3)"
check_output "(requests.cpu is 1)" '^1$' kubectl get deploy blue -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}'

# The patch starts a rollout: scaling during it mixes two ReplicaSets and makes the counts racy.
kubectl rollout status deploy/blue --timeout=180s >/dev/null
section "Scaling up in practice"
check "kubectl scale deployment blue (from the note, with $N replicas instead of 7)" \
  run "$(note_block "$NOTE" 4 | sed "s/--replicas=7/--replicas=$N/")"
# phase=Pending includes ContainerCreating pods: wait for the STATUS column, which means unscheduled.
retry 120 bash -c "kubectl get pods -l app=blue --no-headers 2>/dev/null | grep -Eq '^blue-\S+ +0/1 +Pending '"
check_output "more than the node can fit: some Pods are Pending (from the note)" '^blue-\S+ +0/1 +Pending' run "$(note_block "$NOTE" 5)"
why() { kubectl get pods -l app=blue -o jsonpath='{.items[*].status.conditions[?(@.type=="PodScheduled")].message}'; }
retry 60 bash -c "$(declare -f why); why | grep -q 'Insufficient cpu'" || true
check_output "(the scheduler says why: Insufficient cpu)" 'Insufficient cpu' why
skip "a new Node appears and the Pod runs; scale down; cluster-autoscaler-status" "kind has no cluster autoscaler"
