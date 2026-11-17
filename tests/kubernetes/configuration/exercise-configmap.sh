#!/usr/bin/env bash
# note: kubernetes/configuration/exercise-configmap.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/configuration/exercise-configmap
WORDSMITH_COMMIT=2c2f0203895576ecd03d49db9743e40d224eacad
# Docker Hub limits anonymous pulls per IP, and every test shares this IP.
# mirror.gcr.io serves the same Docker Hub images.
WEB=mirror.gcr.io/jpetazzo/wordsmith-web:latest
cd "$(mktemp -d)"
cleanup() {
  local rc=$?
  [[ -n ${cid:-} ]] && docker rm "$cid" >/dev/null 2>&1
  docker rmi "$WEB" >/dev/null 2>&1 || true
  (exit "$rc")
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
# The solution's blocks are the only ones on the page.
for n in 1 2 3; do note_block "$NOTE" "$n" >/dev/null; done
block() { note_block "$NOTE" "$1"; }

section "Exercise — ConfigMaps"
# The note clones the repository; the test takes the same files at a pinned commit.
mkdir wordsmith
curl -fsSL "https://github.com/jpetazzo/wordsmith/archive/$WORDSMITH_COMMIT.tar.gz" | tar -xz --strip-components=1 -C wordsmith
check "kubectl create configmap static --from-file=wordsmith/web/static/ (from the note)" \
  bash -ec "$(block 1 | grep -v '^git clone')"
check_output "it holds the regular files of the directory" \
  '^angular.min.js app.js favicon.ico index.html style.css $' \
  bash -c "kubectl get configmap static -o json | jq -r '(.data // {}) + (.binaryData // {}) | keys[]' | tr '\n' ' '"
check_output "favicon.ico is under binaryData" '^favicon.ico$' \
  bash -c "kubectl get configmap static -o json | jq -r '.binaryData | keys[]'"
check_output "the fonts and images subdirectories are skipped" '^0$' \
  bash -c "kubectl get configmap static -o json | jq -r '(.data // {}) + (.binaryData // {}) | keys[]' | grep -c -E 'woff2|png|svg' || true"
size=$(kubectl get configmap static -o json | wc -c)
check "it fits in the 1 MiB limit of a ConfigMap ($size bytes)" test "$size" -lt 1048576
head -c 1100000 /dev/urandom >big.bin
check_output "a ConfigMap over 1 MiB is rejected" 'Too long|too long|exceeds' \
  bash -c "kubectl create configmap big --from-file=big.bin 2>&1; true"

# Reading the image needs no amd64 CPU: create a container, do not start it.
cid=$(docker create -q --platform linux/amd64 "$WEB")
files=$(docker export "$cid" | tar -t)
check_output "the web image has no working directory: it runs in /" '^$' \
  docker image inspect "$WEB" --format '{{.Config.WorkingDir}}'
check_output "and its static files are in /static" '^static/index.html$' grep -x 'static/index.html' <<<"$files"
assert_match "with fonts and images in subdirectories" '^static/fonts/font1.woff2$' "$files"

kubectl create deployment web --image="$WEB" >/dev/null
kubectl expose deployment web --port=80 >/dev/null
# The image is amd64-only: an arm64 node runs it only if it emulates amd64 (Docker Desktop does).
if ! kubectl rollout status deployment web --timeout=180s >/dev/null; then
  check_output "this node cannot run amd64: exec format error, as the note warns" 'exec format error' \
    kubectl logs deployment/web
  for c in "kubectl exec deployment/web -- ls /static" "the patch mounts the ConfigMap on /static" \
    "fonts and images break" "an edit of the ConfigMap reaches the Pod"; do
    skip "$c" "this node cannot run the amd64-only wordsmith-web image"
  done
  exit 0
fi
check_output "kubectl exec deployment/web -- ls /static (from the note)" '^index.html$' bash -ec "$(block 2)"
check "the patch mounts the ConfigMap on /static (from the note)" bash -ec "$(block 3)"
kubectl rollout status deployment web --timeout=180s >/dev/null
kubectl run client --image=mirror.gcr.io/library/busybox:1.37 -- sleep 3600 >/dev/null
kubectl wait --for=condition=Ready pod/client --timeout=120s >/dev/null
get() { kubectl exec client -- wget -qO- -T 5 "http://web/$1"; }
# Go's file server redirects /index.html to ./, which busybox wget cannot follow: ask for /.
retry 60 get "" >/dev/null || true  # the new Service and Pod may need a moment
check_output "index.html is served from the ConfigMap" '<html' get ""
check_fails "fonts and images break" get fonts/font1.woff2
kubectl get configmap static -o json | jq '.data["style.css"] += "\n/* edited */\n"' | kubectl replace -f - >/dev/null
check "an edit of the ConfigMap reaches the Pod, without a restart" retry 120 bash -c "kubectl exec client -- wget -qO- -T 5 http://web/style.css | grep -q edited"
