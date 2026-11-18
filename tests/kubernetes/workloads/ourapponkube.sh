#!/usr/bin/env bash
# note: kubernetes/workloads/ourapponkube.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace
# retry_out N CMD...: like retry, but prints the output of the first run that exits 0 with
# some output. retry discards output, so check_output cannot use it.
retry_out() {
  local n=$1 i out=
  shift
  for ((i = 1; i <= n; i++)); do
    out=$("$@" 2>&1) && [[ -n $out ]] && { printf '%s\n' "$out"; return 0; }
    sleep 1
  done
  printf '%s\n' "$out"
  return 1
}

NOTE=kubernetes/workloads/ourapponkube
cd "$(mktemp -d)"
node_ip() { kubectl get node "$CLUSTER-worker" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }

section "Running our application on Kubernetes"
check "kubectl create deployment redis (from the note)" bash -ec "$(note_block "$NOTE" 'Running our application' 1)"
check "kubectl create deployment for the other components (from the note)" bash -ec "$(note_block "$NOTE" 'Running our application' 2)"
for d in redis hasher rng webui worker; do
  check "deploy/$d becomes available" kubectl rollout status "deploy/$d" --timeout=300s
done

section "Deploying other images"
loop=$(note_block "$NOTE" 'Deploying other images' 1)
dry='--dry-run=client -o yaml --image='
check_output "the loop makes the same four Deployments, image REGISTRY/SERVICE:TAG (dry run)" \
  '^dockercoins/hasher:v0.1 dockercoins/rng:v0.1 dockercoins/webui:v0.1 dockercoins/worker:v0.1 $' \
  bash -ec "${loop//--image=/$dry} | sed -n 's/^ *- image: //p' | tr '\n' ' '"

section "Is this working?"
check_output "rng is fine (from the note)" 'Running on http' bash -ec "$(note_block "$NOTE" 'Is this working?' 1) 2>&1"
check_output "worker cannot resolve redis yet" 'Error.*redis|redis.*(not known|resolution)' retry_out 120 bash -c "kubectl logs deploy/worker 2>&1 | grep -iE 'error.*redis|redis.*(not known|resolution)'"
check_output "and says it waits 10s" 'Waiting 10s and restarting' bash -c "kubectl logs deploy/worker"

section "Connecting containers together"
check "kubectl expose redis, rng, hasher (from the note)" bash -ec "$(note_block "$NOTE" 'Connecting containers together' 1)"
check_output "three Services, worker and webui not exposed" '^hasher redis rng $' bash -c "kubectl get svc -o name | sed 's|.*/||' | sort | tr '\n' ' '"

section "Is this working yet?"
# The worker logs "0 units of work done" before each failed try too: look for real work.
check_output "the worker recovers (from the note, with a timeout)" '[1-9][0-9]* units of work done, updating hash counter' \
  bash -c "timeout 60 $(note_block "$NOTE" 'Is this working yet?' 1) | grep -m1 -E '[1-9][0-9]* units of work done'"

section "Exposing services for external access"
check "kubectl expose webui as NodePort (from the note)" bash -ec "$(note_block "$NOTE" 'Exposing services' 1)"
check_output "kubectl get svc shows the allocated port (from the note)" 'webui +NodePort .*80:3[0-9]{4}/TCP' bash -ec "$(note_block "$NOTE" 'Exposing services' 2)"
port=$(kubectl get svc webui -o jsonpath='{.spec.ports[0].nodePort}')
check "the port is in 30000-32767" test "$port" -ge 30000 -a "$port" -le 32767

section "Accessing the web UI"
check_output "the web UI answers on a node's IP and the node port" 'DockerCoin Miner WebUI' retry_out 30 curl -fsSL "http://$(node_ip):$port/"
cp_ip=$(kubectl get node "$CLUSTER-control-plane" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
check_output "on any node, the control plane too" 'DockerCoin Miner WebUI' retry_out 30 curl -fsSL "http://$cp_ip:$port/"
check_output "the counter goes up" '"hashes":"[1-9][0-9]*"' retry_out 60 curl -fsS "http://$(node_ip):$port/json"
