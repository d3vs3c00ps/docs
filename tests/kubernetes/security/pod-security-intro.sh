#!/usr/bin/env bash
# note: kubernetes/security/pod-security-intro.md
# env: kind
# timeout: 600
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/security/pod-security-intro
use_test_namespace   # private kubeconfig copy: kns below changes only it
cleanup() { kubectl delete namespace green --ignore-not-found --wait=false >/dev/null 2>&1; _k8s_exit; }
trap '_k8s_rc=$?; cleanup' EXIT
# `kns` (kubens, from kubectx) sets the current context's namespace; a stand-in.
KNS='kns() { kubectl config set-context --current --namespace="$1" >/dev/null; }'
run() { bash -ec "$KNS; $1"; }

section "Setting up a namespace"
check "create the green namespace (from the note)" run "$(note_block "$NOTE" 'Setting up a namespace' 1)"
check "kns green (from the note)" run "$(note_block "$NOTE" 'Setting up a namespace' 2)"
check_output "the context now defaults to green" '^green$' \
  kubectl config view --minify -o jsonpath='{.contexts[0].context.namespace}'

section "Creating a basic Deployment"
check "deploy NGINX (from the note)" run "$(note_block "$NOTE" 'Creating a basic Deployment' 1)"
kubectl rollout status deployment/web --timeout=180s >/dev/null
check_output "Deployment, ReplicaSet and a Running Pod exist (from the note)" \
  'deployment.apps/web.*replicaset.apps/web-.*Running|pod/web-.*Running' \
  bash -c "$(note_block "$NOTE" 'Creating a basic Deployment' 2) | tr '\n' ' '"

section "One example of malicious pods"
skip "the upstream escalation DaemonSet (hacktheplanet.yaml)" \
  "not run by these tests on purpose; pod-security-admission tests that admission control rejects hostPath DaemonSets, which is the mitigation this note leads to"

section "Admission plugins"
assert_no_match "PodSecurityPolicy was removed in 1.25: the API no longer serves it" 'podsecuritypolicies' \
  "$(kubectl api-resources --api-group=policy -o name)"
check_output "PodSecurity admission is on by default: a namespace label enforces it" \
  'violates PodSecurity "baseline' bash -c '
    kubectl create ns psa-probe-$$ >/dev/null
    kubectl label ns psa-probe-$$ pod-security.kubernetes.io/enforce=baseline >/dev/null
    kubectl -n psa-probe-$$ run p --image=busybox --restart=Never \
      --overrides="{\"spec\":{\"hostPID\":true}}" -- true 2>&1 || true
    kubectl delete ns psa-probe-$$ --wait=false >/dev/null'

section "Validating Admission Policies"
check_output "ValidatingAdmissionPolicy is GA: served in admissionregistration.k8s.io/v1" \
  'validatingadmissionpolicies' kubectl api-resources --api-group=admissionregistration.k8s.io -o wide
check_output "at v1" 'admissionregistration.k8s.io/v1 ' \
  bash -c "kubectl api-resources --api-group=admissionregistration.k8s.io | grep -i validatingadmissionpolic"
