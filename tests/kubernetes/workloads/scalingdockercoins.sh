#!/usr/bin/env bash
# note: kubernetes/workloads/scalingdockercoins.md
# env: kind
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/scalingdockercoins
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
cd "$(mktemp -d)"
# rate SECONDS: hashes per second, from the redis counter the workers update every second.
rate() {
  local a b
  a=$(kubectl exec deploy/redis -- redis-cli get hashes)
  sleep "$1"
  b=$(kubectl exec deploy/redis -- redis-cli get hashes)
  awk -v a="$a" -v b="$b" -v t="$1" 'BEGIN { printf "%.1f\n", (b - a) / t }'
}
# scale_and_rate BLOCK: run the note's scale block, wait for the rollout, print the rate.
scale_and_rate() {
  bash -ec "$1" >/dev/null
  kubectl rollout status deploy/worker --timeout=300s >/dev/null
  sleep 10
  rate 30
}
gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

# Setup: DockerCoins, as kubercoins.md deploys it.
kubectl apply -f "$UPSTREAM/k8s/dockercoins.yaml" >/dev/null
for d in hasher redis rng webui worker; do kubectl rollout status "deploy/$d" --timeout=300s >/dev/null; done
retry 60 bash -c '[ "$(kubectl exec deploy/redis -- redis-cli get hashes)" -gt 0 ]'
r1=$(rate 30)

section "Adding another worker"
{ timeout 60 bash -c "$(note_block "$NOTE" 'Adding another worker' 1)" >pods.log 2>&1 & } 2>/dev/null
r2=$(scale_and_rate "$(note_block "$NOTE" 'Adding another worker' 2)")
check_output "2 worker Pods (from the note)" '^2$' bash -c "kubectl get pods -l app=worker --no-headers | wc -l"
check "the speed goes up: $r1/s with 1 worker, $r2/s with 2" gt "$r2" "$r1"
check_output "kubectl get pods -w shows the new Pod" 'worker-' cat pods.log

section "Adding more workers"
r3=$(scale_and_rate "$(note_block "$NOTE" 'Adding more workers' 1)")
check "3 workers: up again ($r3/s)" gt "$r3" "$r2"

section "Adding even more workers"
r10=$(scale_and_rate "$(note_block "$NOTE" 'Adding even more workers' 1)")
check "10 workers: it peaks at about 10 hashes/second ($r10/s)" awk -v r="$r10" 'BEGIN { exit !(r > 7 && r <= 11.5) }'
check "not 10x the speed of one worker ($r1/s x 10)" gt "$(awk -v a="$r1" 'BEGIN { print a * 10 }')" "$r10"
kubectl scale deployment worker --replicas=20 >/dev/null
kubectl rollout status deploy/worker --timeout=300s >/dev/null
sleep 10
r20=$(rate 30)
check "20 workers: still not past 10 hashes/second ($r20/s)" awk -v r="$r20" 'BEGIN { exit !(r <= 11.5) }'
kubectl scale deployment worker --replicas=10 >/dev/null
# Old workers ignore SIGTERM and keep calling rng for 30 s: wait until only 10 are left.
retry 90 bash -c '[ "$(kubectl get pods -l app=worker --no-headers | wc -l)" -eq 10 ]'

section "Obtaining ClusterIP addresses"
ips=$(note_block "$NOTE" 'Obtaining ClusterIP addresses' 1)
eval "$ips"
export HASHER RNG
check_output "HASHER holds the ClusterIP of hasher (from the note)" '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' echo "$HASHER"
check_output "RNG holds the ClusterIP of rng (from the note)" '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' echo "$RNG"

section "Checking hasher and rng response times"
# httping runs in a Pod: ClusterIPs are not reachable from outside the cluster. Alpine has
# no httping package; Debian does. The ECR copy of the Docker official image avoids Hub limits.
kubectl run bench --image=public.ecr.aws/docker/library/debian:trixie-slim --command -- sleep 3600 >/dev/null
kubectl wait --for=condition=Ready pod/bench --timeout=600s >/dev/null ||
  { kubectl describe pod bench | tail -15; exit 1; }
check "httping installs in a Debian Pod" kubectl exec bench -- sh -c 'apt-get update -qq >/dev/null && apt-get install -y -qq httping >/dev/null 2>&1' 
check_fails "a ClusterIP does not answer from outside the cluster" curl -fsS -m 3 "http://$RNG/"
run_httping() { local c=${1#"${1%%[! ]*}"}; bash -ec "${c/#httping /kubectl exec bench -- httping }"; }
blk=$(note_block "$NOTE" 'Checking `hasher` and `rng` response times' 1)
out_hasher=$(run_httping "$(sed -n 1p <<<"$blk")")
out_rng=$(run_httping "$(sed -n 2p <<<"$blk")")
avg() { sed -n 's|.*min/avg/max = [0-9.]*/\([0-9.]*\)/.*|\1|p' <<<"$1"; }
h=$(avg "$out_hasher"); r=$(avg "$out_rng")
check "httping -c 3 \$HASHER (from the note) answers" test -n "$h"
check "httping -c 3 \$RNG (from the note) answers" test -n "$r"
check "hasher replies in a few milliseconds ($h ms)" awk -v v="$h" 'BEGIN { exit !(v < 50) }'
check "rng is slow with 10 workers ($r ms, the note says about 700)" awk -v v="$r" 'BEGIN { exit !(v > 300 && v < 1500) }'
