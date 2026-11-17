#!/usr/bin/env bash
# note: kubernetes/concepts/declarative.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/concepts/declarative

section "The API takes a spec"
out=$(bash -c "$(note_block "$NOTE" 'The API takes a spec' 1)" 2>&1) && rc=0 || rc=$?
assert_match "the API server rejects a Pod with no image (from the note)" '^[1-9]' "$rc"
assert_match "the error says spec.containers[0].image: Required value" 'spec\.containers\[0\]\.image: Required value' "$out"
check_fails "and stores nothing" kubectl get pod no-image

section "Reconciling state"
block=$(note_block "$NOTE" 'Reconciling state' 1)
check "create and scale the Deployment (from the note, first two lines)" bash -ec "$(head -2 <<<"$block")"
check "the controllers converge the state to the spec" \
  kubectl wait --for=jsonpath='{.status.readyReplicas}'=3 deployment/web --timeout=180s
check_output "the jsonpath query prints spec then status: 3 3 (from the note)" '^3 3$' bash -ec "$(sed -n 3p <<<"$block")"
check_output "a ReplicaSet created the Pods, not the Deployment" '^ReplicaSet$' \
  bash -c "kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.ownerReferences[0].kind}'"
