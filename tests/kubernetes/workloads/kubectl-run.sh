#!/usr/bin/env bash
# note: kubernetes/workloads/kubectl-run.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/kubectl-run
cd "$(mktemp -d)"
# Docker Hub limits anonymous pulls, and many tests share this machine's address: run the
# note's commands with the same official image from its public ECR copy.
hub() { sed -E 's#--image[= ]alpine#--image=public.ecr.aws/docker/library/alpine#'; }
block() { note_block "$NOTE" "$@" | hub; }
podname() { kubectl get pods -l app=pingpong -o jsonpath="{.items[${1:-0}].metadata.name}"; }

section "If you're running Kubernetes 1.17 (or older)"
check_output "the server is 1.19 or newer" 'Server Version: v1\.(19|[2-9][0-9])\.' kubectl version
check_fails "kubectl run has no --replicas option any more" kubectl run x --image=alpine --replicas=2 --dry-run=client
check_fails "nor --generator" kubectl run x --image=alpine --generator=deployment/apps.v1 --dry-run=client
check_output "kubectl run creates a Pod only" '^kind: Pod$' kubectl run x --image=alpine --dry-run=client -o yaml

section "Starting a simple pod with kubectl run"
check_output "kubectl run pingpong (from the note)" '^pod/pingpong created$' bash -ec "$(block 'Starting a simple pod' 1)"
check_output "the words after the name are the container's args" '^\["ping","127.0.0.1"\] *$' \
  kubectl get pod pingpong -o jsonpath='{.spec.containers[0].args} {.spec.containers[0].command}'
check_output "--command makes them the command" '^\["ping","127.0.0.1"\]$' \
  kubectl run x --image=alpine --dry-run=client -o jsonpath='{.spec.containers[0].command}' --command -- ping 127.0.0.1
check_output "-- passes options to the command, not to kubectl" '^\["ping","-c","3","127.0.0.1"\]$' \
  kubectl run x --image=alpine --dry-run=client -o jsonpath='{.spec.containers[0].args}' -- ping -c 3 127.0.0.1
kubectl wait --for=condition=Ready pod/pingpong --timeout=120s >/dev/null

section "Viewing container output"
check_output "kubectl logs pingpong shows ping (from the note)" 'bytes from 127.0.0.1' bash -ec "$(block 'Viewing container output' 1)"

section "Streaming logs in real time"
check_output "--tail 1 --follow streams one line, then new ones (from the note)" '^[3-9]$' \
  bash -c "timeout 4 $(block 'Streaming logs' 1) | grep -c 'bytes from 127.0.0.1'; true"
check_output "--since takes a duration" 'bytes from' kubectl logs pingpong --since=5s
check_fails "not a timestamp" kubectl logs pingpong --since=2026-01-01T10:00:00Z
check_output "--since-time takes the timestamp" 'bytes from' kubectl logs pingpong --since-time="$(date -u -d '-1 min' +%Y-%m-%dT%H:%M:%SZ)"

section "Scaling our application"
out=$(bash -c "$(block 'Scaling our application' 1)" 2>&1) && rc=0 || rc=$?
check "kubectl scale pod fails (from the note)" test "$rc" -ne 0
assert_eq "with the note's error" "$(note_block "$NOTE" 'Scaling our application' 2)" "$out"

section "NotFound"
check_output "-v6 shows a PATCH to the scale subresource" 'verb="PATCH" url="https://.*/pods/pingpong/scale" status="404' \
  bash -c 'kubectl scale pod pingpong --replicas=3 -v6 2>&1; true'

section "Creating a Deployment running ping"
check "kubectl create deployment pingpong (from the note)" bash -ec "$(block 'Creating a Deployment running' 1)"
check_output "the words after -- are the container's command" '^\["ping","127.0.0.1"\]$' \
  kubectl get deploy pingpong -o jsonpath='{.spec.template.spec.containers[0].command}'
kubectl rollout status deploy/pingpong --timeout=120s >/dev/null

section "What has been created?"
all=$(bash -ec "$(block 'What has been created' 1)")
assert_match "kubectl get all shows the standalone Pod (from the note)" 'pod/pingpong +1/1 +Running' "$all"
assert_match "the Deployment's Pod, pingpong-xxxxxxxxxx-yyyyy" 'pod/pingpong-[a-z0-9]{8,10}-[a-z0-9]{5} ' "$all"
assert_match "the Deployment" 'deployment.apps/pingpong +1/1' "$all"
assert_match "and a ReplicaSet" 'replicaset.apps/pingpong-[a-z0-9]{8,10} +1 +1 +1' "$all"
kubectl create configmap not-in-all --from-literal=a=1 >/dev/null
assert_no_match "kubectl get all is a lie: no ConfigMaps" 'not-in-all' "$all $(kubectl get all)"

section "From Deployment to Pod"
rs=$(kubectl get rs -l app=pingpong -o name)
check_output "the ReplicaSet is owned by the Deployment" '^Deployment/pingpong$' \
  kubectl get "$rs" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}'
check_output "the Pod is owned by the ReplicaSet" "^ReplicaSet/${rs#replicaset.apps/}\$" \
  kubectl get pod "$(podname)" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}'

section "Pod details"
kubectl run ok --image=public.ecr.aws/docker/library/alpine --restart=Never -- true >/dev/null
kubectl run ko --image=public.ecr.aws/docker/library/alpine --restart=Never -- false >/dev/null
check "all containers exit 0: Succeeded" kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/ok --timeout=120s
check "one fails, no restart: Failed" kubectl wait --for=jsonpath='{.status.phase}'=Failed pod/ko --timeout=120s

section "Can we scale now?"
check "kubectl scale deployment pingpong (from the note)" bash -ec "$(block 'Can we scale now' 1)"
check "kubectl scale deployment/pingpong, the other form (from the note)" bash -ec "$(block 'Can we scale now' 2)"
check "3 Pods become ready" kubectl wait --for=jsonpath='{.status.readyReplicas}'=3 deploy/pingpong --timeout=120s
check_output "kubectl get pods lists them (from the note)" '^3$' bash -c "$(block 'Can we scale now' 3) | grep -c '^pingpong-'"

section "Scaling a Replica Set"
kubectl scale "$rs" --replicas=5 >/dev/null
check "the Deployment scales its ReplicaSet back to 3" \
  retry 30 bash -c "[ \"\$(kubectl get $rs -o jsonpath='{.spec.replicas}')\" = 3 ]"
kubectl wait --for=delete pod -l app=pingpong --field-selector=status.phase!=Running --timeout=60s >/dev/null 2>&1 || true
retry 60 bash -c '[ "$(kubectl get pods -l app=pingpong --no-headers | wc -l)" = 3 ]' || true

section "Checking Deployment logs"
check_output "kubectl logs deploy/pingpong --tail 2 shows 2 lines (from the note)" '^2$' \
  bash -ec "$(block 'Checking Deployment logs' 1) 2>/dev/null | grep -c 'bytes from'"
check_output "it says which Pod it used" 'Found 3 pods, using pod/pingpong-' bash -ec "$(block 'Checking Deployment logs' 1) 2>&1 >/dev/null"

section "Resilience"
victim=$(podname)
start=$(date +%s)
check "kubectl delete pod (from the note)" bash -ec "$(note_block "$NOTE" 'Resilience' 2 | sed "s/pingpong-xxxxxxxxxx-yyyyy/$victim/") --wait=false"

section "What happened?"
check "the ReplicaSet replaces it while it is Terminating" retry 20 bash -c \
  "[ \"\$(kubectl get pods -l app=pingpong --no-headers | grep -c Running)\" = 3 ] && kubectl get pod $victim -o jsonpath='{.metadata.deletionTimestamp}' | grep -q ."
check_output "its logs can still be read" 'bytes from' kubectl logs "$victim" --tail 1
check_output "with a 30 second grace period" '^30$' kubectl get pod "$victim" -o jsonpath='{.metadata.deletionGracePeriodSeconds}'
kubectl wait --for=delete "pod/$victim" --timeout=90s >/dev/null
took=$(($(date +%s) - start))
check "ping (PID 1) ignores TERM, so it is killed at the end of the grace period (${took}s)" test "$took" -ge 25

section "Deleting a standalone Pod"
check "kubectl delete pod pingpong (from the note)" bash -ec "$(block 'Deleting a standalone Pod' 1)"
sleep 3
check_fails "no replacement Pod" kubectl get pod pingpong
