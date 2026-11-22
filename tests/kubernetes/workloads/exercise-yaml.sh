#!/usr/bin/env bash
# note: kubernetes/workloads/exercise-yaml.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/exercise-yaml
cd "$(mktemp -d)"
arch=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')
# The note's foo123, made unique because the cluster is shared. Removed on exit.
NS=$TEST_NS-foo123
trap '_k8s_rc=$?; kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1; _k8s_exit' EXIT

# Strategy 1 needs wordsmith running: deploy it with the exercise-wordsmith solution.
bash -ec "$(note_block kubernetes/workloads/exercise-wordsmith 'Solution' 1)" >/dev/null

section "Strategies"
kubectl get deployment,service db words web -o yaml >raw.yaml
check_output "kubectl get -o yaml dumps the 3 Deployments and 3 Services" '^3 3$' \
  bash -c "echo \$(grep -c '^  kind: Deployment$' raw.yaml) \$(grep -c '^  kind: Service$' raw.yaml)"
check_output "kubercoins is where the note says" '^200$' \
  curl -s -o /dev/null -w '%{http_code}' https://github.com/jpetazzo/kubercoins

section "Cleaning up a dump"
kubectl create namespace "$NS" >/dev/null
check_output "a raw dump does not apply in another namespace" 'does not match the namespace' \
  bash -c "kubectl apply --namespace $NS -f raw.yaml 2>&1; true"
sed '/^    namespace: /d' raw.yaml >no-ns.yaml
check_output "without metadata.namespace, the Services ask for the same IP" 'provided IP is already allocated' \
  bash -c "kubectl apply --namespace $NS -f no-ns.yaml 2>&1; true"
kubectl delete --namespace "$NS" deployment --all >/dev/null
check "the jq clean-up (from the note)" bash -ec "$(note_block "$NOTE" 'Strategies' 1)"
check_output "it keeps the 6 objects" '^6$' jq '.items | length' wordsmith.json
check_output "and drops the live fields" '^\[\]$' \
  jq -c '[.items[] | (.metadata.namespace, .metadata.uid, .status, .spec.clusterIP, .spec.ports[]?.nodePort) | select(. != null)]' wordsmith.json

section "How to test our YAML"
check "step 2: kubectl apply --namespace foo123 -f XYZ" kubectl apply --namespace "$NS" -f wordsmith.json
step3=$(sed -n 's/.*`\(kubectl get service web --namespace foo123\)`.*/\1/p' "$NOTES_ROOT/content/$NOTE.md")
check_output "step 3 (from the note) shows the NodePort" '^web +NodePort +[0-9.]+ +<none> +80:[0-9]+/TCP' \
  bash -c "${step3/foo123/$NS}"
check_fails "the original step 3, without a namespace name, fails" kubectl get service web --namespace

# The images are amd64-only: an arm64 node runs them only if it emulates amd64 (Docker Desktop does).
if ! kubectl wait --namespace "$NS" --for=condition=available deploy/db deploy/web deploy/words --timeout=300s >/dev/null; then
  skip "step 4: connect to it and see the wordsmith app" "this $arch node cannot run the amd64-only wordsmith images"
  exit 0
fi
check "the copy becomes available (on $arch)" kubectl wait --namespace "$NS" --for=condition=available deploy/db deploy/web deploy/words --timeout=10s
port=$(kubectl get service web --namespace "$NS" -o jsonpath='{.spec.ports[0].nodePort}')
ip=$(kubectl get node "$CLUSTER-worker" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
check "step 4: web answers on the NodePort, with words from db" retry 120 curl -sf "http://$ip:$port/words/noun"
