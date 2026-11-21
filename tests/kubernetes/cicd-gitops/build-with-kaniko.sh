#!/usr/bin/env bash
# note: kubernetes/cicd-gitops/build-with-kaniko.md
# env: kind
# timeout: 1500
# "Running Kaniko in a Docker container": the Docker daemon cannot see the runner's
# files, so the context is copied in with docker cp instead of -v, and the registry is a
# local container (kind NodePorts are not published on the host).
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"
use_test_namespace

NOTE=kubernetes/cicd-gitops/build-with-kaniko
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
HOME=$(mktemp -d)
export HOME
cd "$HOME"
HPORT=$((20000 + RANDOM % 20000))
REG=notes-kaniko-registry-$HPORT
KAN=notes-kaniko-$HPORT
cleanup() {
  docker rm -fv "$REG" "$KAN" >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
run() { bash -ec "$1" 2>&1; }

section "Running Kaniko in a Docker container"
git clone -q --depth 1 https://github.com/jpetazzo/container.training
docker run -d --name "$REG" -p "$HPORT:5000" registry:3 >/dev/null
retry 30 curl -sf "localhost:$HPORT/v2/"
assert_match "the note pins the tested Kaniko" "executor:$KANIKO_VERSION" "$(note_block "$NOTE" 4)"
# The note's command, with docker create instead of run, and no -v (see above).
cmd=$(note_block "$NOTE" 4 | sed "s/docker run/docker create --name $KAN/; /-v ~/d; s/\$PORT/$HPORT/")
check "create the Kaniko container with the note's flags" bash -ec "$cmd"
docker cp container.training/dockercoins/worker/. "$KAN:/workspace" >/dev/null
check "Kaniko builds and pushes without Docker or privileges" docker start -a "$KAN"
check_output "worker-kaniko is in the registry, over 127.0.0.1 with --net host (from the note)" '"tags":\["latest"\]' \
  curl -s "localhost:$HPORT/v2/worker-kaniko/tags/list"

section "Running Kaniko in a Kubernetes pod"
kubectl create deployment registry --image=registry:3 >/dev/null
kubectl expose deployment registry --port=5000 --type=NodePort >/dev/null
kubectl rollout status deploy/registry --timeout=180s >/dev/null
check_output "kubectl get svc registry, and PORT (from the note)" '^3[0-9]{4}$' bash -c "$(note_block "$NOTE" 3) >/dev/null; echo \$PORT"
pod=$(note_block "$NOTE" 5)
check_output "upstream kaniko-build.yaml still clones git:// (the correction)" 'git clone git://github.com' \
  curl -fsSL "$UPSTREAM/k8s/kaniko-build.yaml"
check_fails "and git:// no longer works with GitHub" timeout 30 git clone -q git://github.com/jpetazzo/container.training x
check_output "upstream kaniko-build.yaml has no restartPolicy, so it gets Always (the correction)" '^Always$' bash -c \
  "curl -fsSL $UPSTREAM/k8s/kaniko-build.yaml | kubectl create --dry-run=server -f - -o jsonpath='{.spec.restartPolicy}'"
assert_match "the note's pod sets restartPolicy: OnFailure" 'restartPolicy: OnFailure' "$pod"
check_output "a volume with no source is an emptyDir (from the note)" '"emptyDir":\{\}' bash -c \
  "printf '%s\n' \"\$1\" | kubectl create --dry-run=server -f - -o jsonpath='{.spec.volumes[0]}'" _ "$pod"
check "the note's builder pod" bash -c "printf '%s\n' \"\$1\" | kubectl apply -f -" _ "$pod"
check "the init container clones, then Kaniko builds, pushes and the pod ends" \
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/kaniko-build --timeout=900s
check_output "the git-clone init container ran first, and succeeded" '^Completed$' \
  kubectl get pod kaniko-build -o jsonpath='{.status.initContainerStatuses[0].state.terminated.reason}'
PORT=$(kubectl get svc registry -o jsonpath='{.spec.ports[0].nodePort}')
check_output "rng-kaniko is in the in-cluster registry" '"name":"rng-kaniko","tags":\["latest"\]' \
  docker exec "$(kubectl get nodes -o name | head -1 | cut -d/ -f2)" curl -s "localhost:$PORT/v2/rng-kaniko/tags/list"
