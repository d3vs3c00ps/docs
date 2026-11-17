#!/usr/bin/env bash
# note: kubernetes/packaging/exercise-helm.md
# env: kind
# timeout: 900
# The exercise has no commands: this test solves levels 1 and 2 the way the hints say.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

use_test_namespace
HOME=$(mktemp -d)
export HOME
cd "$HOME"
arch=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')

# "The YAML manifests that we wrote earlier": the exercise-wordsmith solution, as YAML.
{
  for c in db web words; do
    kubectl create deployment "$c" --image="jpetazzo/wordsmith-$c:latest" --dry-run=client -o yaml
    echo ---
  done
  kubectl create service clusterip db --tcp=5432 --dry-run=client -o yaml
  echo ---
  kubectl create service clusterip words --tcp=8080 --dry-run=client -o yaml
  echo ---
  kubectl create service nodeport web --tcp=80 --dry-run=client -o yaml
} >wordsmith.yaml

section "Level 1: a chart to deploy wordsmith"
check "helm create (hint)" helm create wordsmith
check "delete the content of templates/ and put our YAML instead (hint)" bash -ec \
  'rm -rf wordsmith/templates/* && cp wordsmith.yaml wordsmith/templates/'
check "install the resulting chart (hint)" helm install wordsmith ./wordsmith
check_output "the 3 Deployments and 3 Services are there" '^3 3$' bash -c \
  'echo $(kubectl get deploy -o name | wc -l) $(kubectl get svc -o name | wc -l)'

section "Level 2: --set replicas=X"
# Our YAML has a replicas: 1 line in the words Deployment only.
awk '/^  name: words$/{w=1} w && /^  replicas: 1$/{$0="  replicas: {{ .Values.replicas }}"; w=0} 1' \
  wordsmith/templates/wordsmith.yaml >t.yaml && mv t.yaml wordsmith/templates/wordsmith.yaml
echo 'replicas: 5' >wordsmith/values.yaml
check "{{ .Values.replicas }} in the words Deployment, replicas: 5 in values.yaml (hint)" helm upgrade wordsmith ./wordsmith
check_output "the default is 5" '^5$' kubectl get deploy words -o jsonpath='{.spec.replicas}'
check "--set replicas=3" helm upgrade wordsmith ./wordsmith --set replicas=3
check_output "now 3" '^3$' kubectl get deploy words -o jsonpath='{.spec.replicas}'
check_output "the other Deployments keep 1" '^1 1$' bash -c \
  'echo $(kubectl get deploy db -o jsonpath={.spec.replicas}) $(kubectl get deploy web -o jsonpath={.spec.replicas})'

section "The app runs"
# The images are amd64-only: an arm64 node runs them only if it emulates amd64 (Docker Desktop does).
if kubectl wait --for=condition=available deploy/db deploy/web deploy/words --timeout=300s >/dev/null; then
  port=$(kubectl get service web -o jsonpath='{.spec.ports[0].nodePort}')
  ip=$(kubectl get node "$CLUSTER-control-plane" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  check "web answers on the NodePort, with words from db (on $arch)" retry 120 docker exec "$CLUSTER-control-plane" \
    curl -sf "http://$ip:$port/words/noun"
else
  skip "the app answers" "this $arch node cannot run the amd64-only wordsmith images"
fi

section "Level 3"
skip "changing the colors" "needs a registry account to build and push our own images"
