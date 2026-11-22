#!/usr/bin/env bash
# note: kubernetes/security/csr-api.md
# env: kind
# timeout: 600
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/security/csr-api
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
use_test_namespace   # private kubeconfig copy: the context switches below stay in it
WORK=$(mktemp -d)
cd "$WORK"
export HOME=$WORK/home
mkdir -p "$HOME/container.training/k8s"
curl -fsSL "$UPSTREAM/k8s/user=jean.doe.yaml" >"$HOME/container.training/k8s/user=jean.doe.yaml"
ADMIN_CTX=$(kubectl config current-context)
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
cleanup() {
  kubectl --context "$ADMIN_CTX" delete csr user=jean.doe --ignore-not-found >/dev/null 2>&1
  kubectl --context "$ADMIN_CTX" delete clusterrolebinding,clusterrole user=jean.doe --ignore-not-found >/dev/null 2>&1
  kubectl --context "$ADMIN_CTX" delete namespace users --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl config use-context "$ADMIN_CTX" >/dev/null 2>&1
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT

# `kctx -` (from kubectx) switches to the previous context; a stand-in that does the same.
export KCTX_PREV=$WORK/kctx-prev
KCTX='kctx() { local cur; cur=$(kubectl config current-context); kubectl config use-context "$(cat "$KCTX_PREV")"; echo "$cur" >"$KCTX_PREV"; }'
run() { bash -ec "$KCTX; $1"; }
rejected() { "$@" || true; }

section "Creating the user's resources"
check "create the users namespace and jean.doe's ServiceAccount and RBAC (from the note)" \
  run "$(note_block "$NOTE" "Creating the user's resources" 1); $(note_block "$NOTE" "Creating the user's resources" 2)"

section "Extracting the user's token"
TOKEN=$(run "$(note_block "$NOTE" "Extracting the user's token" 1)")
assert_match "kubectl create token prints a JWT" '^ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$' "$TOKEN"
check_output "and no token Secret exists any more (the note's correction)" '^$' \
  kubectl -n users get secrets -o name

section 'Configure `kubectl` to use the token'
check "set-credentials with the token" \
  run "$(note_block "$NOTE" 'Configure `kubectl`' 1 | sed "s|--token=\.\.\.|--token=$TOKEN|")"
check "set-context, adapted to this cluster's name as the note says" \
  run "$(note_block "$NOTE" 'Configure `kubectl`' 2 | sed "s|--cluster=kubernetes|--cluster=$CLUSTER_NAME|")"
echo "$ADMIN_CTX" >"$KCTX_PREV"
check "use-context jean.doe" run "$(note_block "$NOTE" 'Configure `kubectl`' 3)"

section "Access the API with the token"
check_output "any resource: Forbidden, as the ServiceAccount" \
  'Forbidden.*system:serviceaccount:users:jean.doe' \
  rejected run "$(note_block "$NOTE" 'Access the API with the token' 1)"
check_output "our CSR: NotFound (we may get it, it does not exist yet)" 'NotFound' \
  rejected run "$(note_block "$NOTE" 'Access the API with the token' 2)"

section "Create a key and a CSR"
check "openssl generates key.pem and csr.pem (from the note)" \
  run "$(note_block "$NOTE" 'Create a key and a CSR' 1)"
check_output "the CSR claims CN=jean.doe, O=devs" 'CN *= *jean\.doe|O *= *devs' \
  openssl req -in csr.pem -noout -subject
assert_match "the subject has both fields" 'O *= *devs.*CN *= *jean\.doe|CN *= *jean\.doe.*O *= *devs' \
  "$(openssl req -in csr.pem -noout -subject)"

section "Sending the CSR to Kubernetes"
check "jean.doe creates the CSR object (from the note)" \
  run "$(note_block "$NOTE" 'Sending the CSR to Kubernetes' 1 | sed 's/^  //')"
check_output "it is Pending" 'Pending' kubectl get csr user=jean.doe

section "Verifying and approving the CSR"
check "kctx - goes back to the admin context" run "$(note_block "$NOTE" 'Verifying and approving' 1)"
check_output "describe shows the requested subject (from the note)" 'jean\.doe' \
  run "$(note_block "$NOTE" 'Verifying and approving' 2)"
check "approve it (from the note)" run "$(note_block "$NOTE" 'Verifying and approving' 3)"

section "Obtaining the certificate"
check "kctx - goes back to jean.doe" run "$(note_block "$NOTE" 'Obtaining the certificate' 1)"
check "jean.doe can read the issued certificate (from the note)" \
  retry 30 run "$(note_block "$NOTE" 'Obtaining the certificate' 2); test -s cert.pem"
check_output "the certificate is for jean.doe in devs" 'Subject:.*CN *= *jean\.doe' \
  run "$(note_block "$NOTE" 'Obtaining the certificate' 3)"
lifetime=$(( $(date -d "$(openssl x509 -in cert.pem -noout -enddate | cut -d= -f2)" +%s) \
  - $(date -d "$(openssl x509 -in cert.pem -noout -startdate | cut -d= -f2)" +%s) ))
assert_match "expirationSeconds: 3600 gives a ~1 hour certificate, not a year" '^(3[0-9]{3}|[4-9][0-9]{3})$' "$lifetime"

section "Using the certificate"
check "add the key and certificate to kubeconfig (from the note)" \
  run "$(note_block "$NOTE" 'Using the certificate' 1)"
check "point the jean.doe context at them (from the note)" \
  run "$(note_block "$NOTE" 'Using the certificate' 2)"
check_output "now seen as User \"jean.doe\" (no longer the ServiceAccount), still without permissions" \
  'Forbidden.*User "jean\.doe" cannot list resource "pods"' \
  rejected run "$(note_block "$NOTE" 'Using the certificate' 3)"
