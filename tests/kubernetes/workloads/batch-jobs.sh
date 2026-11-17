#!/usr/bin/env bash
# note: kubernetes/workloads/batch-jobs.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/batch-jobs
cd "$(mktemp -d)"
# job_state JOB: Complete, Failed, or nothing while it runs.
job_state() { kubectl get job "$1" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' | grep -oE 'Complete|Failed'; }
job_reason() { kubectl get job "$1" -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}'; }

section "Creating a Job"
check "kubectl create job flipcoin (from the note)" bash -ec "$(note_block "$NOTE" 'Creating a Job' 1)"
check_output "the default backoff limit is 6" '^6$' kubectl get job flipcoin -o jsonpath='{.spec.backoffLimit}'

section "Our Job in action"
check_output "its Pods carry job-name=flipcoin (from the note)" '^flipcoin-' \
  bash -c "$(note_block "$NOTE" 'Our Job in action' 1) -o name | sed 's|pod/||'"
# 1 run in 128 fails every time, so wait for either end, then run the note's block.
check "the Job ends, complete or failed" retry 700 job_state flipcoin
if [[ $(job_state flipcoin) == Complete ]]; then
  check "kubectl wait for complete (from the note)" bash -ec "$(note_block "$NOTE" 'Our Job in action' 2)"
else
  check_output "no luck at all: BackoffLimitExceeded" '^BackoffLimitExceeded$' job_reason flipcoin
fi
# A Job that always fails, with backoffLimit 2: 3 failed Pods (the first try and two
# retries), then Failed/BackoffLimitExceeded. With the default 6, that is 7 Pods.
kubectl create job always-fails --image=alpine --dry-run=client -o yaml -- sh -c 'exit 1' |
  sed 's/^spec:/spec:\n  backoffLimit: 2/' | kubectl apply -f - >/dev/null
check "a Job out of retries fails" kubectl wait --for=condition=failed job/always-fails --timeout=240s
check_output "with the reason BackoffLimitExceeded" '^BackoffLimitExceeded$' job_reason always-fails
check_output "after backoffLimit + 1 failed Pods" '^3$' \
  bash -c "kubectl get pods -l job-name=always-fails --no-headers | wc -l"
check_output "failed Pods stay, in Error state" '^3$' \
  bash -c "kubectl get pods -l job-name=always-fails --no-headers | grep -c Error"
check "so their logs can be read" kubectl logs "$(kubectl get pods -l job-name=always-fails -o name | head -1)"
times=$(kubectl get pods -l job-name=always-fails -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{"\n"}{end}' | sort)
gaps=$(python3 -c "
import sys, datetime as d
t = [d.datetime.fromisoformat(x.replace('Z', '+00:00')) for x in sys.argv[1].split()]
print(' '.join(str(int((b - a).total_seconds())) for a, b in zip(t, t[1:])))" "$times")
check "the delay between tries grows ($gaps seconds)" bash -c "set -- $gaps; [ \$2 -gt \$1 ]"

section "Completions and parallelism"
check_fails "kubectl create job has no --completions option" kubectl create job x --image=alpine --completions=3 --dry-run=client
note_block "$NOTE" 'Completions and parallelism' 1 >parallel.yaml
check "the Indexed Job (from the note)" kubectl apply -f parallel.yaml
check "all 6 complete" kubectl wait --for=condition=complete job/parallel --timeout=180s
check_output "6 Pods succeeded" '^6$' kubectl get job parallel -o jsonpath='{.status.succeeded}'
idx=$(for p in $(kubectl get pods -l job-name=parallel -o name); do kubectl logs "$p"; done | sort | tr '\n' ' ')
assert_eq "each Pod got its own JOB_COMPLETION_INDEX, 0 to 5" "item 0 item 1 item 2 item 3 item 4 item 5 " "$idx"
starts=$(kubectl get pods -l job-name=parallel -o jsonpath='{range .items[*]}{.status.startTime}{"\n"}{end}' | sort | uniq -c | awk '{ print $1 }' | sort -n | tail -1)
check "no more than 3 ran at once (at most $starts started in the same second)" test "$starts" -le 3

section "Setting a time limit"
note_block "$NOTE" 'Setting a time limit' 1 >too-slow.yaml
kubectl apply -f too-slow.yaml >/dev/null
check "a Job past activeDeadlineSeconds fails" kubectl wait --for=condition=failed job/too-slow --timeout=60s
check_output "with the reason DeadlineExceeded" '^DeadlineExceeded$' job_reason too-slow
check_output "its Pods are deleted, with no retry" '^0$' bash -c "kubectl get pods -l job-name=too-slow --no-headers 2>/dev/null | wc -l"
check_output "and it counts one failure" '^1$' kubectl get job too-slow -o jsonpath='{.status.failed}'
# A Pod deadline instead: that Pod stops, and the Job tries again.
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: batch/v1
kind: Job
metadata: {name: pod-deadline}
spec:
  backoffLimit: 1
  template:
    spec:
      activeDeadlineSeconds: 5
      restartPolicy: Never
      containers: [{name: work, image: alpine, command: ["sleep", "60"]}]
YAML
check "with a Pod deadline, the Job retries: a second Pod" \
  retry 90 bash -c '[ "$(kubectl get pods -l job-name=pod-deadline --no-headers | wc -l)" -ge 2 ]'
check_output "the stopped Pod's reason is DeadlineExceeded" 'DeadlineExceeded' \
  kubectl get pods -l job-name=pod-deadline -o jsonpath='{.items[*].status.reason}'

section "Cleaning up"
note_block "$NOTE" 'Cleaning up' 1 | sed 's/ttlSecondsAfterFinished: 30/ttlSecondsAfterFinished: 5/' >cleanup.yaml
check "a Job with ttlSecondsAfterFinished (from the note, 5 s instead of 30)" kubectl apply -f cleanup.yaml
check "it is deleted after it finishes" retry 90 bash -c '! kubectl get job cleanup >/dev/null 2>&1'
check_output "with its Pods" '^0$' bash -c "kubectl get pods -l job-name=cleanup --no-headers 2>/dev/null | wc -l"
kubectl delete job flipcoin >/dev/null
check_output "kubectl delete job deletes its Pods too" '^0$' \
  bash -c "sleep 3; kubectl get pods -l job-name=flipcoin --no-headers 2>/dev/null | wc -l"

section "Scheduling periodic background work"
cj=$(kubectl create cronjob tz --image=alpine --schedule='0 3 * * *' --dry-run=client -o yaml -- true)
check "spec.timeZone accepts Europe/Paris" bash -c "sed 's/^spec:/spec:\n  timeZone: Europe\/Paris/' <<<'$cj' | kubectl apply -f -"
check_output "and rejects an unknown zone" 'timeZone' bash -c "sed 's/^spec:/spec:\n  timeZone: Mars\/Olympus/' <<<'$cj' | kubectl apply -f - 2>&1; true"

section "Creating a Cron Job"
check "kubectl create cronjob every3mins (from the note)" bash -ec "$(note_block "$NOTE" 'Creating a Cron Job' 1)"
check_output "kubectl get cronjobs lists it (from the note)" 'every3mins +\*/3 \* \* \* \*' bash -ec "$(note_block "$NOTE" 'Creating a Cron Job' 2)"
check_output "concurrencyPolicy defaults to Allow" '^Allow$' kubectl get cronjob every3mins -o jsonpath='{.spec.concurrencyPolicy}'
check_output "history limits default to 3 successful and 1 failed" '^3 1$' \
  kubectl get cronjob every3mins -o jsonpath='{.spec.successfulJobsHistoryLimit} {.spec.failedJobsHistoryLimit}'

section "Cron Jobs in action"
check "run it now, with --from=cronjob (from the note)" bash -ec "$(note_block "$NOTE" 'Cron Jobs in action' 2)"
check "that Job completes" kubectl wait --for=condition=complete job/every3mins-now --timeout=120s
# A every-minute copy, to see a scheduled run without waiting three minutes.
kubectl create cronjob every1min --schedule='* * * * *' --image=alpine -- sleep 1 >/dev/null
check "at the scheduled time, the CronJob creates a Job" \
  retry 90 bash -c 'kubectl get jobs -o name | grep -q "every1min-"'
check_output "named after the CronJob and the time" '^every1min-[0-9]+$' \
  bash -c "kubectl get jobs -o name | sed 's|job.batch/||' | grep every1min | head -1"
check_output "kubectl get jobs lists it (from the note)" 'every1min-' bash -ec "$(note_block "$NOTE" 'Cron Jobs in action' 1)"
check "suspend (from the note)" bash -ec "$(sed -n 's/.*`\(kubectl patch cronjob every3mins .*\)`.*/\1/p' "$NOTES_ROOT/content/$NOTE.md")"
check_output "the CronJob is suspended" '^true$' kubectl get cronjob every3mins -o jsonpath='{.spec.suspend}'
