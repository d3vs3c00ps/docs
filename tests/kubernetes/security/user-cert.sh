#!/usr/bin/env bash
# note: kubernetes/security/user-cert.md
# env: kind
# timeout: 600
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/security/user-cert
use_test_namespace   # private kubeconfig copy: set-credentials/set-context stay in it
WORK=$(mktemp -d)
cd "$WORK"
CP=$CLUSTER-control-plane
ADMIN_USER=$(kubectl config view --minify -o jsonpath='{.users[0].name}')
cleanup() {
  kubectl config set-context --current --user="$ADMIN_USER" >/dev/null 2>&1
  kubectl delete clusterrolebinding devs-can-view --ignore-not-found >/dev/null 2>&1
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
# The note's commands run on a control plane node with sudo; here, as root.
# (blocks inside callouts keep their list indentation, hence the leading spaces)
# shellcheck disable=SC2001 # anchored, per-line edit of a multi-line string
run() { bash -ec "$(sed 's/^\( *\)sudo /\1/' <<<"$1")"; }
rejected() { "$@" || true; }

section "How it works"
check_output "kubeadm points the API server at the CA (the note's grep, on the node)" \
  '--client-ca-file=/etc/kubernetes/pki/ca\.crt' \
  docker exec "$CP" bash -ec "$(note_block "$NOTE" 'How it works' 1 | sed 's/^\( *\)sudo /\1/')"

section "Locate the CA key and cert"
# "On a cluster deployed with kubeadm: the files will be in /etc/kubernetes/pki"
docker exec "$CP" cat /etc/kubernetes/pki/ca.crt >ca.crt
docker exec "$CP" cat /etc/kubernetes/pki/ca.key >ca.key
assert_match "ca.crt is there" 'BEGIN CERTIFICATE' "$(cat ca.crt)"
export CA_CRT=$WORK/ca.crt CA_KEY=$WORK/ca.key

section "Generating a key and CSR for our user"
check "generate a private key (from the note)" run "$(note_block "$NOTE" 'Generating a key and CSR' 1)"
check "generate a CSR (from the note)" run "$(note_block "$NOTE" 'Generating a key and CSR' 2)"

section "Generating a signed certificate"
check_output "the CSR carries CN=jerome and two O fields (from the note)" \
  'Subject: CN *= *jerome, O *= *devs, O *= *ops' \
  run "$(note_block "$NOTE" 'Generating a signed certificate' 1)"
check "sign it with the cluster CA (from the note)" \
  run "$(note_block "$NOTE" 'Generating a signed certificate' 2)"
check "the certificate verifies against the cluster CA" openssl verify -CAfile ca.crt user.crt

section "Adding the key and certificate to kubeconfig"
check "set-credentials jerome (from the note)" \
  run "$(note_block "$NOTE" 'Adding the key and certificate' 1)"

section "Using the new identity"
check "switch the context to jerome (from the note)" \
  run "$(note_block "$NOTE" 'Using the new identity' 1)"
out=$(rejected run "$(note_block "$NOTE" 'Using the new identity' 2)" 2>&1)

section "On a normal cluster"
assert_match "the key and cert are valid: the API server names User \"jerome\"..." \
  'User "jerome"' "$out"
assert_match "...but it is Forbidden to list pods, as the note shows" \
  'Error from server \(Forbidden\): pods is forbidden: User "jerome" cannot list resource "pods" in API group "" in the namespace' "$out"

section "Granting permissions"
# kind names its admin user kind-<cluster>; kubeadm's admin.conf calls it
# kubernetes-admin, which the note assumes. Give this kubeconfig that alias.
kubectl config view --raw -o jsonpath="{.users[?(@.name==\"$ADMIN_USER\")].user.client-certificate-data}" | base64 -d >admin.crt
kubectl config view --raw -o jsonpath="{.users[?(@.name==\"$ADMIN_USER\")].user.client-key-data}" | base64 -d >admin.key
kubectl config set-credentials kubernetes-admin --client-certificate=admin.crt --client-key=admin.key --embed-certs >/dev/null
check_output "the admin certificate is CN=kubernetes-admin, as the note says" 'CN *= *kubernetes-admin' \
  openssl x509 -in admin.crt -noout -subject
check "switch back to the admin identity (from the note)" \
  run "$(note_block "$NOTE" 'Granting permissions' 1)"
check "bind the view ClusterRole to the devs group (from the note)" \
  run "$(note_block "$NOTE" 'Granting permissions' 2)"

section "Testing the new permissions"
check "switch to jerome again (from the note)" \
  run "$(note_block "$NOTE" 'Testing the new permissions' 1)"
check_output "jerome, in group devs, can now list pods" 'No resources found|NAME' \
  run "$(note_block "$NOTE" 'Testing the new permissions' 2)"
check_output "but view is read-only" 'forbidden' \
  rejected kubectl create configmap jerome-was-here --from-literal=a=b
kubectl config set-context --current --user=kubernetes-admin >/dev/null

section 'kubeadm kubeconfig user'
# Issues a key and certificate from /etc/kubernetes/pki and prints a kubeconfig.
docker exec "$CP" kubeadm kubeconfig user --client-name=alice --org=devs >alice.kubeconfig
check_output "the generated kubeconfig embeds a client certificate" 'client-certificate-data' cat alice.kubeconfig
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
# kubeadm writes the in-cluster endpoint; reach the same API server through ours
check_output "and it works: alice (group devs) can list pods" 'No resources found|NAME' \
  kubectl --kubeconfig alice.kubeconfig --server "$server" -n "$TEST_NS" get pods
