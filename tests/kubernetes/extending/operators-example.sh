#!/usr/bin/env bash
# note: kubernetes/extending/operators-example.md
# env: kind
# timeout: 600
# Runs nsplease.sh from the runner, with the test namespace as the requests namespace.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/extending/operators-example
HOME=$(mktemp -d)
export HOME
cd "$HOME"
NS=nsp-$TEST_NS
cleanup() {
  kill %1 2>/dev/null || true
  kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
mkdir bin
export PATH=$HOME/bin:$PATH
# shortcut: the runner has no gettext; this handles only the two variables of namespace-template.yaml.
# shellcheck disable=SC2016
printf '#!/bin/sh\nsed "s/\\$REQUESTS_NAMESPACE/$REQUESTS_NAMESPACE/g; s/\\$NAMESPACE/$NAMESPACE/g"\n' >bin/envsubst
chmod +x bin/envsubst

section "Show me the code!"
git clone -q --depth 1 https://github.com/jpetazzo/nsplease
cd nsplease
check_output "about 150 lines of code (from the note)" '^1[2-7][0-9]$' bash -c "wc -l <nsplease.sh | tr -d ' '"
check_output "the main loop is the note's excerpt" '^$' bash -c \
  "while read -r l; do [ -z \"\$l\" ] && continue; grep -qF -- \"\$l\" nsplease.sh || echo \"missing: \$l\"; done <<<\"\$1\"" _ "$(note_block "$NOTE" 1)"

section "Running the operator"
REQUESTS_NAMESPACE=$TEST_NS sh nsplease.sh >operator.log 2>&1 &
retry 30 grep -q 'Waiting for ConfigMap events' operator.log
check "a ConfigMap with a kubectl create configmap one-liner (from the note)" \
  kubectl create configmap "$NS" --from-literal=hello=world
check "the operator creates the Namespace" retry 60 kubectl get namespace "$NS"
check "and a Secret with the credentials, in the requests namespace" retry 60 bash -c \
  "kubectl get secret $NS -o jsonpath='{.data.token}' | grep -q ."
# --token is not enough here: the kubeconfig's client certificate wins. Impersonate the account.
SA=system:serviceaccount:$NS:admin
check_output "the credentials only give access to their Namespace (from the note)" '^yes no$' bash -c \
  "echo \$(kubectl auth can-i create deploy -n $NS --as=$SA) \$(kubectl auth can-i create deploy -n default --as=$SA || true)"
check_output "the token is for that ServiceAccount" "\"sub\":\"$SA\"" bash -c \
  "kubectl get secret $NS -o jsonpath='{.data.token}' | base64 -d | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null; true"
retry 60 bash -c "kubectl get configmap $NS -o jsonpath='{.metadata.ownerReferences[0].kind}' | grep -q Namespace"
check_output "the Namespace owns the ConfigMap and the Secret (from the note)" '^Namespace/nsp-.* Namespace/nsp-' bash -c \
  "echo \$(kubectl get configmap,secret $NS -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name} {end}')"
check_output "--output-watch-events gives the event type, so the script can skip deletions and edits" 'Got event: ADDED nsp-' cat operator.log

section "Resource ownership"
kill %1 2>/dev/null || true
check "with the operator stopped, delete the Namespace" kubectl delete namespace "$NS" --wait=true --timeout=180s
check "the ConfigMap is deleted automatically (from the note)" retry 60 bash -c "! kubectl get configmap $NS 2>/dev/null"
check "and so is the Secret (from the note)" retry 60 bash -c "! kubectl get secret $NS 2>/dev/null"
