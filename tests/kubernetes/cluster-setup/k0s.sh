#!/usr/bin/env bash
# note: kubernetes/cluster-setup/k0s.md
# env: leap-systemd
# timeout: 1200
# The single-node install, run as written (as root: no sudo in the image), and k0sctl init.
# k0sctl apply needs three SSH hosts: skipped.
source "$NOTES_ROOT/tests/lib/assert.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/cluster-setup/k0s
cd "$(mktemp -d)"
run() { bash -ec "$(sed 's/^ *sudo //; s/| sudo sh/| sh/' <<<"$1")" 2>&1; }
case $(uname -m) in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; esac
# containerd cannot put its overlays on the container's overlayfs root.
mkdir -p /var/lib/k0s && mount -t tmpfs tmpfs /var/lib/k0s

section "k0sctl"
assert_match "the note downloads the pinned k0sctl" "download/$K0SCTL_VERSION/k0sctl-linux-amd64" "$(note_block "$NOTE" 1)"
check "download k0sctl (from the note, for this CPU)" run "$(note_block "$NOTE" 1 | sed "s/linux-amd64/linux-$ARCH/")"
check_output "it runs" "${K0SCTL_VERSION#v}" k0sctl version

section "k0sctl configuration file"
check "k0sctl init (from the note)" run "$(note_block "$NOTE" 2)"
check_output "three hosts, all controllers" '^3 controller$' bash -c "grep -o 'role: .*' k0sctl.yaml | sort | uniq -c | awk '{print \$1, \$3}'"
check_output "with the docker SSH user" 'user: docker' cat k0sctl.yaml
check_output "--k0s adds a default k0s config to the file" 'apiVersion: k0s.k0sproject.io/' cat k0sctl.yaml
check_output "(with etcd: the three controllers form the etcd cluster of the note)" 'type: etcd' cat k0sctl.yaml
check_output "noTaints is a host field k0sctl knows" 'noTaints' bash -c \
  "curl -fsSL https://raw.githubusercontent.com/k0sproject/k0sctl/$K0SCTL_VERSION/README.md | grep -m1 -o 'noTaints'"
skip "k0sctl apply (from the note)" "needs three hosts reachable over SSH"

section "Single node install"
assert_match "get.k0s.sh (from the note)" 'get.k0s.sh' "$(note_block "$NOTE" 10)"
# Pin the version get.k0s.sh installs; the note takes the latest.
check "download k0s (from the note)" run "export K0S_VERSION=$K0S_VERSION; $(note_block "$NOTE" 10)"
check_output "(the pinned version)" "^${K0S_VERSION//+/\\+}\$" k0s version
check "k0s install controller --single (from the note)" run "$(note_block "$NOTE" 11)"
check_output "it installs a systemd unit" 'k0scontroller.service' bash -c 'systemctl list-unit-files | grep k0s'
check "k0s start (from the note)" run "$(note_block "$NOTE" 12)"
retry 180 bash -c 'k0s kubectl get nodes 2>/dev/null | grep -q " Ready "'

section "Check the results"
out=$(run "$(note_block "$NOTE" 4)")
while read -r field; do
  [ -n "$field" ] && assert_match "k0s status shows '$field' (from the note)" "^$field" "$out"
done <<<"$(note_block "$NOTE" 5 | sed 's/:.*/:/')"
assert_match "Role: controller" '^Role: controller$' "$out"
assert_match "SingleNode: true here (the note's three-node cluster says false)" '^SingleNode: true$' "$out"
assert_match "Workloads: true (a --single controller also runs kubelet)" '^Workloads: true$' "$out"
check_output "k0s kubectl get nodes (from the note): Ready" ' Ready ' run "$(note_block "$NOTE" 8)"
check_output "(VERSION ends with +k0s, as in the note)" '\+k0s' run "$(note_block "$NOTE" 8)"
check_fails "--single uses kine, not etcd: etcd member-list fails" run "$(note_block "$NOTE" 6)"

section "Single node uninstall"
check "k0s stop (from the note)" run "$(note_block "$NOTE" 13)"
check "k0s reset (from the note)" run "$(note_block "$NOTE" 14)"
check_fails "the unit is gone" bash -c 'systemctl list-unit-files | grep -q k0scontroller'
