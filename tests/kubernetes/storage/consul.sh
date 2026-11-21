#!/usr/bin/env bash
# note: kubernetes/storage/consul.md
# env: kind
# timeout: 1800
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/storage/consul
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
HOME=$(mktemp -d)
export HOME
cd "$HOME"
mkdir -p container.training/k8s
for f in consul-1 consul-2; do curl -fsSL "$UPSTREAM/k8s/$f.yaml" >"container.training/k8s/$f.yaml"; done
# The anti-affinity of consul-2 needs 3 nodes that take pods: own cluster, 3 workers.
C=notes-consul
kind_cluster "$C"
printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes: [{role: control-plane}, {role: worker}, {role: worker}, {role: worker}]\n' >kind.yaml
out=$(kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" --config kind.yaml 2>&1) || { echo "$out"; kind_diag; exit 1; }
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
run() { bash -ec "$1" 2>&1; }
members_alive() { kubectl exec consul-0 -- consul members 2>/dev/null | grep -c ' alive '; }
# retry_get POD: the value of the key answer, read from POD, once it can be read.
retry_get() {
  local i
  for i in $(seq 1 60); do kubectl exec "$1" -- consul kv get answer 2>/dev/null && return 0; sleep 2; done
  kubectl exec "$1" -- consul kv get answer
}
wait_members() { retry 300 bash -c "[ \$(kubectl exec consul-0 -- consul members 2>/dev/null | grep -c ' alive ') -eq $1 ]"; }

section "Running our Consul cluster"
check "apply consul-1.yaml (from the note)" run "$(note_block "$NOTE" 4)"
check "the 3 pods come up, one after another" kubectl rollout status statefulset/consul --timeout=600s
wait_members 3 || true
check_output "consul members: 3 alive servers, found through Cloud Auto-join (from the note)" \
  'consul-2 .* alive +server' run "$(note_block "$NOTE" 6)"
assert_eq "(3 of them)" 3 "$(members_alive)"
check_output "the retry-join uses the k8s provider, as the note says" 'provider=k8s label_selector=\\"app=consul\\"' \
  kubectl get statefulset consul -o jsonpath='{.spec.template.spec.containers[0].args}'
check_output "it uses a service account that can list pods" '^consul$' \
  kubectl get statefulset consul -o jsonpath='{.spec.template.spec.serviceAccountName}'
check_output "the pod's service account may list pods" '^yes$' kubectl auth can-i list pods --as system:serviceaccount:default:consul

section "Caveats: scaling down breaks consul-1"
kubectl exec consul-0 -- consul kv put answer 42 >/dev/null
kubectl scale statefulset consul --replicas=1 >/dev/null
retry 120 bash -c '[ $(kubectl get pods -l app=consul --no-headers | wc -l) -eq 1 ]'
sleep 20
check_output "the last node has no quorum: no leader" 'No cluster leader|Unexpected response code: 500' \
  bash -c 'kubectl exec consul-0 -- consul kv get answer 2>&1 || true'
kubectl delete -f container.training/k8s/consul-1.yaml --wait=true >/dev/null
kubectl wait --for=delete pod -l app=consul --timeout=180s >/dev/null 2>&1 || true

section "Improving pod placement, using a lifecycle hook"
c2=$(cat container.training/k8s/consul-2.yaml)
for n in 7 9; do
  while read -r l; do
    [[ -z $l ]] && continue
    assert_match "consul-2.yaml has the note's line: $l" "$(printf '%s' "$l" | sed 's/[][\.*^$]/\\&/g')" "$c2"
  done <<<"$(note_block "$NOTE" "$n")"
done
check "deploy consul-2.yaml (from the note)" run "$(note_block "$NOTE" 10)"
check "the 3 pods come up" kubectl rollout status statefulset/consul --timeout=600s
wait_members 3 || true
assert_eq "3 alive members" 3 "$(members_alive)"
check_output "the pods are on 3 different nodes" '^3$' \
  bash -c "kubectl get pods -l app=consul -o jsonpath='{range .items[*]}{.spec.nodeName}{\"\\n\"}{end}' | sort -u | wc -l"

section "Still no persistence, though"
kubectl exec consul-0 -- consul kv put answer 42 >/dev/null
kubectl delete pod consul-1 >/dev/null
# The StatefulSet creates the new consul-1 a moment later: wait for it to exist first.
retry 120 kubectl get pod consul-1 >/dev/null
kubectl wait --for=condition=Ready pod/consul-1 --timeout=300s >/dev/null
wait_members 3 || true
check_output "a lost pod comes back empty, rejoins, and gets the data from the others" '^42$' \
  retry_get consul-1

section "consul-2 survives a scale-down (thanks to the lifecycle hook)"
# The recreated consul-1 has a new node ID: wait until autopilot drops the old Raft peer,
# or the leaves below leave the last server without a quorum.
retry 180 bash -c "[ \$(kubectl exec consul-0 -- consul operator raft list-peers 2>/dev/null | tail -n +2 | grep -c .) -eq 3 ]" || true
kubectl scale statefulset consul --replicas=1 >/dev/null
retry 180 bash -c '[ $(kubectl get pods -l app=consul --no-headers | wc -l) -eq 1 ]'
sleep 20
check_output "the leaving members ran consul leave: the last one still answers" '^42$' retry_get consul-0
