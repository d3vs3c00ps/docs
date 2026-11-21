#!/usr/bin/env bash
# note: kubernetes/extending/events.md
# env: kind
# timeout: 600
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/extending/events
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s
cd "$(mktemp -d)"
LABEL=notes-test/events=$TEST_NS
cleanup() {
  kubectl -n default delete events -l "$LABEL" >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
run() { bash -ec "$1" 2>&1; }
CP=$(kubectl get nodes -o name | grep control-plane | head -1 | cut -d/ -f2)

section "Reading events"
check_output "kubectl get ev is a short name for events" '^ev$' bash -c \
  "kubectl api-resources --api-group='' -o wide | awk '\$1==\"events\"{print \$2}'"
kubectl run broken --image=notes-test.invalid/nope --restart=Never >/dev/null
retry 120 bash -c "kubectl get ev --field-selector=type=Warning,involvedObject.name=broken -o name | grep -q ."
check_output "the non-Normal events, in all namespaces (from the note)" "^$TEST_NS +.*Warning +.*pod/broken" run "$(note_block "$NOTE" 1)"
check_output "(only Warning events in that list)" '^$' bash -c \
  "kubectl get ev -A --field-selector=type!=Normal --no-headers -o custom-columns=T:.type 2>/dev/null | grep -v '^Warning$' || true"
check_output "kubectl warns that ev also matches events.k8s.io (the note's remark)" 'short name "ev" could also match .*events.events.k8s.io' \
  bash -c 'kubectl get ev 2>&1 >/dev/null'

section "Reading events (take 2)"
check_output "kubectl describe -v6 shows the request that reads the events (from the note)" \
  'GET.*/api/v1/namespaces/default/events\?.*involvedObject\.name%3Dkubernetes' \
  bash -c "$(note_block "$NOTE" 2 | sed 's|>/dev/null|2>\&1 >/dev/null|')"

section "Experimenting with events: a Node"
curl -fsSL "$UPSTREAM/event-node.yaml" | sed "s/kind-control-plane/$CP/; s|container.training/test: \"\"|notes-test/events: \"$TEST_NS\"|" >event-node.yaml
check "kubectl create -f event-node.yaml, name and uid updated (from the note)" kubectl -n default create -f event-node.yaml
check_output "kubectl describe node shows it, with the Node name as uid (upstream's file)" 'Warning +NodeOverheat .*Node temperature exceeds critical threshold' \
  kubectl describe node "$CP"
uid=$(kubectl get node "$CP" -o jsonpath='{.metadata.uid}')
sed "s/^  uid: .*/  uid: $uid/; s/NodeOverheat/NodeRealUid/" event-node.yaml | kubectl -n default create -f - >/dev/null
check_output "with the real uid of the Node, it shows too (the note's remark)" 'Warning +NodeRealUid ' \
  kubectl describe node "$CP"

section "Experimenting with events: a Pod"
kubectl run magic-bean --image=busybox:1.37 -- sleep 3600 >/dev/null
puid=$(kubectl get pod magic-bean -o jsonpath='{.metadata.uid}')
curl -fsSL "$UPSTREAM/event-pod.yaml" |
  sed "s/^  #apiVersion: v1/  apiVersion: v1/; s/^  #kind: Pod/  kind: Pod/; s/^  #name: magic-bean/  name: magic-bean/; s/^  #namespace: blue/  namespace: $TEST_NS/; s/^  #uid: .*/  uid: $puid/" >event-pod.yaml
check "kubectl create -f event-pod.yaml, involvedObject edited (from the note)" kubectl create -f event-pod.yaml
check_output "kubectl describe pod shows it (from the note)" 'Normal +BackupSuccessful .*Object successfully dumped to gitops repository' \
  kubectl describe pod magic-bean
check_output "both APIs see the same events (core v1 and events.k8s.io)" '^BackupSuccessful$' \
  kubectl get events.v1.events.k8s.io hello.1234567890 -o jsonpath='{.reason}'

section "Cluster operator perspective"
# shellcheck disable=SC2016
apihelp='kubectl -n kube-system exec "kube-apiserver-$1" -- kube-apiserver --help 2>&1'
check_output "events are kept 1 hour by default: --event-ttl (from the note)" '--event-ttl duration +.*\(default 1h0m0s\)' \
  bash -c "$apihelp | grep -A1 -- '--event-ttl' | tr -s ' \n' ' '" _ "$CP"
check_output "--etcd-servers-overrides exists, with the group/resource#servers form (from the note)" '--etcd-servers-overrides strings +Per-resource etcd servers overrides.*group/resource#servers' \
  bash -c "$apihelp | grep -A2 -- '--etcd-servers-overrides' | tr -s ' \n' ' '" _ "$CP"
