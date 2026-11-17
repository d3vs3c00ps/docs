#!/usr/bin/env bash
# note: kubernetes/concepts/deploymentslideshow.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/concepts/deploymentslideshow
owner() { kubectl get "$1" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}'; }

section "19,000 words"
check "kubectl create deployment web --image=nginx (from the note)" bash -ec "$(note_block "$NOTE" '19,000 words' 1)"
check "the Pod starts" kubectl wait --for=condition=Available deployment/web --timeout=180s
rs=$(kubectl get replicaset -l app=web -o name)
pod=$(kubectl get pod -l app=web -o name)
check_output "the Deployment created a ReplicaSet" '^Deployment/web$' owner "$rs"
check_output "the ReplicaSet created the Pod" "^ReplicaSet/${rs#replicaset.apps/}\$" owner "$pod"
check_output "the scheduler bound the Pod to a worker" "^$CLUSTER-worker2?\$" kubectl get "$pod" -o jsonpath='{.spec.nodeName}'
all=$(bash -c "$(note_block "$NOTE" '19,000 words' 2 | sed -n 1p)" | awk '{ print $1 }' | grep -oE '^(deployment.apps/web|replicaset.apps/web-|pod/web-)' | tr '\n' ' ')
assert_eq "kubectl get deployment,replicaset,pod lists all three (from the note)" "deployment.apps/web replicaset.apps/web- pod/web- " "$all"
events=$(bash -c "$(note_block "$NOTE" '19,000 words' 2 | sed -n 2p) -o jsonpath='{range .items[*]}{.reason}:{.source.component}{.reportingComponent} {end}'")
assert_match "events: Scheduled, from the scheduler" 'Scheduled:default-scheduler' "$events"
assert_match "events: Pulled, Created and Started, from the kubelet" 'Pulled:kubelet.*Created:kubelet.*Started:kubelet' "$events"
