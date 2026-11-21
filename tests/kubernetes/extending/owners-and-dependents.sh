#!/usr/bin/env bash
# note: kubernetes/extending/owners-and-dependents.md
# env: kind
# timeout: 600
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/extending/owners-and-dependents
# run BLOCK: run a note block as the reader copies it (the list indentation removed).
run() { bash -ec "$(dedent <<<"$1")" 2>&1; }
dedent() { awk 'NF{m=match($0,/[^ ]/)-1; if(min==""||m<min)min=m} {l[NR]=$0} END{for(i=1;i<=NR;i++)print substr(l[i],min+1)}'; }

section "Finding out the owners of an object"
check "kubectl create deployment yanginx (from the note)" run "$(note_block "$NOTE" 1)"
check "kubectl scale --replicas=3 (from the note)" run "$(note_block "$NOTE" 2)"
kubectl rollout status deploy/yanginx --timeout=180s >/dev/null
check_output "the pods are owned by a ReplicaSet yanginx-xxxxxxxxxx (from the note)" \
  'kind: ReplicaSet' run "$(note_block "$NOTE" 3)"
check_output "(its name, within the first 25 lines)" 'name: yanginx-[a-z0-9]{8,10}$' run "$(note_block "$NOTE" 3)"

section "Listing objects with their owners"
check_output "custom-columns with the owner (from the note)" '^yanginx-\S+ +ReplicaSet +yanginx-[a-z0-9]+$' run "$(note_block "$NOTE" 4)"
check_output "(indented lines insert spaces and break the option, as the note says)" 'error|unexpected|invalid' \
  bash -c "$(note_block "$NOTE" 4 | sed 's/^ */    /') 2>&1; true"

section "Orphaning pods"
check_output "--cascade=false still works, but is deprecated for --cascade=orphan (the correction)" \
  'cascade=false is deprecated.*--cascade=orphan' bash -c "kubectl delete deployment -l app=yanginx --cascade=false --dry-run=client 2>&1"
check "delete the Deployment with --cascade=orphan (from the note)" run "$(note_block "$NOTE" 5)"
check_output "(the ReplicaSet stays)" '^replicaset.apps/yanginx-' kubectl get rs -l app=yanginx -o name
check "delete the ReplicaSet, orphaning its pods (from the note)" run "$(note_block "$NOTE" 6)"
check_output "the pods are still here (from the note)" '^3$' bash -c \
  "kubectl get pods -l app=yanginx --no-headers | grep -c Running"
check_output "with no owner left" '^$' bash -c \
  "kubectl get pods -l app=yanginx -o jsonpath='{.items[*].metadata.ownerReferences}'"

section "Finding and deleting orphan pods"
kubectl run owned-check --image=busybox:1.37 -- sleep 3600 >/dev/null
kubectl create job owned-job --image=busybox:1.37 -- sleep 3600 >/dev/null
retry 60 bash -c "kubectl get pods -l job-name=owned-job -o name | grep -q ."
check_output "jq lists the pods with no owner (from the note)" '^owned-check yanginx-[^ ]+ yanginx-[^ ]+ yanginx-[^ ]+ $' \
  bash -c "$(note_block "$NOTE" 8 | dedent) | sort | tr '\n' ' '"
check "and | xargs kubectl delete pod deletes them (from the note)" run "$(note_block "$NOTE" 9)"
check_output "only the Job's pod is left" '^owned-job-' bash -c "kubectl get pods -o name | cut -d/ -f2"
check_output "(nothing else)" '^1$' bash -c "kubectl get pods --no-headers | wc -l | tr -d ' '"

section "Deletion policy"
check_output "kubectl delete --help: the three policies (from the note)" 'Must be "background", "orphan", or "foreground".*Defaults to background' bash -c \
  "kubectl delete --help | grep -A1 -- '--cascade=' | tr -s ' \n' ' '"
check "foreground: the API call returns after the dependents are deleted (from the note)" \
  kubectl delete job owned-job --cascade=foreground --wait=true
check_output "(the Job's pod is gone too)" '^0$' bash -c "kubectl get pods --no-headers 2>/dev/null | wc -l | tr -d ' '"
