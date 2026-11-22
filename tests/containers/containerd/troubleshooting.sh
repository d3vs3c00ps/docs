#!/usr/bin/env bash
# note: containers/containerd/troubleshooting.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=containers/containerd/troubleshooting
use_test_namespace
CP=$CLUSTER-control-plane
on() { docker exec "$CP" "$@"; }

section "Start here"
check_output "systemctl status containerd" 'active \(running\)' on systemctl status containerd --no-pager
check "journalctl -u containerd -n 200 --no-pager" \
  bash -c "docker exec $CP journalctl -u containerd -n 200 --no-pager >/dev/null"
assert_no_match "ctr plugins list: nothing in error state" 'error' "$(on ctr plugins list)"
check_output "crictl info reports the runtime conditions" 'RuntimeReady' \
  bash -c "docker exec $CP crictl info"

section "/var/lib/containerd filling the disk"
check "du -sh /var/lib/containerd/* (from the note)" \
  on bash -c 'du -sh /var/lib/containerd/* >/dev/null'
check "ctr snapshots usage shows where the disk went" on ctr --namespace k8s.io snapshots usage
check "crictl images lists what could be reclaimed" on crictl images
check "crictl rmi --prune (from the note)" on crictl rmi --prune

section "Pod stuck in ContainerCreating"
# A missing ConfigMap: the sandbox exists, the container is never created.
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: stuck}
spec:
  containers:
    - name: app
      image: busybox:1.37
      args: [sleep, "300"]
      envFrom: [{configMapRef: {name: does-not-exist}}]
EOF
check "the sandbox appears on a node (crictl pods): CNI and pause are fine" retry 60 bash -c \
  "docker exec $CLUSTER-worker crictl pods --name stuck -q | grep -q . ||
   docker exec $CLUSTER-worker2 crictl pods --name stuck -q | grep -q ."
check_output "but kubectl describe names the real problem in events" \
  'configmap "does-not-exist" not found' \
  retry_out 30 bash -c "kubectl describe pod stuck | tail -10 | grep -m1 'configmap \"does-not-exist\" not found'"
check_output "the CNI config directory is not empty" 'conflist' on ls /etc/cni/net.d/
check_output "the CNI binaries are in /opt/cni/bin" 'portmap' on ls /opt/cni/bin/

section "Cgroup driver mismatch"
check_output "grep SystemdCgroup /etc/containerd/config.toml (from the note)" \
  'SystemdCgroup = true' on grep -r SystemdCgroup /etc/containerd/config.toml
check_output "grep cgroupDriver in the kubelet config" 'systemd' \
  on grep cgroupDriver /var/lib/kubelet/config.yaml
check_output "stat -fc %T /sys/fs/cgroup/ on the node" 'cgroup2fs' \
  on stat -fc %T /sys/fs/cgroup/

section "Containers survive a containerd restart"
check_output "ps shows the shims that parent the containers" 'containerd-shim' \
  bash -c "docker exec $CP ps aux | grep containerd-shim | grep -v grep | head -2"

section "A quick node health script"
# kind mounts a tmpfs over /tmp after start, which masks docker cp; stream via exec
note_block "$NOTE" 'A quick node health script' 1 | docker exec -i "$CP" sh -c 'cat >/tmp/health.sh'
check_output "the note's health script runs end to end on a node" '== recent errors ==' \
  on bash /tmp/health.sh
