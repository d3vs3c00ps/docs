#!/usr/bin/env bash
# note: kubernetes/workloads/record.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/record
cd "$(mktemp -d)"

# dockercoins/worker:v0.2 is amd64-only. Elsewhere an image string that differs but
# runs everywhere stands in for it: the history only needs a distinct Pod template.
arch=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')
V02=dockercoins/worker:v0.2
[[ $arch == amd64 ]] || V02=docker.io/dockercoins/worker:v0.1
block() { note_block "$NOTE" "$@" | sed "s|dockercoins/worker:v0.2|$V02|g"; }
# last_cause: the CHANGE-CAUSE column of the last revision.
last_cause() { kubectl rollout history deployment worker | awk '/^[0-9]/ { $1 = ""; c = $0 } END { sub(/^ +/, "", c); print c }'; }
export -f last_cause
revisions() { kubectl rollout history deployment worker | awk '/^[0-9]/ { print $1 }' | xargs; }

# The state the note starts from: worker on v0.2. The history only needs the
# Deployment, so the rest of DockerCoins is not deployed.
kubectl create deployment worker --image="$V02" >/dev/null
[[ $arch == amd64 ]] || skip "dockercoins/worker:v0.2 itself" "amd64-only image; on $arch the test uses $V02 for it"

section "Recording deployment actions"
check_output "--record still works, with a deprecation warning" 'Flag --record has been deprecated' \
  kubectl set image deployment worker worker="$V02" --record --dry-run=server
check_fails "--record is hidden from the help" bash -c 'kubectl set image --help | grep -q -- --record'

section "Using --record"
check "set image v0.1 --record (from the note)" bash -ec "$(block 'Using `--record`' 1)"
check "set image v0.2 --record (from the note)" bash -ec "$(block 'Using `--record`' 2)"
check_output "the history shows the command (from the note)" "kubectl set image deployment worker worker=$V02 .*--record=true" \
  bash -ec "$(block 'Using `--record`' 3)"
check_output "the Deployment carries it in kubernetes.io/change-cause" "worker=$V02" \
  kubectl get deploy worker -o jsonpath='{.metadata.annotations.kubernetes\.io/change-cause}'

section "Pitfall #1: forgetting --record"
check "set image v0.3 without --record (from the note)" bash -ec "$(block 'Pitfall #1' 1)"
check_output "it records version 0.2 instead of 0.3 (from the note)" "^4 +kubectl set image deployment worker worker=$V02 " \
  bash -c "$(block 'Pitfall #1' 2) | tail -2 | head -1"

section "How --record really works"
rs=$(kubectl get rs -l app=worker -o jsonpath='{range .items[?(@.spec.template.spec.containers[0].image=="dockercoins/worker:v0.3")]}{.metadata.name}{end}')
check_output "the new ReplicaSet got the old annotation" "worker=$V02" \
  kubectl get rs "$rs" -o jsonpath='{.metadata.annotations.kubernetes\.io/change-cause}'

section "Pitfall #2: recording scale commands"
check "scale --record (from the note)" bash -ec "$(block 'Pitfall #2' 2)"
# The controller copies the annotation to the ReplicaSet a moment later.
retry 20 bash -c '[[ "$(last_cause)" == "kubectl scale"* ]]' || true
check_output "the last entry is now the scale command (from the note)" '^4 +kubectl scale deployment worker .*--replicas=3 --record=true' \
  bash -c "$(block 'Pitfall #2' 3) | tail -2 | head -1"

section "Actions that don't create a new ReplicaSet"
check_output "scale created no new revision: 2 3 4, as before" '^2 3 4$' revisions

section "Updating the annotation directly"
check "kubectl annotate, without --overwrite (from the note)" bash -ec "$(block 'Updating the annotation directly' 1)"
retry 20 bash -c '[ "$(last_cause)" = "Just for fun" ]' || true
check_output "the annotation shows up in the history (from the note)" '^4 +Just for fun' \
  bash -c "$(block 'Updating the annotation directly' 2) | tail -2 | head -1"
kubectl annotate deployment worker other=1 >/dev/null
check_fails "other annotations need --overwrite" kubectl annotate deployment worker other=2

section "Setting the change cause without --record"
check "set image, then annotate (from the note)" bash -ec "$(note_block "$NOTE" 'Setting the change cause' 1)"
check "the new revision has the right cause" retry 20 bash -c '[ "$(last_cause)" = "Back to v0.1, v0.3 does not exist" ]'
check_output "and the previous one kept its own" '^4 +Just for fun' \
  bash -c "kubectl rollout history deployment worker | grep '^4 '"
# The manifest snippet is a fragment: merge it into the live Deployment.
check "the annotation in the manifest metadata (from the note)" \
  kubectl patch deployment worker --type=merge -p "$(note_block "$NOTE" 'Setting the change cause' 2)"
check "shows up in the history too" retry 20 bash -c '[ "$(last_cause)" = "Image v0.1, applied from git commit abc1234" ]'
