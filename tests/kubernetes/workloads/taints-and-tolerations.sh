#!/usr/bin/env bash
# note: kubernetes/workloads/taints-and-tolerations.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/taints-and-tolerations
cd "$(mktemp -d)"
# Other tests share this cluster: taint one worker only, with a key of our own, never
# NoExecute (it would evict their Pods), and remove everything on exit.
node=$CLUSTER-worker2
key=notes.example.com/$TEST_NS
cleanup() {
  local rc=$?
  kubectl taint node "$node" "$key-" >/dev/null 2>&1 || true
  kubectl uncordon "$node" >/dev/null 2>&1 || true
  _k8s_stop_cpk
  _k8s_cleanup
  _t_finish "$rc"
}
trap cleanup EXIT

# pod NAME [TOLERATIONS-JSON]: a pause Pod that may only run on $node.
pod() {
  kubectl apply -f - >/dev/null <<EOF
{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "$1"},
 "spec": {"nodeSelector": {"kubernetes.io/hostname": "$node"}, "tolerations": ${2:-[]},
          "containers": [{"name": "pause", "image": "registry.k8s.io/pause:3.10"}]}}
EOF
}
runs() { kubectl wait --for=condition=Ready "pod/$1" --timeout=90s; }
# blocked POD: the scheduler refuses it because of a taint.
blocked() {
  retry 30 bash -c "kubectl get pod $1 -o jsonpath='{.status.conditions[?(@.type==\"PodScheduled\")].message}' | grep -q 'untolerated taint'"
}

section "Taints and tolerations"
check_output "kubeadm taints the control plane node" 'node-role.kubernetes.io/control-plane:NoSchedule' \
  kubectl describe node "$CLUSTER-control-plane"
check_output "CoreDNS tolerates it" '"key":"node-role.kubernetes.io/control-plane"' \
  kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[0].spec.tolerations}'
check_output "the API server is a static Pod (owned by the Node, not scheduled)" '^Node$' \
  kubectl -n kube-system get pod "kube-apiserver-$CLUSTER-control-plane" -o jsonpath='{.metadata.ownerReferences[0].kind}'

section "Checking taints on our nodes"
blk=$(note_block "$NOTE" 'Checking taints on our nodes' 1)
check_output "kubectl describe nodes | grep ^Taints (from the note)" '^Taints: +node-role.kubernetes.io/control-plane:NoSchedule' bash -ec "$(sed -n 1p <<<"$blk")"
check_output "custom-columns (from the note)" "$CLUSTER-control-plane +\[map\[effect:NoSchedule key:node-role.kubernetes.io/control-plane\]\]" bash -ec "$(sed -n 3p <<<"$blk")"
check_output "jq (from the note)" '"node-role.kubernetes.io/control-plane"' bash -ec "$(sed -n 5p <<<"$blk")"
check_output "the workers have no taints" "$CLUSTER-worker +<none>" bash -ec "$(sed -n 3p <<<"$blk")"

section "Taint structure"
ex=$(kubectl explain node.spec.taints)
assert_match "effect is required" 'effect\s+<string> -required-' "$ex"
assert_match "key is required" 'key\s+<string> -required-' "$ex"
assert_match "value is optional" 'value\s+<string>$' "$ex"
assert_match "and timeAdded" 'timeAdded\s+<string>' "$ex"
check_fails "a taint with no effect is refused" kubectl taint node "$node" "$key=x"

section "Taint effect: NoSchedule"
pod before
check "a Pod runs on the node before the taint" runs before
check "kubectl taint node NAME key=val:NoSchedule" kubectl taint node "$node" "$key=v:NoSchedule"
pod after
check "a new Pod without toleration is not scheduled there" blocked after
check_output "the existing Pod is not affected" '^Running$' kubectl get pod before -o jsonpath='{.status.phase}'

section "Toleration operator and value"
pod equal "[{\"key\": \"$key\", \"operator\": \"Equal\", \"value\": \"v\", \"effect\": \"NoSchedule\"}]"
check "Equal with the same key and value tolerates it" runs equal
pod default-op "[{\"key\": \"$key\", \"value\": \"v\"}]"
check "Equal is the default operator" runs default-op
check_output "(the stored operator stays empty)" '^$' kubectl get pod default-op -o jsonpath='{.spec.tolerations[0].operator}'
pod wrong-value "[{\"key\": \"$key\", \"operator\": \"Equal\", \"value\": \"w\"}]"
check "Equal with another value does not" blocked wrong-value
pod exists "[{\"key\": \"$key\", \"operator\": \"Exists\"}]"
check "Exists ignores the value" runs exists
pod any "[{\"operator\": \"Exists\"}]"
check "Exists with no key matches every taint" runs any

section "Toleration effect"
pod no-effect "[{\"key\": \"$key\", \"operator\": \"Exists\"}]"
check "no effect: any effect matches" runs no-effect
pod other-effect "[{\"key\": \"$key\", \"operator\": \"Exists\", \"effect\": \"PreferNoSchedule\"}]"
check "another effect does not match" blocked other-effect

section "Toleration key"
check_output "no key needs the Exists operator" 'operator must be Exists when `key` is empty' \
  bash -c "kubectl run x --image=registry.k8s.io/pause:3.10 --dry-run=server --overrides='{\"spec\": {\"tolerations\": [{\"value\": \"v\"}]}}' 2>&1; true"

section "Toleration structure"
ex=$(kubectl explain pod.spec.tolerations)
for f in effect key operator value tolerationSeconds; do
  assert_match "a toleration has $f" "^ +$f\s+<" "$ex"
done
check_fails "an empty toleration is refused" \
  kubectl run x --image=registry.k8s.io/pause:3.10 --dry-run=server --overrides='{"spec": {"tolerations": [{}]}}'

section "Taint value"
kubectl taint node "$node" "$key-" >/dev/null
check "a taint can have no value" kubectl taint node "$node" "$key:NoSchedule"
pod novalue
check "it blocks Pods the same way" blocked novalue

section "Taint effect: PreferNoSchedule"
kubectl taint node "$node" "$key-" >/dev/null
kubectl taint node "$node" "$key=v:PreferNoSchedule" >/dev/null
pod prefer
check "PreferNoSchedule is a preference: a Pod that can only go there still runs" runs prefer
kubectl taint node "$node" "$key-" >/dev/null
skip "NoExecute evicts the Pods on the node" "it would evict other tests' Pods on the shared cluster"

section "Checking tolerations on our Pods"
blk=$(note_block "$NOTE" 'Checking tolerations on our Pods' 1)
check_output "custom-columns (from the note)" '^before +\[map\[effect:NoExecute key:node.kubernetes.io/not-ready' bash -ec "$(sed -n 1p <<<"$blk")"
check_output "jq (from the note)" '"pod_name": "equal"' bash -ec "$(sed -n 3,4p <<<"$blk")"

section "Taint-based evictions"
# The note's YAML, read as a Pod's tolerations, compared with what a Pod really gets.
note_tol=$({ printf 'apiVersion: v1\nkind: Pod\nmetadata: {name: x}\nspec:\n  containers: [{name: x, image: x}]\n  tolerations:\n'
  note_block "$NOTE" 'Taint-based evictions' 1; } | kubectl create --dry-run=client -f - -o json | jq -c '.spec.tolerations | sort_by(.key)')
got=$(kubectl get pod before -o json | jq -c '[.spec.tolerations[] | select(.effect == "NoExecute")] | sort_by(.key)')
assert_match "the note's block holds two tolerations" 'not-ready.*unreachable' "$note_tol"
assert_eq "every Pod gets the note's two tolerations" "$note_tol" "$got"
pod own-tol '[{"key": "node.kubernetes.io/unreachable", "operator": "Exists", "effect": "NoExecute", "tolerationSeconds": 60}]'
check_output "a Pod with its own toleration keeps it, and gets no 300 s one for that key" '^60$' \
  bash -c "kubectl get pod own-tol -o json | jq -r '[.spec.tolerations[] | select(.key == \"node.kubernetes.io/unreachable\") | .tolerationSeconds] | join(\" \")'"
check_output "DaemonSet Pods tolerate them with no tolerationSeconds" '^null null$' \
  bash -c "kubectl -n kube-system get pods -l k8s-app=kube-proxy -o json | jq -r '.items[0].spec.tolerations[] | select(.key == \"node.kubernetes.io/not-ready\" or .key == \"node.kubernetes.io/unreachable\") | .tolerationSeconds' | tr '\n' ' ' | sed 's/ \$//'"

section "Node not-ready or unreachable"
check_output "the kubelet's Lease lasts 40 seconds" '^40$' \
  bash -c "kubectl get --raw /api/v1/nodes/$node/proxy/configz | jq '.kubeletconfig.nodeLeaseDurationSeconds'"
times=()
for _ in $(seq 25); do
  times+=("$(kubectl -n kube-node-lease get lease "$node" -o jsonpath='{.spec.renewTime}')")
  sleep 1
done
gaps=$(printf '%s\n' "${times[@]}" | uniq | python3 -c "
import sys, datetime as d
t = [d.datetime.fromisoformat(x.strip().replace('Z', '+00:00')) for x in sys.stdin if x.strip()]
print(' '.join(str(round((b - a).total_seconds())) for a, b in zip(t, t[1:])))")
check "the kubelet renews it every 10 seconds (gaps: $gaps)" bash -c "set -- $gaps; [ \$# -ge 1 ] && for g; do [ \$g -ge 9 ] && [ \$g -le 11 ] || exit 1; done"
kcm=kube-controller-manager-$CLUSTER-control-plane
check_output "--node-monitor-grace-period is 50 s by default" 'node-monitor-grace-period duration .*\(default 50s\)' \
  kubectl -n kube-system exec "$kcm" -- kube-controller-manager --help
check_fails "and kind does not change it" bash -c "kubectl -n kube-system get pod $kcm -o yaml | grep -q node-monitor-grace-period"
skip "after 300 s unreachable, the Pods are evicted" "it needs a node to go down; stopping one would disrupt other tests"

section "Manipulating taints"
check_fails "there is no kubectl untaint" kubectl untaint node "$node" "$key=v:NoSchedule"
kubectl taint node "$node" "$key=v:NoSchedule" >/dev/null
check "kubectl taint ... key=val:effect- removes a taint" kubectl taint node "$node" "$key=v:NoSchedule-"
check_output "it is gone" '^$' kubectl get node "$node" -o jsonpath="{.spec.taints[?(@.key==\"$key\")].effect}"
kubectl taint node "$node" "$key=v:NoSchedule" "$key=v:PreferNoSchedule" >/dev/null
check "kubectl taint ... key- removes every taint with that key" kubectl taint node "$node" "$key-"
check_output "both are gone" '^$' kubectl get node "$node" -o jsonpath="{.spec.taints[?(@.key==\"$key\")].effect}"
check "kubectl cordon" kubectl cordon "$node"
check "adds node.kubernetes.io/unschedulable:NoSchedule" retry 20 bash -c \
  "kubectl get node $node -o jsonpath='{.spec.taints[?(@.key==\"node.kubernetes.io/unschedulable\")].effect}' | grep -qx NoSchedule"
check "kubectl uncordon" kubectl uncordon "$node"
check "removes it" retry 20 bash -c \
  "! kubectl get node $node -o jsonpath='{.spec.taints[*].key}' | grep -q node.kubernetes.io/unschedulable"
