#!/usr/bin/env bash
# note: kubernetes/cicd-gitops/tilt.md
# env: kind
# timeout: 1800
# tilt ci runs the upstream DockerCoins Tiltfile to the end. Tilt's port-forward on
# localhost:30555 is in the runner, which shares the Docker daemon's network.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"
use_test_namespace

NOTE=kubernetes/cicd-gitops/tilt
HOME=$(mktemp -d)
export HOME
cd "$HOME"
BIN=$HOME/bin
mkdir -p "$BIN"
export PATH=$BIN:$PATH
arch=$(uname -m)
case $arch in aarch64) arch=arm64 ;; esac
cleanup() {
  [ -d "$HOME/container.training/dockercoins" ] &&
    (cd "$HOME/container.training/dockercoins" && timeout 300 tilt down >/dev/null 2>&1)
  kubectl delete namespace tilt-registry shpod --ignore-not-found --wait=false >/dev/null 2>&1
  docker image ls --format '{{.Repository}}:{{.Tag}}' | grep '^localhost:30555/' | xargs -r docker rmi >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT

section "Installing Tilt"
check "a binary release from GitHub" bash -ec \
  "curl -fsSL https://github.com/tilt-dev/tilt/releases/download/$TILT_VERSION/tilt.${TILT_VERSION#v}.linux.$arch.tar.gz | tar -xz -C $BIN tilt"
check_output "tilt version" "v${TILT_VERSION#v}" tilt version

section "Telling Tilt to listen on 0.0.0.0"
check_output "tilt up has a --host flag (from the note)" '--host string' tilt up --help
check_output "its default comes from TILT_HOST (from the note)" 'TILT_HOST' tilt up --help
assert_match "the note uses tilt up --host" '^tilt up --host=0\.0\.0\.0$' "$(note_block "$NOTE" 2 | sed 's/^ *//')"
check_output "without up, --host is refused (the correction)" 'unknown flag: --host' bash -c 'tilt --host=0.0.0.0 </dev/null 2>&1; true'

section "Running Tilt in a Pod: the shpod patch"
kubectl create namespace shpod >/dev/null
kubectl -n shpod create service nodeport shpod --tcp=22:22 >/dev/null
check "kubectl patch service shpod (from the note)" bash -ec "$(note_block "$NOTE" 4)"
check_output "port 10350 is now on NodePort 30150" '10350:30150' \
  kubectl -n shpod get svc shpod -o jsonpath='{range .spec.ports[*]}{.port}:{.nodePort} {end}'

section "Tilt in practice"
git clone -q --depth 1 https://github.com/jpetazzo/container.training
cd container.training/dockercoins
for i in 5 6 7; do
  line=$(note_block "$NOTE" "$i" | sed 's/^ *//')
  check_output "the Tiltfile has: $line" "^1$" bash -c "grep -cF -- \"\$1\" Tiltfile" _ "$line"
done
check "tilt ci builds, pushes and deploys DockerCoins" timeout 1200 tilt ci --timeout 15m
check_output "the worker image is renamed localhost:30555/dockercoins_worker:tilt-xxx (from the note)" \
  '^localhost:30555/dockercoins_worker:tilt-[0-9a-f]+$' \
  kubectl get deploy worker -o jsonpath='{.spec.template.spec.containers[0].image}'
check_output "and the nodes pulled it from the registry on NodePort 30555" '^5$' bash -c \
  "kubectl get deploy -o jsonpath='{range .items[*]}{.status.readyReplicas}{\"\n\"}{end}' | grep -c '^1$'"
