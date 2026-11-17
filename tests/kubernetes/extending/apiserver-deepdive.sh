#!/usr/bin/env bash
# note: kubernetes/extending/apiserver-deepdive.md
# env: kind
# timeout: 300
# The verb mapping, seen from the authorizer: a ServiceAccount with no rights is
# refused, and the refusal names the Kubernetes verb.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

PORT=$((20000 + RANDOM % 20000))
kubectl proxy --port="$PORT" >/dev/null 2>&1 &
trap '_k8s_rc=$?; kill %1 2>/dev/null || true; _k8s_exit' EXIT
retry 30 curl -sf "localhost:$PORT/version"
SA=system:serviceaccount:$TEST_NS:default
P=localhost:$PORT/api/v1/namespaces/$TEST_NS/configmaps
# as METHOD PATH [CURL ARGS]: the refusal message, as the ServiceAccount.
as() {
  curl -s -X "$1" -H "Impersonate-User: $SA" -H 'Content-Type: application/json' "${@:3}" "$2" | jq -r .message
}

section "HTTP verb mapping"
check_output "POST → create (from the note)" 'cannot create resource "configmaps"' as POST "$P" -d '{"metadata":{"name":"x"}}'
check_output "PUT → update (from the note)" 'cannot update resource "configmaps"' as PUT "$P/x" -d '{"metadata":{"name":"x"}}'
check_output "PATCH → patch (from the note)" 'cannot patch resource "configmaps"' as PATCH "$P/x" -H 'Content-Type: application/merge-patch+json' -d '{}'
check_output "DELETE with a name → delete (from the note)" 'cannot delete resource "configmaps"' as DELETE "$P/x"
check_output "DELETE without a name → deletecollection (from the note)" 'cannot deletecollection resource "configmaps"' as DELETE "$P"
check_output "GET with a name → get (from the note)" 'cannot get resource "configmaps"' as GET "$P/x"
check_output "GET without a name → list (from the note)" 'cannot list resource "configmaps"' as GET "$P"
check_output "GET with ?watch=true → watch (from the note)" 'cannot watch resource "configmaps"' as GET "$P?watch=true"
check_output "HEAD is authorized like GET (from the note)" '^403$' bash -c \
  "curl -s -o /dev/null -w '%{http_code}' -I -H 'Impersonate-User: $SA' $P/x"

section "AuthN and AuthZ"
check_output "WithImpersonation: kubectl --as (from the note)" "^$SA$" \
  kubectl auth whoami --as="$SA" -o jsonpath='{.status.userInfo.username}'
check_output "system:masters bypasses Priority and Fairness: the exempt FlowSchema (from the note)" '"name":"system:masters"' \
  kubectl get flowschema exempt -o jsonpath='{.spec.rules[*].subjects}'
check_output "(and its priority level is exempt)" '^Exempt$' \
  kubectl get prioritylevelconfiguration exempt -o jsonpath='{.spec.type}' --ignore-not-found
check_output "the main source file of the note's links is still there" '^200$' \
  curl -s -o /dev/null -w '%{http_code}' https://github.com/kubernetes/apiserver/blob/release-1.32/pkg/server/config.go
