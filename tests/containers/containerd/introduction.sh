#!/usr/bin/env bash
# note: containers/containerd/introduction.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=containers/containerd/introduction
source "$NOTES_ROOT/tests/containers/containerd/containerd-lib.bash"
use_test_namespace
W=$CLUSTER-worker2
# on NODE CMD...: this note's tests use two nodes
on() { local n=$1; shift; docker exec "$n" "$@"; }

section "What containerd is"
check_output "$(nline 1 1): a systemd service on every node" 'active \(running\)' \
  on_sh "$(nline 1 1)"
check_output "$(nline 1 2) talks to the daemon" 'Server' on_sh "$(nline 1 2)"

section "The layers"
check_output "one containerd-shim-runc-v2 per container" 'containerd-shim' \
  on "$CP" ps -C containerd-shim-runc-v2 -o comm=
shims=$(on "$CP" ps -C containerd-shim-runc-v2 --no-headers | wc -l)
check "several shims live on a busy node (one per container)" test "$shims" -gt 1

section "The shim is why containerd can be restarted"
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: survivor}
spec:
  nodeSelector: {kubernetes.io/hostname: $W}
  containers: [{name: app, image: busybox:1.37, args: [sleep, "600"]}]
EOF
kubectl wait --for=condition=Ready pod/survivor --timeout=180s >/dev/null
cid_before=$(kubectl get pod survivor -o jsonpath='{.status.containerStatuses[0].containerID}')
check "systemctl restart containerd on the node" on "$W" systemctl restart containerd
retry 30 docker exec "$W" ctr version >/dev/null
sleep 5
check_output "the pod is still Running afterwards" '^Running$' \
  kubectl get pod survivor -o jsonpath='{.status.phase}'
assert_eq "the container was not restarted (same container ID)" "$cid_before" \
  "$(kubectl get pod survivor -o jsonpath='{.status.containerStatuses[0].containerID}')"
assert_eq "restart count stayed 0" "0" \
  "$(kubectl get pod survivor -o jsonpath='{.status.containerStatuses[0].restartCount}')"

section "Its relationship to Docker"
check_output "Kubernetes containers live in the k8s.io namespace" 'k8s.io' \
  on "$CP" ctr namespaces list
check_output "ctr with --namespace k8s.io sees them" 'io.containerd.runc.v2' \
  on "$CP" ctr --namespace k8s.io containers list
skip "$(nline 3 1) (Docker's containers)" \
  "no Docker engine shares this containerd; the namespace exists only beside dockerd"

section "The CRI"
check_output "the kubelet's view through the CRI: crictl sees the API server" 'kube-apiserver' \
  on "$CP" crictl ps --name kube-apiserver
