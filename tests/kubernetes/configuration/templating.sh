#!/usr/bin/env bash
# note: kubernetes/configuration/templating.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/configuration/templating
cd "$(mktemp -d)"
host_of() { kubectl get ingress front -o jsonpath='{.spec.rules[0].host}'; }

# The runner has no gettext: run envsubst from a multi-arch image (Docker Hub mirror, to
# avoid its pull limits). Exported, so the note's blocks, run with bash -c, find it.
ENVSUBST_IMAGE=mirror.gcr.io/library/nginx:1.29-alpine
envsubst() { docker run --rm -i -e HOSTNAME -e OTHER "$ENVSUBST_IMAGE" envsubst "$@"; }
export -f envsubst
export ENVSUBST_IMAGE
docker pull -q "$ENVSUBST_IMAGE" >/dev/null

section "Standard UNIX tools - sed"
note_block "$NOTE" 'Standard UNIX tools - `sed`' 1 >ingress.yaml
check "sed | kubectl apply (from the note)" bash -ec "$(note_block "$NOTE" 'Standard UNIX tools - `sed`' 2)"
check_output "the Ingress has the host www.example.com" '^www\.example\.com$' host_of
kubectl delete ingress front >/dev/null

section "Standard UNIX tools - envsubst"
note_block "$NOTE" 'Standard UNIX tools - `envsubst`' 1 >ingress.yaml
check "envsubst | kubectl apply (from the note)" bash -ec "$(note_block "$NOTE" 'Standard UNIX tools - `envsubst`' 2)"
check_output "the Ingress has the host www.example.com" '^www\.example\.com$' host_of
check_output "an unset variable becomes an empty string" '^host: $' \
  bash -c "unset HOSTNAME; echo 'host: \${HOSTNAME}' | envsubst"
check_output "every variable is replaced, not just ours" '^a=www.example.com b=x$' \
  bash -c "echo 'a=\${HOSTNAME} b=\$OTHER' | HOSTNAME=www.example.com OTHER=x envsubst"
check_output "a variable list limits the replacement (from the note)" '^a=www.example.com b=\$OTHER$' \
  bash -c "echo 'a=\${HOSTNAME} b=\$OTHER' >ingress.yaml; OTHER=x; export OTHER; $(note_block "$NOTE" 'Standard UNIX tools - `envsubst`' 3)"

section "Helm"
# A release is tracked, upgraded, rolled back and uninstalled. No --wait: the chart's
# image does not need to run for Helm to track the release.
helm create demo >/dev/null
check "helm install" helm install demo ./demo
check_output "helm keeps track of what is installed" '^demo$' helm list --short
check "helm upgrade" helm upgrade demo ./demo --set replicaCount=2
check "helm rollback" helm rollback demo 1
check_output "the rollback is revision 3, back to 1 replica" '^1$' kubectl get deploy demo -o jsonpath='{.spec.replicas}'
check "helm uninstall" helm uninstall demo
check_output "the release is gone" '^$' helm list --short

section "Kustomize"
mkdir k && kubectl create configmap c --from-literal=a=b --dry-run=client -o yaml >k/c.yaml
printf 'resources:\n- c.yaml\nnamePrefix: dev-\n' >k/kustomization.yaml
check "kubectl apply -k (Kustomize is built into kubectl)" kubectl apply -k k
check "  the transformed resource exists" kubectl get configmap dev-c
