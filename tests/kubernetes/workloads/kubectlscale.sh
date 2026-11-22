#!/usr/bin/env bash
# note: kubernetes/workloads/kubectlscale.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/kubectlscale
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

# Setup: DockerCoins, as kubercoins.md deploys it.
kubectl apply -f "$UPSTREAM/k8s/dockercoins.yaml" >/dev/null
for d in hasher redis rng webui worker; do kubectl rollout status "deploy/$d" --timeout=300s >/dev/null; done
retry 60 bash -c '[ "$(kubectl exec deploy/redis -- redis-cli get hashes)" -gt 0 ]'
one=$(rate 20)

section "Scaling a deployment"
watches=$(note_block "$NOTE" 'Scaling a deployment' 1)
{ timeout 90 bash -c "$(sed -n 1p <<<"$watches")" >pods.log 2>&1 & } 2>/dev/null
{ timeout 90 bash -c "$(sed -n 2p <<<"$watches")" >deploys.log 2>&1 & } 2>/dev/null
sleep 3
check_output "kubectl scale --replicas=10 (from the note)" 'deployment.apps/worker scaled' bash -ec "$(note_block "$NOTE" 'Scaling a deployment' 2)"
check "the 10 workers become ready" kubectl rollout status deploy/worker --timeout=300s
check_output "10 worker Pods" '^10$' bash -c "kubectl get pods -l app=worker --no-headers | wc -l"
sleep 5
check_output "kubectl get pods -w shows Pods going from Pending to Running" 'worker-.*Pending' cat pods.log
check_output "and Running" 'worker-.* 1/1 +Running' cat pods.log
check_output "kubectl get deployments -w shows worker reaching 10/10" 'worker +10/10' cat deploys.log
sleep 10
ten=$(rate 30)
check "the speed goes up ($one/s with 1 worker, $ten/s with 10)" awk -v a="$one" -v b="$ten" 'BEGIN { exit !(b > a) }'
check "it peaks at about 10 hashes/second ($ten/s)" awk -v r="$ten" 'BEGIN { exit !(r > 7 && r <= 11.5) }'
