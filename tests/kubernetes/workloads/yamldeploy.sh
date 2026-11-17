#!/usr/bin/env bash
# note: kubernetes/workloads/yamldeploy.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/yamldeploy
cd "$(mktemp -d)"
run() { bash -ec "$(note_block "$NOTE" "$@")"; }
replicas() { kubectl get deploy purple -o jsonpath='{.spec.replicas}'; }

section "Why use YAML? (1/3)"
check_fails "kubectl create has no daemonset subcommand" kubectl create daemonset x --image=alpine --dry-run=client
check_fails "nor a statefulset one" kubectl create statefulset x --image=alpine --dry-run=client
check_fails "kubectl create deployment has no option for limits" kubectl create deployment x --image=alpine --limits=cpu=1 --dry-run=client

section "Why use YAML? (2/3)"
url=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/nginx-1-without-volume.yaml
check_output "kubectl create -f accepts a URL" 'pod/nginx-without-volume created \(server dry run\)' \
  kubectl create -f "$url" --dry-run=server
mkdir directory-with-yaml
kubectl create configmap one --dry-run=client -o yaml >directory-with-yaml/one.yaml
kubectl create configmap two --dry-run=client -o yaml >directory-with-yaml/two.yaml
check_output "and a directory" 'configmap/two created' kubectl create -f directory-with-yaml/

section "Overrides and kubectl set"
check_fails "kubectl create deployment has no --overrides" kubectl create deployment x --image=alpine --overrides '{}' --dry-run=client
check_output "kubectl run --overrides patches the generated YAML" '^overridden$' \
  kubectl run x --image=alpine --dry-run=client -o jsonpath='{.metadata.labels.run}' \
  --overrides '{"metadata": {"labels": {"run": "overridden"}}}'

section "Writing a Pod manifest"
check_output "kubectl run --dry-run=client -o yaml prints a Pod (from the note)" '^kind: Pod$' run 'Writing a Pod manifest' 1
check "save it to pod-purple.yaml (from the note)" run 'Writing a Pod manifest' 2
check_output "the file holds the Pod" '^  name: purple$' cat pod-purple.yaml

section "Running the Pod"
check "kubectl create -f pod-purple.yaml (from the note)" run 'Running the Pod' 1
check "the Pod runs" kubectl wait --for=condition=ready pod/purple --timeout=180s
check_output "kubectl get pods lists it (from the note)" '^purple +1/1 +Running' run 'Running the Pod' 2

section "Comparing with direct kubectl run"
check "kubectl run yellow (from the note)" run 'Comparing with direct' 1
kubectl wait --for=condition=ready pod/yellow --timeout=180s >/dev/null
check "both manifests can be read (from the note)" run 'Comparing with direct' 2
spec() { kubectl get pod "$1" -o json | jq -S '.spec | del(.nodeName, .volumes, .containers[].volumeMounts, .containers[].name)'; }
assert_eq "the two Pods have the same spec, but for their names" "$(spec purple)" "$(spec yellow)"

section "Generating a Deployment manifest"
check_output "generate the Deployment YAML (from the note)" '^kind: Deployment$' run 'Generating a Deployment manifest' 1
check "save it (from the note)" run 'Generating a Deployment manifest' 2
check "kubectl create -f (from the note)" run 'Generating a Deployment manifest' 3
check_output "it has replicas: 1" '^  replicas: 1$' cat deployment-purple.yaml

section "Updating our Deployment"
skip "vim deployment-purple.yaml" "interactive editor; the test changes the line with sed"
sed -i 's/^  replicas: 1$/  replicas: 2/' deployment-purple.yaml

section "Applying our changes"
out=$(bash -c "$(note_block "$NOTE" 'Applying our changes' 1)" 2>&1) && rc=0 || rc=$?
assert_eq "kubectl create on an existing resource fails (from the note)" 1 "$rc"
assert_match "with AlreadyExists, as the comment says" 'AlreadyExists' "$out"
check_output "and the Deployment is not changed" '^1$' replicas

section "kubectl apply vs create"
check_output "kubectl create stores no last-applied annotation" '^$' \
  kubectl get deploy purple -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}'

section "Trying kubectl apply"
check "delete the Deployment (from the note)" run 'Trying `kubectl apply`' 1
check "create it with kubectl apply (from the note)" run 'Trying `kubectl apply`' 2
check_output "it has the edited replica count" '^2$' replicas
skip "vim deployment-purple.yaml (again)" "interactive editor; the test changes the line with sed"
sed -i 's/^  replicas: 2$/  replicas: 3/' deployment-purple.yaml
check_output "apply the new manifest (from the note)" 'deployment.apps/purple configured' run 'Trying `kubectl apply`' 4
check_output "the existing Deployment is updated" '^3$' replicas

section "create -> apply"
check_output "kubectl apply added last-applied-configuration" '"replicas":3' \
  kubectl get deploy purple -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}'
# A ConfigMap over 256 KiB: create works, apply fails, because the annotation would be too big.
python3 -c "print('apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: huge\ndata:\n  x: ' + 'a' * 300000)" >huge.yaml
check_output "for a huge object, the annotation is too long for kubectl apply" 'Too long' \
  bash -c 'kubectl apply -f huge.yaml 2>&1; true'
check "but kubectl create works" kubectl create -f huge.yaml

section "Adding a Service"
check_output "kubectl expose -o yaml --dry-run=client (from the note)" '^kind: Service$' run 'Adding a Service' 1
check "save it (from the note)" run 'Adding a Service' 2
check_output "kubectl expose of a missing Deployment fails, even with --dry-run=client" 'NotFound' \
  bash -c 'kubectl expose deployment nothing --port 80 -o yaml --dry-run=client 2>&1; true'

section "What if the Deployment doesn't exist?"
out=$(run "What if the Deployment doesn't exist?" 1)
assert_match "kubectl create service clusterip --tcp 80 (from the note)" '^kind: Service$' "$out"
assert_match "port 80, to target port 80" 'port: 80' "$out"

section "Combining manifests"
check "the loop builds app-purple.yaml (from the note)" run 'Combining manifests' 1
check_output "with two documents" '^2$' bash -c "grep -c '^---$' app-purple.yaml"

section "Resource ordering"
cat >ordering.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: in-new-ns, namespace: $TEST_NS-order}
---
apiVersion: v1
kind: Namespace
metadata: {name: $TEST_NS-order}
EOF
# kubectl create goes on after the error and makes the Namespace: remove it on exit.
trap '_k8s_rc=$?; kubectl delete namespace "$TEST_NS-order" --ignore-not-found --wait=false >/dev/null 2>&1; _k8s_exit' EXIT
check_output "a resource listed before its Namespace fails" 'not found' bash -c 'kubectl create -f ordering.yaml 2>&1; true'
kubectl delete -f ordering.yaml --ignore-not-found --wait=false >/dev/null 2>&1 || true

section "Using -f with other commands"
kubectl delete deploy purple >/dev/null
check "kubectl apply -f app-purple.yaml (from the note)" run 'Using `-f` with other commands' 1
check "kubectl label -f (from the note)" run 'Using `-f` with other commands' 2
check_output "both have release=production" '^purple purple$' \
  bash -c "kubectl get deploy,svc -l release=production -o jsonpath='{.items[*].metadata.name}'"
check "kubectl delete -f (from the note)" run 'Using `-f` with other commands' 3
check_output "both are gone" '^$' bash -c "kubectl get deploy,svc -l app=purple -o name"

section "Pruning resources"
# Every prune here is scoped to TEST_NS and a label: a cluster-wide prune would delete
# applied Namespaces of the whole cluster. The note's --prune --all warning is not run.
rm directory-with-yaml/*
kubectl create configmap kept --dry-run=client -o yaml | kubectl label --local -f - app=myapp -o yaml >directory-with-yaml/kept.yaml
kubectl create configmap removed --dry-run=client -o yaml | kubectl label --local -f - app=myapp -o yaml >directory-with-yaml/removed.yaml
kubectl apply -f directory-with-yaml/ >/dev/null
rm directory-with-yaml/removed.yaml
check_output "--prune alone fails" 'without explicitly passing --all' \
  bash -c "kubectl apply -n $TEST_NS -f directory-with-yaml/ --prune --dry-run=server 2>&1; true"
prune=$(note_block "$NOTE" 'Pruning resources' 1 | sed "s/-n myapp/-n $TEST_NS/")
check_output "the dry run lists what would be pruned (from the note)" 'configmap/removed pruned \(server dry run\)' \
  bash -c "$prune --dry-run=server 2>&1"
check_output "--prune -l removes what left the directory (from the note)" 'configmap/removed pruned' bash -ec "$prune"
check "and keeps the rest" kubectl get configmap kept
check "but not what kubectl create made" kubectl get configmap one huge
