#!/usr/bin/env bash
# note: kubernetes/cicd-gitops/build-with-docker.md
# env: kind
# timeout: 1200
# kind nodes run containerd, like most clusters today: the note's pod shows the failure,
# and the Docker-in-Docker variant builds and pushes.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"
use_test_namespace

NOTE=kubernetes/cicd-gitops/build-with-docker
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
HOME=$(mktemp -d)
export HOME
cd "$HOME"
NODE=
cleanup() {
  # The hostPath bind mount leaves an empty directory where the socket was expected.
  [ -n "$NODE" ] && docker exec "$NODE" sh -c '[ -d /var/run/docker.sock ] && rmdir /var/run/docker.sock' >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
run() { bash -ec "$1" 2>&1; }

section "The self-hosted registry"
kubectl create deployment registry --image=registry:3 >/dev/null
kubectl expose deployment registry --port=5000 --type=NodePort >/dev/null
kubectl rollout status deploy/registry --timeout=180s >/dev/null
check_output "kubectl get svc registry (from the note)" '^registry +NodePort .*5000:3[0-9]{4}/TCP' run "$(note_block "$NOTE" 4)"
PORT=$(kubectl get svc registry -o jsonpath='{.spec.ports[0].nodePort}')

section "Resource specification for our builder pod"
pod=$(note_block "$NOTE" 2)
check_output "the inline YAML is the upstream docker-build.yaml (except the port line)" '^$' bash -c \
  "diff <(curl -fsSL $UPSTREAM/k8s/docker-build.yaml | grep -v 'value:' | sed '/^\$/d') <(grep -v 'value:' <<<\"\$1\") || true" _ "$pod"
check_output "the port must be a string: without the quotes, the API refuses it (from the note)" 'cannot unmarshal number|expected string|invalid type' \
  bash -c "sed 's/value: \"3XXXX\".*/value: $PORT/' <<<\"\$1\" | kubectl create --dry-run=server -f - 2>&1; true" _ "$pod"

section "Running our pod on a containerd node"
for n in $(kubectl get nodes -o name | cut -d/ -f2); do
  check_fails "no Docker socket on node $n" docker exec "$n" test -S /var/run/docker.sock
done
printf '%s\n' "$pod" | sed "s/value: \"3XXXX\".*/value: \"$PORT\"/" | kubectl apply -f - >/dev/null
retry 300 bash -c "kubectl logs build-image 2>/dev/null | grep -q 'Cannot connect to the Docker daemon'"
NODE=$(kubectl get pod build-image -o jsonpath='{.spec.nodeName}')
check_output "the note's pod fails: no Docker Engine (the correction)" 'Cannot connect to the Docker daemon' kubectl logs build-image
kubectl delete pod build-image --wait=true >/dev/null

section "Variant: Docker-in-Docker sidecar"
check "apply the variant (from the note)" bash -c "$(printf 'kubectl apply -f - <<"EOF"\n%s\nEOF' "$(note_block "$NOTE" 3)")"
check "the build pod completes" kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/build-image-dind --timeout=900s
check_output "it built and pushed the worker image" 'Pushed|digest: sha256' kubectl logs build-image-dind -c docker-build --tail=5
check_output "the image is in our registry" '"name":"worker","tags":\["latest"\]' \
  docker exec "$(kubectl get nodes -o name | head -1 | cut -d/ -f2)" curl -s "localhost:$PORT/v2/worker/tags/list"
