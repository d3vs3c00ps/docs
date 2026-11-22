#!/usr/bin/env bash
# note: kubernetes/concepts/architecture.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/concepts/architecture
CP=$CLUSTER-control-plane
cd "$(mktemp -d)"
# The note's namespace is cluster-wide: use a name of our own, and delete it on exit.
NS=$TEST_NS-hello
own() { sed "s/\bhello\b/$NS/g"; }
_pids=()
_cleanup() {
  kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  ((${#_pids[@]})) && kill "${_pids[@]}" 2>/dev/null
  true
}
_exit() { local rc=$?; _cleanup; (exit "$rc"); _k8s_exit; }
trap '_k8s_rc=$?; _exit' EXIT

section "What runs on a node"
pods=$(bash -ec "$(note_block "$NOTE" 'What runs on a node' 1)")
for n in "$CP" "$CLUSTER-worker" "$CLUSTER-worker2"; do
  assert_match "kube-proxy runs as a Pod on $n (from the note)" "^kube-proxy-.* $n " "$pods"
  check_output "kubelet is a system service on $n" '^active$' docker exec "$n" systemctl is-active kubelet
done
check_output "the container engine is containerd" '^containerd://' kubectl get node "$CP" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}'

section "What's in the control plane"
for c in etcd kube-apiserver kube-controller-manager kube-scheduler; do
  assert_match "$c runs as a Pod in kube-system" "^$c-$CP " "$pods"
done
check_output "only the API server connects to etcd's client port" '^kube-apiserver$' \
  bash -c "docker exec $CP ss -tnp state established '( dport = :2379 )' | grep -o '\"[a-z-]*\"' | tr -d '\"' | sort -u"

section "Communication protocols: API server"
port=$((20000 + RANDOM % 10000))
kubectl proxy --port="$port" >/dev/null 2>&1 &
_pids+=($!)
retry 20 curl -sf "http://127.0.0.1:$port/version" >/dev/null
check_output "the API answers JSON" '"kind": *"Namespace"' curl -s "http://127.0.0.1:$port/api/v1/namespaces/default"
check_output "and protobuf when asked: the k8s magic prefix" '^6b387300' \
  bash -c "curl -s -H 'Accept: application/vnd.kubernetes.protobuf' http://127.0.0.1:$port/api/v1/namespaces/default | head -c 4 | od -An -tx1 | tr -d ' \n'"

section "Communication protocols: on the nodes"
check_output "CNI plugins are programs in /opt/cni/bin" 'ptp|bridge|host-local' docker exec "$CP" ls /opt/cni/bin
check_output "configured by files in /etc/cni/net.d" '\.conflist' docker exec "$CP" ls /etc/cni/net.d
check "kubelet talks to the engine over CRI (crictl uses the same socket)" docker exec "$CP" crictl ps

section "Control plane location"
# On a freshly created cluster the workers may still be joining (taint not-ready).
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
taints=$(bash -ec "$(note_block "$NOTE" 'Control plane location' 1)")
assert_match "the control plane node has the control-plane taint (from the note)" \
  "^$CP +node-role.kubernetes.io/control-plane" "$taints"
assert_match "the workers have none" "^$CLUSTER-worker +<none>" "$taints"

section "Let's experiment a bit!"
check_output "all nodes are Ready (from the note)" '^$' \
  bash -c "$(note_block "$NOTE" "Let's experiment a bit!" 1) --no-headers | awk '\$2 != \"Ready\"'"

section "Create"
check "kubectl create -f- <<EOF (from the note, with our own name)" bash -ec "$(note_block "$NOTE" Create 1 | own)"
check_output "same as kubectl create namespace" '^namespace/.* created \(dry run\)$' \
  kubectl create namespace "$NS-x" --dry-run=client

section "Read"
yaml=$(bash -ec "$(note_block "$NOTE" Read 1 | own)")
assert_match "spec.finalizers was added (from the note)" '^  finalizers:' "$yaml"
assert_match "with the kubernetes finalizer" '^  - kubernetes$' "$yaml"
assert_match "the kubernetes.io/metadata.name label was added" "kubernetes.io/metadata.name: $NS" "$yaml"
assert_match "status is dynamic: phase Active" 'phase: Active' "$yaml"

section "API versions"
versions=$(kubectl api-versions)
assert_match "apps/v1 is served" '^apps/v1$' "$versions"
assert_match "rbac.authorization.k8s.io/v1 is served" '^rbac.authorization.k8s.io/v1$' "$versions"
assert_match "networking.k8s.io/v1 is served" '^networking.k8s.io/v1$' "$versions"
assert_no_match "extensions/v1beta1 is not served any more" '^extensions/' "$versions"
check_output "the batch group has jobs and cronjobs (from the note)" '^cronjobs .*CronJob ?.*jobs .*Job$' \
  bash -c "$(note_block "$NOTE" 'API versions' 1) --no-headers | sort | tr '\n' ' ' | sed 's/ *$//'"

section "Adding a label"
watch_cmd=$(note_block "$NOTE" 'Adding a label' 1)
timeout 20 bash -c "$watch_cmd" >watch.out 2>&1 &
_pids+=($!)
sleep 3
check "kubectl label (from the note)" bash -ec "$(note_block "$NOTE" 'Adding a label' 2 | own)"
check "the watch prints the namespace with its new label (from the note)" \
  retry 15 grep -qE "^$NS +Active .*color=purple" watch.out

section "Watch events"
timeout 60 bash -c "$(note_block "$NOTE" 'Watch events' 1)" >events.out 2>&1 &
_pids+=($!)
sleep 3
run=$(note_block "$NOTE" 'Watch events' 2)
# -ti needs a terminal: script gives it one.
check "kubectl run pause --rm -ti --restart=Never (from the note)" script -qec "$run" /dev/null
check "the watch shows ADDED, MODIFIED and DELETED" \
  retry 15 bash -c 'grep -q "^ADDED .*pause" events.out && grep -q "^MODIFIED .*pause" events.out && grep -q "^DELETED .*pause" events.out'

section "Controller manager"
kubectl create deployment web --image=nginx >/dev/null
check "the Deployment gets a Pod" kubectl wait --for=condition=Available deployment/web --timeout=180s
check_output "the Deployment controller created a ReplicaSet" '^Deployment$' \
  bash -c "kubectl get rs -l app=web -o jsonpath='{.items[0].metadata.ownerReferences[0].kind}'"
check_output "the ReplicaSet controller created the Pod" '^ReplicaSet$' \
  bash -c "kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.ownerReferences[0].kind}'"

section "Scheduler"
kubectl run nowhere --image=nginx --overrides='{"spec":{"nodeSelector":{"no-such":"node"}}}' >/dev/null
check "a Pod with constraints no node meets stays Pending" \
  bash -c "sleep 5; [ \"\$(kubectl get pod nowhere -o jsonpath='{.status.phase}')\" = Pending ]"
check "kubectl describe pod shows FailedScheduling" retry 20 bash -c "kubectl describe pod nowhere | grep -q FailedScheduling"
check_output "it says why: no node matches the selector" "didn't match Pod's node affinity/selector" kubectl describe pod nowhere
