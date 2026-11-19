#!/usr/bin/env bash
# note: kubernetes/workloads/kubercoins.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/kubercoins
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
cd "$(mktemp -d)"
# The note uses ~/container.training: a private HOME with only the manifest it needs.
export HOME=$PWD
node_ip() { kubectl get node "$CLUSTER-worker" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }

section "Connecting to our Kubernetes cluster"
check_output "kubectl get nodes: all nodes Ready (from the note)" "$CLUSTER-worker +Ready" bash -ec "$(note_block "$NOTE" 'Connecting to our' 1)"
check "no node is NotReady" bash -c "! kubectl get nodes --no-headers | grep -q NotReady"

section "Cloning the repository"
url=$(note_block "$NOTE" 'Cloning the repository' 1 | awk '{ print $3 }')
check "the repository URL in the note answers ($url)" git ls-remote --exit-code "$url" HEAD
mkdir -p container.training/k8s
curl -fsSL "$UPSTREAM/k8s/dockercoins.yaml" -o container.training/k8s/dockercoins.yaml

section "Running the application"
check "kubectl apply dockercoins.yaml (from the note)" bash -ec "$(note_block "$NOTE" 'Running the application' 1)"
check_output "one Deployment per component" '^hasher redis rng webui worker$' \
  bash -c "kubectl get deploy -o name | sed 's|.*/||' | sort | tr '\n' ' ' | sed 's/ $//'"
check_output "a Service for each component except worker" '^hasher redis rng webui$' \
  bash -c "kubectl get svc -o name | sed 's|.*/||' | sort | tr '\n' ' ' | sed 's/ $//'"
check_output "images are dockercoins/<component>:v0.1 and redis" '^dockercoins/hasher:v0.1 redis dockercoins/rng:v0.1 dockercoins/webui:v0.1 dockercoins/worker:v0.1 $' \
  kubectl get deploy -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{" "}{end}'
for d in hasher redis rng webui worker; do
  check "deploy/$d becomes available" kubectl rollout status "deploy/$d" --timeout=300s
done

section "DockerCoins in the microservices era"
check_output "the upstream Compose file lists the 5 services" '^hasher redis rng webui worker $' \
  bash -c "curl -fsSL $UPSTREAM/dockercoins/compose.yml | sed -n 's/^  \([a-z]*\):\$/\1/p' | sort | tr '\n' ' '"
check_output "docker-compose.yml is gone from the main branch (404)" '^404$' \
  curl -sS -o /dev/null -w '%{http_code}' https://raw.githubusercontent.com/jpetazzo/container.training/main/dockercoins/docker-compose.yml

section "Example in worker/worker.py"
check "the worker code shown matches upstream" bash -c "curl -fsSL $UPSTREAM/dockercoins/worker/worker.py | grep -qF 'requests.get(\"http://rng/32\")' && curl -fsSL $UPSTREAM/dockercoins/worker/worker.py | grep -qF 'redis = Redis(\"redis\")'"

section "Our application at work"
check_output "the worker reports units of work (from the note)" '[1-9][0-9]* units of work done, updating hash counter' \
  retry_out 60 bash -ec "$(note_block "$NOTE" 'Our application at work' 1 | sed -n 1p) | grep -E '[1-9][0-9]* units of work done'"
check_output "the hasher logs one line per request (from the note)" 'POST /' \
  retry_out 30 bash -ec "$(note_block "$NOTE" 'Our application at work' 1 | sed -n 2p) | grep 'POST /'"

section "Connecting to the web UI"
check_output "kubectl get svc webui shows a NodePort (from the note)" 'webui +NodePort +[0-9.]+ +<none> +80:3[0-9]{4}/TCP' \
  bash -ec "$(note_block "$NOTE" 'Connecting to the web UI' 1)"
port=$(kubectl get svc webui -o jsonpath='{.spec.ports[0].nodePort}')
check_output "the web UI answers on a node, on that port" 'index.html|DockerCoin' retry_out 30 curl -fsSL "http://$(node_ip):$port/"
check_output "/json returns the counter from redis" '"hashes":"[0-9]+"' retry_out 30 curl -fsS "http://$(node_ip):$port/json"
# The runner shares the host network with other tests: no fixed local port.
lport=$((20000 + RANDOM % 20000))
kubectl port-forward svc/webui "$lport:80" >/dev/null 2>&1 &
pf=$!
check_output "kubectl port-forward also works" '"hashes"' retry_out 20 curl -fsS "http://localhost:$lport/json"
kill "$pf" 2>/dev/null || true
