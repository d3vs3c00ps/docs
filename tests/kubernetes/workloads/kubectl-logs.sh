#!/usr/bin/env bash
# note: kubernetes/workloads/kubectl-logs.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/kubectl-logs
cd "$(mktemp -d)"
# pods_in TEXT: how many different Pods appear in --prefix output.
pods_in() { grep -o '^\[pod/[^/]*' <<<"$1" | sort -u | wc -l | tr -d ' '; }

# pingpong as in kubectl-run, scaled to 3 Pods.
kubectl create deployment pingpong --image=alpine --replicas=3 -- ping 127.0.0.1 >/dev/null
check "pingpong runs, with 3 Pods" kubectl wait --for=condition=available deploy/pingpong --timeout=180s

section "Streaming logs of multiple pods"
out=$(timeout 5 bash -c "$(note_block "$NOTE" 'Streaming logs of multiple pods' 1)" 2>&1) || true
assert_match "kubectl logs deploy/... follows one Pod (from the note)" 'Found 3 pods, using pod/pingpong-' "$out"
assert_match "and prints its ping lines" 'bytes from 127.0.0.1' "$out"
out=$(timeout 5 kubectl logs deploy/pingpong --tail 1 --follow --prefix 2>/dev/null) || true
assert_eq "only one Pod's lines come out" 1 "$(pods_in "$out")"
out=$(kubectl logs deploy/pingpong --all-pods --tail 1)
assert_eq "--all-pods shows every Pod, prefixed" 3 "$(pods_in "$out")"

section "Viewing logs of multiple pods"
check_output "the Pods carry app=pingpong" '^3$' bash -c "kubectl get pods -l app=pingpong --no-headers | wc -l"
out=$(bash -ec "$(note_block "$NOTE" 'Viewing logs of multiple pods' 1)")
assert_eq "-l app=pingpong --tail 1 prints one line per Pod (from the note)" 3 "$(grep -c 'bytes from' <<<"$out")"

section "Streaming logs of all pingpong pods"
out=$(timeout 5 bash -c "$(note_block "$NOTE" 'Streaming logs of all pingpong pods' 1) --prefix" 2>&1) || true
assert_eq "-l and -f together stream all 3 Pods (from the note, with --prefix)" 3 "$(pods_in "$out")"

section "Streaming logs of many pods"
check "scale to 8 (from the note)" bash -ec "$(note_block "$NOTE" 'Streaming logs of many pods' 1)"
kubectl wait --for=condition=available deploy/pingpong --timeout=180s >/dev/null
expected=$(note_block "$NOTE" 'Streaming logs of many pods' 3)
out=$(timeout 10 bash -c "$(note_block "$NOTE" 'Streaming logs of many pods' 2)" 2>&1) && rc=0 || rc=$?
assert_eq "following 8 streams fails (from the note)" 1 "$rc"
assert_eq "with the message the note shows" "$expected" "$out"

section "Why can't we stream the logs of many pods?"
check_output "--max-log-requests is 5 by default" '--max-log-requests=5:' kubectl logs --help
out=$(timeout 5 kubectl logs -l app=pingpong --tail 1 -f --max-log-requests=8 --prefix 2>&1) || true
assert_eq "--max-log-requests=8 lifts the limit" 8 "$(pods_in "$out")"
kubectl scale deployment pingpong --replicas=3 >/dev/null
kubectl wait --for=jsonpath='{.status.replicas}'=3 deploy/pingpong --timeout=120s >/dev/null

section "Shortcomings of kubectl logs"
out=$(kubectl logs -l app=pingpong --tail 1)
assert_no_match "without --prefix, lines do not say which Pod sent them" '^\[pod/' "$out"
out=$(kubectl logs -l app=pingpong --tail 1 --prefix)
assert_match "--prefix adds [pod/<name>/<container>]" '^\[pod/pingpong-[^/]+/alpine\] ' "$out"
# Stream in the background, add a Pod, then replace every Pod.
kubectl logs -l app=pingpong -f --prefix >stream.log 2>&1 &
stream=$!
sleep 3
kubectl scale deployment pingpong --replicas=4 >/dev/null
kubectl wait --for=condition=available deploy/pingpong --timeout=120s >/dev/null
sleep 3
new=$(kubectl get pods -l app=pingpong -o name --sort-by=.metadata.creationTimestamp | tail -1 | sed 's|pod/||')
check_fails "a new Pod's logs do not show up in the stream" grep -q "pod/$new/" stream.log
kubectl delete pods -l app=pingpong --grace-period=1 --wait=false >/dev/null
check "when the Pods are replaced, the stream stops" retry 60 bash -c "! kill -0 $stream 2>/dev/null"
kill "$stream" 2>/dev/null || true
