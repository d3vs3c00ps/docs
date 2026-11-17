#!/usr/bin/env bash
# note: kubernetes/cicd-gitops/buildshiprun-selfhosted.md
# env: kind
# timeout: 1800
# The note runs Docker on a node. Here Docker runs in the runner, and reaches the
# registry through a port-forward on 127.0.0.1; the kind nodes pull from 127.0.0.1:NodePort.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/cicd-gitops/buildshiprun-selfhosted
HOME=$(mktemp -d)
export HOME
cd "$HOME"
PF=$((20000 + RANDOM % 20000))
REGISTRY=127.0.0.1:$PF
export REGISTRY
cleanup() {
  kill %1 2>/dev/null || true
  docker image ls --format '{{.Repository}}:{{.Tag}}' | grep "^$REGISTRY/" | xargs -r docker rmi >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
run() { bash -ec "$1" 2>&1; }
catalog() { curl -s "$REGISTRY/v2/_catalog"; }

section "Deploying a self-hosted registry"
check "kubectl create deployment registry (from the note)" run "$(note_block "$NOTE" 2)"
check "kubectl expose ... --type=NodePort (from the note)" run "$(note_block "$NOTE" 3)"
kubectl rollout status deploy/registry --timeout=180s >/dev/null

section "Connecting to our registry"
check_output "kubectl describe svc/registry shows the NodePort (from the note)" '^NodePort: +<unset> +3[0-9]{4}/TCP' run "$(note_block "$NOTE" 4)"
NODEPORT=$(bash -c "$(note_block "$NOTE" 5); echo \$NODEPORT")
check_output "NODEPORT, programmatically (from the note)" '^3[0-9]{4}$' echo "$NODEPORT"
kubectl port-forward svc/registry "$PF:5000" >/dev/null 2>&1 &
retry 30 curl -sf "$REGISTRY/v2/"

section "Testing our registry"
check_output "an empty catalog (from the note)" '^\{"repositories":\[\]\}$' run "$(note_block "$NOTE" 6)"
check "docker pull busybox; docker tag (from the note)" run "$(note_block "$NOTE" 8)"
check "docker push (from the note)" run "$(note_block "$NOTE" 9)"
check_output "now busybox is there (from the note)" '^\{"repositories":\["busybox"\]\}$' catalog

section "The nodes pull from 127.0.0.1:NodePort (the note's strategy)"
kubectl run frominside --image="127.0.0.1:$NODEPORT/busybox" -- sleep 3600 >/dev/null
check "containerd pulls over plain HTTP from 127.0.0.1, with no extra configuration" \
  kubectl wait --for=condition=Ready pod/frominside --timeout=120s

section "Building and pushing our images"
git clone -q --depth 1 https://github.com/jpetazzo/container.training
cd container.training/stacks
check_output "the excerpt matches dockercoins.yml" '^$' bash -c \
  "$(declare -f); while read -r l; do [[ -z \$l || \$l == ... ]] && continue; grep -qF -- \"\$l\" dockercoins.yml || echo \"missing: \$l\"; done <<<\"\$1\"" _ "$(note_block "$NOTE" 14)"
check "docker compose build and push (from the note)" bash -ec "$(note_block "$NOTE" 13)"
check_output "the four images are in the registry (from the note)" '"hasher".*"rng".*"webui".*"worker"' catalog
check_output "with the v0.1 tag" '"tags":\["v0.1"\]' curl -s "$REGISTRY/v2/worker/tags/list"
check_output "the docker-compose binary is gone (the note's correction)" '^$' bash -c "command -v docker-compose || true"
