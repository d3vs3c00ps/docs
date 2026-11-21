#!/usr/bin/env bash
# note: kubernetes/workloads/exercise-wordsmith.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/exercise-wordsmith
cd "$(mktemp -d)"
arch=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')

section "Exercise — deploying on Kubernetes"
for s in db web words; do
  check_output "jpetazzo/wordsmith-$s:latest is in the table" "^\| $s +\| jpetazzo/wordsmith-$s:latest" \
    grep -E "^\| $s " "$NOTES_ROOT/content/$NOTE.md"
done

section "Solution"
check_output "the solution block runs (from the note)" '^web +NodePort +[0-9.]+ +<none> +80:[0-9]+/TCP' \
  bash -ec "$(note_block "$NOTE" 'Solution' 1)"
check_output "db listens on 5432, words on 8080" '^5432 8080$' \
  bash -c "echo \$(kubectl get svc db -o jsonpath='{.spec.ports[0].port}') \$(kubectl get svc words -o jsonpath='{.spec.ports[0].port}')"

# The images are amd64-only: an arm64 node runs them only if it emulates amd64 (Docker Desktop does).
if ! kubectl wait --for=condition=available deploy/db deploy/web deploy/words --timeout=300s >/dev/null; then
  skip "the app answers on the NodePort" "this $arch node cannot run the amd64-only wordsmith images"
  check_output "on $arch with no emulation: exec format error, as the note warns" 'exec format error' kubectl logs deploy/web
  exit 0
fi
check "the three Deployments become available (on $arch)" kubectl wait --for=condition=available deploy/db deploy/web deploy/words --timeout=10s
port=$(kubectl get svc web -o jsonpath='{.spec.ports[0].nodePort}')
ip=$(kubectl get node "$CLUSTER-worker" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
# words may answer 500 for a moment, while db starts.
check "web answers on a node's IP and the NodePort" retry 120 curl -sf "http://$ip:$port/words/noun"
check_output "the page holds the sentence" 'class="sentence"' curl -sf "http://$ip:$port/"
check_output "each word comes from words, which reads db" '^\{"word":"[^"]+"\}$' curl -sf "http://$ip:$port/words/verb"
