#!/usr/bin/env bash
# note: kubernetes/my-notes/architecture.md
# env: kind
# timeout: 600
# The note's hello-world namespace is cluster-wide: it gets a unique name, deleted on exit.
# The two-terminal steps run the watch in the background. kubectl run -ti becomes -i.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/my-notes/architecture
HW=hello-world-$RANDOM
cd "$(mktemp -d)"
cleanup() {
  kubectl delete namespace "$HW" --ignore-not-found --wait=false >/dev/null 2>&1
  jobs -p | xargs -r kill 2>/dev/null
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
# run BLOCK: with the unique namespace name, and without a terminal.
run() { local b=${1//hello-world/$HW}; bash -ec "${b// -ti / -i }" 2>&1 </dev/null; }

section "Creating an object"
check "kubectl create -f- with a Namespace (from the note)" run "$(note_block "$NOTE" 1)"
kubectl delete namespace "$HW" --wait=true >/dev/null
check "kubectl create namespace (from the note)" run "$(note_block "$NOTE" 2)"

section "Reading it back"
check_output "kubectl get namespace: Active (from the note)" "^$HW +Active " kubectl get namespace "$HW"
yaml=$(kubectl get namespace "$HW" -o yaml)
check_output "spec.finalizers is added automatically (from the note)" '^  - kubernetes$' echo "$yaml"
check_output "so is the kubernetes.io/metadata.name label (from the note)" "kubernetes.io/metadata.name: $HW" echo "$yaml"
check_output "status is dynamic: phase Active (from the note)" '^  phase: Active$' echo "$yaml"

section "API versions"
versions=$(kubectl api-versions)
for v in v1 apps/v1 rbac.authorization.k8s.io/v1 networking.k8s.io/v1; do
  check_output "$v is served (from the note)" "^$v$" echo "$versions"
done
check_output "extensions/v1beta1 is not served any more (the note's remark)" '^$' bash -c "grep -x 'extensions/v1beta1' <<<\"\$1\" || true" _ "$versions"

section "Adding a label"
run "$(note_block "$NOTE" 6)" >watch.log &
sleep 3
check "kubectl label namespaces ... color=red (from the note)" run "$(note_block "$NOTE" 7)"
check_output "the watch shows the change appear (from the note)" "^$HW +Active .*color=red,kubernetes.io/metadata.name=$HW" \
  bash -c "sleep 3; cat watch.log"

section "Watching events"
run "$(note_block "$NOTE" 9)" >events.log &
sleep 3
check "a short-lived pod (from the note)" run "$(note_block "$NOTE" 10)"
sleep 3
check_output "the watch shows ADDED, MODIFIED, then DELETED (from the note)" 'ADDED +pause .*MODIFIED +pause .*DELETED +pause ' \
  bash -c "tr '\n' ' ' <events.log"
check_output "with Running and Completed along the way (from the note)" 'MODIFIED +pause +1/1 +Running .*MODIFIED +pause +0/1 +Completed' \
  bash -c "tr '\n' ' ' <events.log"

section "kube-controller-manager"
kubectl create deployment web --image=nginx:1.29 >/dev/null
kubectl rollout status deploy/web --timeout=180s >/dev/null
check_output "the Deployment controller creates a ReplicaSet (from the note)" '^Deployment/web$' bash -c \
  "kubectl get rs -l app=web -o jsonpath='{.items[0].metadata.ownerReferences[0].kind}/{.items[0].metadata.ownerReferences[0].name}'"
check_output "and the ReplicaSet controller creates the Pod (from the note)" '^ReplicaSet/web-' bash -c \
  "kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.ownerReferences[0].kind}/{.items[0].metadata.ownerReferences[0].name}'"
check_output "the scheduler binds it to a node (from the note)" 'Successfully assigned .*/web-.* to ' bash -c \
  "kubectl get events --field-selector reason=Scheduled -o jsonpath='{.items[*].message}'"

section "kube-scheduler"
check_output "110 pods per node by default (the kubelet's maxPods; the note's RKE2 value)" '^110$' \
  kubectl get nodes -o jsonpath='{.items[0].status.capacity.pods}'
check_output "the scheduler is a pod of its own on kubeadm clusters" '^kube-scheduler-' bash -c \
  "kubectl -n kube-system get pods -l component=kube-scheduler -o name | cut -d/ -f2"
