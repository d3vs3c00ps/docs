#!/usr/bin/env bash
# note: kubernetes/security/bootstrap.md
# env: kind
# timeout: 300
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/security/bootstrap
CP=$CLUSTER-control-plane
on() { docker exec "$CP" "$@"; }
# A token of our own, short-lived, so the checks do not depend on kind's.
TOKEN=$(on kubeadm token create --ttl 10m)
TID=${TOKEN%%.*}
cleanup() { on kubeadm token delete "$TID" >/dev/null 2>&1; _k8s_exit; }
trap '_k8s_rc=$?; cleanup' EXIT

section "Bootstrap tokens"
assert_match "a token is 6 public characters + 16 secret characters" '^[a-z0-9]{6}\.[a-z0-9]{16}$' "$TOKEN"
check_output "it is a Secret with type bootstrap.kubernetes.io/token" 'bootstrap.kubernetes.io/token' \
  kubectl -n kube-system get secret "bootstrap-token-$TID" -o jsonpath='{.type}'

section "Bootstrap tokens with kubeadm"
check_output "kubeadm tokens add the group system:bootstrappers:kubeadm:default-node-token" \
  'system:bootstrappers:kubeadm:default-node-token' bash -c \
  "kubectl -n kube-system get secret bootstrap-token-$TID -o jsonpath='{.data.auth-extra-groups}' | base64 -d"
check_output "ClusterRoleBinding kubeadm:kubelet-bootstrap binds that group to system:node-bootstrapper" \
  'system:node-bootstrapper.*system:bootstrappers:kubeadm:default-node-token' bash -c \
  "kubectl get clusterrolebinding kubeadm:kubelet-bootstrap -o jsonpath='{.roleRef.name} {.subjects[*].name}'"
check_output "that ClusterRole gives create/get/list/watch on the CSR API" \
  'certificatesigningrequests.*\[create get list watch\]' bash -c \
  "kubectl get clusterrole system:node-bootstrapper -o jsonpath='{range .rules[*]}{.resources} {.verbs}{\"\n\"}{end}' | tr -d '\"' | tr ',' ' '"

section "Bootstrap tokens in practice"
check_output "kubeadm token list shows it (from the note, on the control plane)" "^$TID\." \
  on bash -ec "$(note_block "$NOTE" 'Bootstrap tokens in practice' 1 | sed 's/^\( *\)sudo /\1/')"
check_output "the note's kubectl + jq one-liner rebuilds the tokens from the Secrets" "^$TOKEN\$" \
  bash -ec "$(note_block "$NOTE" 'Retrieving bootstrap tokens with kubectl' 1)"

section "Using a bootstrap token"
# Run from a node: 10.96.0.1 is the kubernetes Service, reachable there.
check_output "the token authenticates, but is not authorized for / (JSON message, as the note shows)" \
  "\"message\": \"forbidden: User \\\\\"system:bootstrap:$TID\\\\\" cannot get path \\\\\"/\\\\\"\"" \
  on curl -sk -H "Authorization: Bearer $TOKEN" https://10.96.0.1/
check_output "and it can use the CSR API" '"kind": *"CertificateSigningRequestList"' \
  on curl -sk -H "Authorization: Bearer $TOKEN" \
  https://10.96.0.1/apis/certificates.k8s.io/v1/certificatesigningrequests
assert_match "the note now gives the URL for the first curl" \
  'Bearer abcdef\.1234567890abcdef" \\ *> > *https://10\.96\.0\.1/' \
  "$(tr '\n' ' ' <"$NOTES_ROOT/content/$NOTE.md")"

section "The cluster-info ConfigMap"
# the bootstrap signer adds the token's signature a few seconds after it is created
retry 60 bash -c "kubectl -n kube-public get cm cluster-info -o jsonpath='{.data}' | grep -q jws-kubeconfig-$TID"
info=$(on bash -ec "$(note_block "$NOTE" 'The cluster-info ConfigMap' 1)")
assert_match "anyone can read it, without credentials (from the note)" '"name": *"cluster-info"' "$info"
assert_match "it holds a kubeconfig with the CA certificate" 'certificate-authority-data' "$info"
assert_match "and the API server address" 'server: https://' "$info"
assert_match "signed per token: a jws-kubeconfig-<token id> field" "jws-kubeconfig-$TID" "$info"
