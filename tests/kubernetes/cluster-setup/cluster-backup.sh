#!/usr/bin/env bash
# note: kubernetes/cluster-setup/cluster-backup.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/cluster-setup/cluster-backup
use_test_namespace
cd "$(mktemp -d)"
CP=$CLUSTER-control-plane
cleanup() {
  docker exec "$CP" rm -rf /tmp/snapshot /tmp/restored >/dev/null 2>&1 || true
  kubectl delete pod --all --wait=false >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
run() { bash -ec "$1" 2>&1; }
rejected() { "$@" || true; }

section "Finding an etcd node and image"
eval "$(note_block "$NOTE" 2)"
eval "$(note_block "$NOTE" 3)"
export NODE IMAGE   # the note's later commands use them
check_output "the control plane node (from the note)" "^$CP\$" echo "$NODE"
check_output "the etcd image (from the note)" '^registry.k8s.io/etcd:' echo "$IMAGE"

section "Making a snapshot"
# The debug pods land in our namespace; their pods stay after --attach returns.
check "etcdctl snapshot save in a node debug pod (from the note)" run "$(note_block "$NOTE" 4)"
check "the snapshot is on the node" docker exec "$CP" test -s /tmp/snapshot

section "Transfer the snapshot"
run "$(note_block "$NOTE" 'Transfer the snapshot' 1)" >/dev/null || true
check_output "the original transfer gives an empty file: no base64 in the etcd image (the correction)" '^0$' \
  bash -c 'wc -c <snapshot | tr -d " "'
check_output "(the debug pod failed to start, but kubectl did not say so)" 'executable file not found' \
  bash -c "kubectl get pods -o jsonpath='{..state.terminated.message}'"
check "the corrected transfer: base64 from a busybox debug pod" bash -ec \
  "$(note_block "$NOTE" 'Transfer the snapshot' 2)"
check "the snapshot arrived intact (same checksum)" bash -c \
  "[ \"\$(sha256sum <snapshot | cut -d' ' -f1)\" = \"\$(docker exec $CP sha256sum /tmp/snapshot | cut -d' ' -f1)\" ]"

section "Restoring an etcd snapshot"
# debug_etcd CMD...: CMD in an etcd node debug pod; prints its logs, returns its exit code.
# (--attach can miss the output of a short command, and always returns 0.)
debug_etcd() {
  local pod rc
  pod=$(kubectl debug --profile=general "node/$NODE" --image "$IMAGE" -- "$@" 2>&1 |
    sed -n 's/^Creating debugging pod \([^ ]*\) .*/\1/p')
  retry 120 bash -c "kubectl get pod $pod -o jsonpath='{..state.terminated.exitCode}' | grep -q ."
  kubectl logs "$pod" 2>&1
  rc=$(kubectl get pod "$pod" -o jsonpath='{..state.terminated.exitCode}')
  return "${rc:-1}"
}
assert_match "the note restores with etcdutl" 'etcdutl snapshot restore' "$(note_block "$NOTE" 'When using kubeadm' 1)"
check_fails "etcdctl snapshot restore is gone from etcd 3.6+: it fails (the correction)" \
  debug_etcd etcdctl snapshot restore /host/tmp/snapshot --data-dir=/host/tmp/restored
check "and wrote nothing" docker exec "$CP" test ! -e /tmp/restored
check "etcdutl snapshot restore creates a new data directory, offline" \
  debug_etcd etcdutl snapshot restore /host/tmp/snapshot --data-dir=/host/tmp/restored
check "(a member directory, as etcd expects)" docker exec "$CP" test -d /tmp/restored/member/snap
check_output "the running etcd is untouched" 'is healthy' \
  debug_etcd etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/host/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/host/etc/kubernetes/pki/etcd/healthcheck-client.crt --key=/host/etc/kubernetes/pki/etcd/healthcheck-client.key \
  endpoint health
skip "kubeadm init with the restored data directory" \
  "rebuilds the control plane; the shared test cluster must keep running"

section "Don't forget: the TLS information"
check_output "kubeadm keeps it in /etc/kubernetes/pki" 'ca.key' docker exec "$CP" ls /etc/kubernetes/pki
