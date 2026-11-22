#!/usr/bin/env bash
# note: kubernetes/cluster-setup/staticpods.md
# env: kind
# timeout: 900
# The note has no commands: these checks follow its claims on a kind worker.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

use_test_namespace
W=$CLUSTER-worker
CP=$CLUSTER-control-plane
DIR=/etc/kubernetes/manifests
cleanup() {
  docker exec "$W" rm -f "$DIR/notes-static.yaml" "$DIR/notes-priv.yaml" >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
# crictl_running NAME: the static pod's container runs on the worker, API server or not.
crictl_running() { docker exec "$W" crictl ps --name "$1" -q | grep -q .; }
put() {
  docker exec -i "$W" sh -c "cat >$DIR/$1" <<EOF
apiVersion: v1
kind: Pod
metadata: {name: ${1%.yaml}, namespace: $TEST_NS}
spec:
  containers:
  - name: ${1%.yaml}
    image: busybox:1.37
    command: [sleep, '$2']
    ${3:-}
EOF
}

section "Static pods"
check_output "kind's kubelet reads static pods from a directory (staticPodPath)" "^staticPodPath: $DIR\$" \
  docker exec "$W" grep '^staticPodPath:' /var/lib/kubelet/config.yaml
check_output "kubeadm renders the control plane there (from the note)" 'etcd.yaml kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml' \
  bash -c "docker exec $CP ls $DIR | xargs"
put notes-static.yaml 3600
retry 120 bash -c "kubectl get pod notes-static-$W >/dev/null 2>&1"
check "kubelet appends the node name to the pod name" kubectl get pod "notes-static-$W"
check_output "the API object is a mirror pod" 'kubernetes.io/config.mirror' \
  kubectl get pod "notes-static-$W" -o jsonpath='{.metadata.annotations}'

section "Mirror pods"
uid=$(kubectl get pod "notes-static-$W" -o jsonpath='{.metadata.uid}')
retry 120 crictl_running notes-static
cid=$(docker exec "$W" crictl ps --name notes-static -q)
kubectl delete pod "notes-static-$W" --wait=false >/dev/null
retry 180 bash -c "[ -n \"\$(kubectl get pod notes-static-$W -o jsonpath='{.metadata.uid}' 2>/dev/null)\" ] && [ \"\$(kubectl get pod notes-static-$W -o jsonpath='{.metadata.uid}')\" != '$uid' ]"
check "kubelet recreates a deleted mirror pod" kubectl get pod "notes-static-$W"
check_output "and deleting it had no effect on the static pod: same container" "^$cid\$" \
  docker exec "$W" crictl ps --name notes-static -q

section "How and when kubelet runs static pods"
put notes-static.yaml 7200
retry 120 bash -c "[ \"\$(docker exec $W crictl ps --name notes-static -q)\" != '$cid' ] && docker exec $W crictl ps --name notes-static -q | grep -q ."
check "a modified manifest: the pod is destroyed and recreated" crictl_running notes-static
check_output "(with the new command)" '7200' kubectl get pod "notes-static-$W" -o jsonpath='{.spec.containers[0].command}'
docker exec "$W" rm "$DIR/notes-static.yaml"
check "a deleted manifest: the pod is destroyed" retry 120 bash -c "! docker exec $W crictl ps -a --name notes-static -q | grep -q ."
check "and so is its mirror pod" retry 60 bash -c "! kubectl get pod notes-static-$W >/dev/null 2>&1"

section "Admission control blocks the mirror pod, not the static pod"
kubectl label namespace "$TEST_NS" pod-security.kubernetes.io/enforce=baseline >/dev/null
put notes-priv.yaml 3600 'securityContext: {privileged: true}'
retry 120 bash -c "docker exec $W crictl ps --name notes-priv -q | grep -q ."
check "kubelet runs the privileged static pod anyway" crictl_running notes-priv
sleep 20
check_fails "but Pod Security admission refuses its mirror pod" kubectl get pod "notes-priv-$W"
check_output "(the kubelet says why)" 'violates PodSecurity|forbidden' bash -c \
  "docker exec $W journalctl -u kubelet --since '-3min' --no-pager | grep -m1 -E 'notes-priv.*(violates PodSecurity|forbidden)'"
