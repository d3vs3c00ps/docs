#!/usr/bin/env bash
# note: kubernetes/networking/cni-internals.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/networking/cni-internals
use_test_namespace
W=$CLUSTER-worker2
undo() {
  docker exec "$W" sh -c '
    [ -f /opt/cni/bin/ptp.real ] && { rm -f /opt/cni/bin/ptp; mv /opt/cni/bin/ptp.real /opt/cni/bin/ptp; }
    rm -f /opt/cni/bin/debug /tmp/cni.*' >/dev/null 2>&1 || true
}
trap '_k8s_rc=$?; undo; _k8s_exit' EXIT

section "Analyzing plugins: instrument ptp with the note's fake plugin"
note_block "$NOTE" 'Analyzing plugins' 1 | docker exec -i "$W" sh -c 'cat >/opt/cni/bin/debug'
docker exec "$W" chmod +x /opt/cni/bin/debug
docker exec "$W" sh -c 'mv /opt/cni/bin/ptp /opt/cni/bin/ptp.real && ln -s debug /opt/cni/bin/ptp'
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: cni-probe}
spec:
  nodeSelector: {kubernetes.io/hostname: $W}
  containers: [{name: app, image: busybox:1.37, args: [sleep, "120"]}]
EOF
check "the pod still starts through the instrumented plugin" \
  kubectl wait --for=condition=Ready pod/cni-probe --timeout=180s

files() { docker exec "$W" sh -c "cat /tmp/cni.*.ptp.$1 2>/dev/null"; }
section "What goes in and out"
assert_match "the input is JSON with the conflist's name injected" '"name"' "$(files in)"
assert_match "the environment says CNI_COMMAND=ADD" 'CNI_COMMAND=ADD' "$(files env)"
assert_match "CNI_IFNAME is eth0" 'CNI_IFNAME=eth0' "$(files env)"
assert_match "CNI_ARGS carries the pod name and namespace" \
  "K8S_POD_NAME=cni-probe.*K8S_POD_NAMESPACE=$TEST_NS|K8S_POD_NAMESPACE=$TEST_NS.*K8S_POD_NAME=cni-probe" \
  "$(files env | tr '\n' ' ')"
assert_match "CNI_NETNS points at a network namespace pseudo-file" 'CNI_NETNS=/' "$(files env)"
assert_match "the output is JSON with the allocated address" '"ips"|"ip4"|"address"' "$(files out)"
assert_match "the caller is the container runtime, not kubelet (note's callout)" \
  'containerd|crio' "$(files parent)"
assert_no_match "really not kubelet" 'kubelet' "$(files parent)"

section "Clean up"
kubectl delete pod cni-probe --timeout=60s >/dev/null
undo
check "a pod starts again with the plugin restored" bash -c "
  kubectl run cni-after --image=busybox:1.37 --restart=Never \
    --overrides='{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$W\"}}}' -- sleep 30 >/dev/null
  kubectl wait --for=condition=Ready pod/cni-after --timeout=180s"
