#!/usr/bin/env bash
# note: containers/containerd/advanced.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=containers/containerd/advanced
use_test_namespace
CP=$CLUSTER-control-plane
on() { docker exec "$CP" "$@"; }
RC=rc-$TEST_NS
trap '_k8s_rc=$?; kubectl delete runtimeclass "$RC" --ignore-not-found >/dev/null 2>&1; _k8s_exit' EXIT

section "Snapshotters"
check_output "ctr plugins list | grep snapshot (from the note)" 'overlayfs' \
  bash -c "docker exec $CP ctr plugins list | grep snapshot"
check_output "the default snapshotter in use is overlayfs" "snapshotter = .overlayfs." \
  bash -c "docker exec $CP containerd config dump 2>/dev/null | grep -m1 'snapshotter ='"

section "Registry configuration"
check_output "config_path is the registry layout containerd offers by default" \
  'config_path' bash -c "docker exec $CP containerd config default | grep config_path | head -1"

section "Runtime classes"
sed "s/name: gvisor/name: $RC/" <(note_block "$NOTE" 'Runtime classes' 2 | sed '/^---$/q' | grep -v '^---$') \
  | kubectl apply -f - >/dev/null
check_output "a RuntimeClass maps a name to a containerd handler" "$RC" \
  kubectl get runtimeclass "$RC"
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: untrusted-workload}
spec:
  runtimeClassName: $RC
  containers: [{name: app, image: busybox:1.37, args: [sleep, "60"]}]
EOF
check "a handler not configured on the node cannot run pods" retry 30 bash -c \
  "kubectl get events --field-selector involvedObject.name=untrusted-workload -o json \
   | grep -qE 'RuntimeClass|no runtime for|FailedCreatePodSandBox'"

section "Plugins"
check_output "ctr plugins list shows the CRI plugin ok" 'cri.*ok' on ctr plugins list
check_output "ctr plugins list --detailed names each plugin's state" 'Type:' \
  bash -c "docker exec $CP ctr plugins list --detailed | head -10"
