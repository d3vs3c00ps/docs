#!/usr/bin/env bash
# note: kubernetes/observability/logs-cli.md
# env: kind
# timeout: 600
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"
use_test_namespace

NOTE=kubernetes/observability/logs-cli
BIN=$(mktemp -d)
export PATH=$BIN:$PATH
arch=$(uname -m)
case $arch in aarch64) arch=arm64 ;; x86_64) arch=amd64 ;; esac
# follow BLOCK: run the note's stern command for a few seconds (stern follows forever).
follow() { timeout 15 bash -c "$1 --color never -n $TEST_NS" 2>&1 || true; }

section "Installing Stern"
check "a binary release from GitHub (from the note)" bash -ec \
  "curl -fsSL https://github.com/stern/stern/releases/download/$STERN_VERSION/stern_${STERN_VERSION#v}_linux_$arch.tar.gz | tar -xz -C $BIN stern"
check_output "stern without arguments prints its usage (from the note)" 'stern pod-query \[flags\]' \
  bash -c 'stern 2>&1; true'

section "Using Stern"
kubectl create deployment pingpong --image=alpine:3.22 --replicas=2 -- ping 127.0.0.1 >/dev/null
kubectl rollout status deployment/pingpong --timeout=180s >/dev/null
out=$(follow "$(note_block "$NOTE" 2)")
check_output "stern pingpong: lines from both pods, prefixed with pod and container (from the note)" '^2$' \
  bash -c "grep -oE '^pingpong-\S+ alpine .*bytes from 127.0.0.1' <<<\"\$1\" | cut -d' ' -f1 | sort -u | wc -l | tr -d ' '" _ "$out"

section "Stern convenient options"
out=$(timeout 15 bash -c "$(note_block "$NOTE" 3) --color never" 2>&1 || true)
check_output "--all-namespaces finds the coredns pods in kube-system (from the note)" '^kube-system coredns-\S+ coredns ' echo "$out"
check_output "--timestamps adds a timestamp" '^kube-system coredns-\S+ coredns [0-9]{4}-[0-9]{2}-[0-9]{2}T' echo "$out"
check_output "--tail 1: one line per container to start with" '^2$' \
  bash -c "grep -c '^kube-system coredns' <<<\"\$1\"" _ "$out"

section "Using Stern with a selector"
check_output "kubectl create deployment adds an app label (from the note)" '^pingpong$' \
  kubectl get pods -l app -o jsonpath='{.items[0].metadata.labels.app}'
kubectl run single --image=alpine:3.22 -- ping 127.0.0.1 >/dev/null
kubectl wait --for=condition=Ready pod/single --timeout=120s >/dev/null
check_output "kubectl run adds a run label (from the note)" '^single$' kubectl get pod single -o jsonpath='{.metadata.labels.run}'
out=$(follow "$(note_block "$NOTE" 4)")
check_output "stern -l app: the deployment's pods (from the note)" '^pingpong-' echo "$out"
check_output "(but not the kubectl run pod)" '^$' bash -c "grep '^single ' <<<\"\$1\" || true" _ "$out"
