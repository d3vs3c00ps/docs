#!/usr/bin/env bash
# note: kubernetes/security/authn-authz.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/security/authn-authz
use_test_namespace
WORK=$(mktemp -d)
cd "$WORK"
CP=$CLUSTER-control-plane
cleanup() {
  kubectl delete clusterrole notes-widget-viewer --ignore-not-found >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
run() { bash -ec "$1" 2>&1; }
rejected() { "$@" || true; }
# The note works in the default namespace; these tests run in their own.
ns() { sed "s/default:default/$TEST_NS:default/g; s/sa default /sa default -n $TEST_NS /g" <<<"$1"; }

section "Who are we?"
check_output "kubectl auth whoami (from the note)" 'Username +kubernetes-admin' \
  run "$(note_block "$NOTE" 'Who are we?' 1)"
check_output "the kubeadm admin group" 'Groups +\[kubeadm:cluster-admins' \
  run "$(note_block "$NOTE" 'Who are we?' 1)"

section "Inspecting a certificate"
check_output "the note's pipeline shows CN and O of our certificate" \
  'Subject: O *= *kubeadm:cluster-admins, CN *= *kubernetes-admin' \
  run "$(note_block "$NOTE" 'Inspecting a certificate' 1)"

section "Inspecting a token"
# Our kubeconfig uses a certificate; build one whose first user has a token.
TOKEN=$(kubectl create token default)
kubectl config view --raw --minify -o json \
  | jq --arg t "$TOKEN" '.users[0].user = {token: $t}' >token.kubeconfig
check_output "the note's pipeline decodes the JWT payload" \
  "\"sub\": *\"system:serviceaccount:$TEST_NS:default\"" \
  env KUBECONFIG="$WORK/token.kubeconfig" bash -c "$(note_block "$NOTE" 'Inspecting a token' 1) 2>/dev/null"

section "Listing service accounts"
check_output "there is a default ServiceAccount (from the note)" '^default ' \
  run "$(note_block "$NOTE" 'Listing service accounts' 1)"

section "Finding the secret"
check_output "since 1.24 it has no token Secret, as the note says: .secrets[0] is null" '^null$' \
  run "$(ns "$(note_block "$NOTE" 'Finding the secret' 1)"); echo \"\$SECRET\""
check_output "kubectl create token default is the replacement" '^ey[A-Za-z0-9_-]+\.' \
  kubectl create token default

section "Using the token"
API=$(kubectl get svc kubernetes -n default -o json | jq -r .spec.clusterIP)
check_output "the kubernetes Service has a ClusterIP (from the note)" '^10\.96\.0\.1$' echo "$API"
# The ClusterIP is reachable from a node.
check_output "without a token: Forbidden, as system:anonymous" 'User \\"system:anonymous\\"' \
  docker exec "$CP" curl -sk "https://$API"
check_output "with the token: Forbidden, as the ServiceAccount" \
  "User \\\\\"system:serviceaccount:$TEST_NS:default\\\\\"" \
  docker exec "$CP" curl -sk -H "Authorization: Bearer $TOKEN" "https://$API"

section "Examples (API discovery)"
check_output "verbs served for core resources (from the note)" '^deletecollection$' \
  run "$(note_block "$NOTE" 11)"
check_output "resources in apps/v1 (from the note)" '^deployments$' run "$(note_block "$NOTE" 12)"
check_output "resources and verbs in networking.k8s.io/v1 (from the note)" '^ingresses: create, delete' \
  run "$(note_block "$NOTE" 13)"

section "Running a pod"
arch=$(kubectl get node "$CP" -o jsonpath='{.status.nodeInfo.architecture}')
img=$(note_block "$NOTE" 'Running a pod' 1 | grep -o 'nixery.dev/[^ ]*')
[[ $arch == arm64 ]] && img=${img/nixery.dev\//nixery.dev\/arm64\/}
# eyepod CMD: the note's pod, with a command instead of an interactive bash.
eyepod() {
  kubectl run "eyepod-$RANDOM" --rm -i --quiet --restart=Never --image "$img" \
    --pod-running-timeout=5m -- bash -c "$1" 2>&1
}
check_output "kubectl in the pod (default ServiceAccount): pods are forbidden" \
  "forbidden: User \"system:serviceaccount:$TEST_NS:default\" cannot list resource \"pods\"" \
  rejected eyepod "$(note_block "$NOTE" 'Checking our permissions' 1)"

section "Binding a role to the service account"
check "create the can-view rolebinding (from the note)" run "$(ns "$(note_block "$NOTE" 'Binding a role' 1)")"

section "Checking our new permissions"
check_output "now the pod can list pods" 'NAME|eyepod' \
  eyepod "$(note_block "$NOTE" 'Checking our new permissions' 1)"
check_output "but not create a Deployment (view is read-only)" 'forbidden.*cannot create resource "deployments"' \
  rejected eyepod "$(note_block "$NOTE" 'Checking our new permissions' 2)"

section 'kubectl run --serviceaccount'
check_output "kubectl run no longer has --serviceaccount (the note's update)" 'unknown flag: --serviceaccount' \
  rejected kubectl run x --image=alpine --serviceaccount=default --dry-run=client
kubectl create serviceaccount my-service-account >/dev/null
check_output "the override sets serviceAccountName (from the note, as a server dry run)" '^my-service-account$' \
  run "$(note_block "$NOTE" 'kubectl run --serviceaccount' 1 | sed 's/ -ti / /') --dry-run=server -o jsonpath='{.spec.serviceAccountName}'"

section 'kubectl auth can-i dothis onthat'
while read -r line; do
  [[ -z $line ]] && continue
  check_output "$line" '^(yes|no)' rejected run "$line"
done <<<"$(note_block "$NOTE" 'kubectl auth can-i dothis onthat' 1)"

section 'kubectl auth can-i ... --as someoneelse'
check_output "as some-user: no" '^no' rejected run "$(note_block "$NOTE" 'as someoneelse' 1 | sed -n 1,2p)"
check_output "as our ServiceAccount: no (view does not include nodes)" '^no' rejected run \
  "$(note_block "$NOTE" 'as someoneelse' 1 | sed -n 3,4p | sed "s/<namespace>/$TEST_NS/; s/<name-of-service-account>/default/")"

section 'kubectl auth can-i --list'
check_output "lists our permissions (from the note)" 'Resources +Non-Resource URLs' \
  run "$(note_block "$NOTE" 'kubectl auth can-i --list' 1)"

section "Customizing the default roles (aggregation)"
labels=$(note_block "$NOTE" 'Customizing the default roles' 1)
assert_match "the note's labels" 'rbac.authorization.k8s.io/aggregate-to-view: "true"' "$labels"
# shellcheck disable=SC2001 # anchored, per-line edit of a multi-line string
kubectl apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: notes-widget-viewer
$(sed 's/^    //' <<<"$labels" | sed 1d)
rules:
- {apiGroups: [example.com], resources: [widgets], verbs: [get, list, watch]}
EOF
check "a ClusterRole with those labels is aggregated into view, edit and admin" retry 30 bash -c \
  'for r in view edit admin; do kubectl get clusterrole $r -o yaml | grep -q widgets || exit 1; done'
check_output "view is built by the note's aggregationRule" \
  'rbac.authorization.k8s.io/aggregate-to-view' kubectl get clusterrole view -o jsonpath='{.aggregationRule}'

section "Where do our permissions come from?"
check_output "the note's grep finds the groups in ClusterRoleBindings" 'kubeadm:cluster-admins' \
  run "$(note_block "$NOTE" 'Where do our permissions come from?' 1)"
check_output "kubeadm:cluster-admins is bound to cluster-admin (the correction)" '^cluster-admin kubeadm:cluster-admins$' \
  kubectl get clusterrolebinding kubeadm:cluster-admins -o jsonpath='{.roleRef.name} {.subjects[*].name}'
check_output "system:masters now only in super-admin.conf" 'O *= *system:masters' bash -c \
  "docker exec $CP cat /etc/kubernetes/super-admin.conf | grep client-certificate-data | awk '{print \$2}' | base64 -d | openssl x509 -noout -subject"

section 'The system:masters group'
check_output "the cluster-admin binding gives cluster-admin to system:masters (from the note)" \
  'Group +system:masters' run "$(note_block "$NOTE" 'The `system:masters` group' 1)"
check_output "and cluster-admin is basically root: * on *.* (from the note)" '\*\.\* +\[\] +\[\] +\[\*\]' \
  run "$(note_block "$NOTE" 'The `system:masters` group' 2)"
