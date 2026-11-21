#!/usr/bin/env bash
# note: containers/containerd/basics.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=containers/containerd/basics
source "$NOTES_ROOT/tests/containers/containerd/containerd-lib.bash"

section "Installing"
skip "$(nline 1 1) / $(nline 1 2)" \
  "kind nodes ship containerd; the openSUSE package is checked in containers/containerd/basics.leap.sh"
check_output "$(nline 2 1)" 'containerd github.com/containerd/containerd/v2 v2\.' on_sh "$(nline 2 1)"
check_output "$(nline 2 2)" 'runc version' on_sh "$(nline 2 2)"

section "Configuration"
# Writing /etc/containerd/config.toml would replace kind's tuned file on the shared
# node: generate to a scratch path instead, and do not restart.
check "$(nline 3 1), to a scratch file" \
  on_sh "$(nline 3 1 | sed 's|/etc/containerd/config.toml|/tmp/config-default.toml|')"
skip "$(nline 3 2)" "would load the generated default on the shared kind node and drop kind's settings"
default=$(on cat /tmp/config-default.toml)
assert_match "containerd 2.x writes a version 3+ file (the note's warning)" '^version = [34]' "$default"
for key in "plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options" \
  "plugins.'io.containerd.cri.v1.images'.pinned_images" "plugins.'io.containerd.cri.v1.images'.registry"; do
  assert_match "the 2.x table [$key] exists, as the note's table says" "\[$key\]" "$default"
done
assert_no_match "the 1.x tables are gone from it (grpc.v1.cri keeps only the streaming server)" \
  "io\.containerd\.grpc\.v1\.cri'?\"?\.(containerd|registry)|sandbox_image" "$default"
check_output "$(nline 4 1) shows what is loaded" 'SystemdCgroup = true' on_sh "$(nline 4 1)"

section "The cgroup driver"
# kind's own config.toml is a 1.x-style (version = 2) file: the note's fragments apply.
config=$(on cat /etc/containerd/config.toml)
assert_match "kind's config.toml is version = 2" '^version = 2' "$config"
assert_match "with the note's cgroup driver table" \
  "$(note_block "$NOTE" 5 | head -1 | sed 's/[][.]/\\&/g')" "$config"
assert_match "and SystemdCgroup = true" 'SystemdCgroup = true' "$config"
check_output "the kubelet agrees: cgroupDriver systemd" 'cgroupDriver: systemd' \
  on grep cgroupDriver /var/lib/kubelet/config.yaml

section "Sandbox image"
assert_match "sandbox_image sits in the note's table" 'sandbox_image = "registry\.k8s\.io/pause:' "$config"
check_output "kubeadm config images list shows the expected tag (the note's hint)" 'pause:3\.10\.2' \
  on kubeadm config images list
check_output "containerd 2.x loads it as pinned_images.sandbox" "sandbox = 'registry\.k8s\.io/pause:" \
  on containerd config dump

section "Registry configuration"
check_output "config_path lives in the 2.x registry table" "config_path = ''" \
  bash -c "docker exec $CP containerd config dump | grep -A3 \"io.containerd.cri.v1.images'.registry\""
skip "the hosts.toml mirror (block 8)" \
  "needs config_path set and a containerd restart on the node; mirrors are tested in containers/containerd/advanced"

section "State on disk"
check "images, snapshots and content live in /var/lib/containerd" \
  on test -d /var/lib/containerd/io.containerd.content.v1.content
check "runtime state lives in /run/containerd" on test -d /run/containerd
check_output "$(nline 9 1): the socket is not world-accessible, root-owned" '^srw-rw---- +[0-9]+ root root' \
  on_sh "$(nline 9 1)"

section "Namespaces"
check_output "$(nline 10 1) shows k8s.io on a Kubernetes node" 'k8s.io' on_sh "$(nline 10 1)"
check_output "$(nline 11 1): Kubernetes' containers" 'io.containerd.runc.v2' on_sh "$(nline 11 1)"
assert_eq "without the flag, the default namespace is empty (the classic surprise)" "" \
  "$(on ctr containers list | tail -n +2)"

section "Verifying it works"
check "$(nline 12 1)" on_sh "$(nline 12 1)"
check_output "$(nline 12 2), without -t and with a command for the shell" '^works$' \
  on_sh "$(nline 12 2 | sed "s/ -t / /; s/ test sh\$/ basics-test-$RANDOM sh -c 'echo works'/")"
check_output "$(nline 13 1) exercises the CRI path the kubelet uses" '"conditions"' on_sh "$(nline 13 1)"
check_output "$(nline 13 2)" 'kube-apiserver' on_sh "$(nline 13 2)"

section "systemd unit"
check_output "$(nline 14 1)" 'active \(running\)' on_sh "$(nline 14 1)"
check_output "$(nline 14 2) (stopped after 3 s)" 'containerd' \
  on_sh "timeout 3 $(nline 14 2) || [ \$? = 124 ]"
