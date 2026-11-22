#!/usr/bin/env bash
# note: kubernetes/cluster-setup/setup-devel.md
# env: kind
# timeout: 900
# Only the k3d commands run here; kind is tested in kind.sh, the other tools need macOS,
# Windows or a GUI. env kind, not k3d: k3d would start a shared cluster this test never uses.
source "$NOTES_ROOT/tests/lib/assert.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/cluster-setup/setup-devel
HOME=$(mktemp -d)
export HOME
cd "$HOME"
unset KUBECONFIG
_devel_exit() {
  local rc=$?
  k3d cluster delete petitcluster groscluster >/dev/null 2>&1 || true
  _t_finish "$rc"
}
trap _devel_exit EXIT
run() { bash -ec "$1" 2>&1; }

section "k3d in action"
check "k3d cluster create petitcluster (from the note)" run "$(note_block "$NOTE" 1) --image $K3S_IMAGE"
check_output "clusters are added to .kube/config (from the note)" '^k3d-petitcluster$' \
  kubectl config get-contexts -o name
check "and the cluster answers" kubectl --context k3d-petitcluster get nodes
k3d cluster delete petitcluster >/dev/null 2>&1
gros=$(note_block "$NOTE" 2)
assert_match "the custom version is the pinned k3s image" "--image ${K3S_IMAGE//./\\.}" "$gros"
assert_match "3 servers and 5 agents (from the note)" '--servers 3 --agents 5' "$gros"
# Five agents would exceed the harness's cluster budget: one is enough to check the roles.
check "the note's command, with 1 agent" run "${gros/--agents 5/--agents 1}"
check_output "3 control plane nodes" '^3$' bash -c \
  "kubectl --context k3d-groscluster get nodes -l node-role.kubernetes.io/control-plane --no-headers | wc -l | tr -d ' '"
check_output "with embedded etcd on the 3 servers" '^3$' bash -c \
  "kubectl --context k3d-groscluster get nodes -l node-role.kubernetes.io/etcd --no-headers | wc -l | tr -d ' '"
check_output "and the agent is a plain worker" '^1$' bash -c \
  "kubectl --context k3d-groscluster get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers | wc -l | tr -d ' '"

section "KinD"
check_output "the single-node command (tested in kind.sh)" '^ *kind create cluster$' note_block "$NOTE" 3
