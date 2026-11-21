#!/usr/bin/env bash
# note: kubernetes/tooling/dashboard.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/tooling/dashboard
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
use_test_namespace

# The note's commands read ~/container.training/k8s/...: a fake HOME holds those files.
HOME=$(mktemp -d)
export HOME
cd "$HOME"
mkdir -p container.training/k8s
for f in dashboard-insecure dashboard-with-token; do
  curl -fsSL "$UPSTREAM/k8s/$f.yaml" >"container.training/k8s/$f.yaml"
done
cleanup() {
  for f in dashboard-insecure dashboard-with-token; do
    kubectl delete -f "container.training/k8s/$f.yaml" --ignore-not-found >/dev/null 2>&1 || true
  done
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT

CP=$CLUSTER-control-plane
NODE_IP=$(kubectl get node "$CP" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
nodeport() { kubectl -n kubernetes-dashboard get svc kubernetes-dashboard -o jsonpath='{.spec.ports[0].nodePort}'; }
# dash SCHEME PATH [CURL_ARGS...]: a request to the dashboard's NodePort, from a node.
dash() { local s=$1 p=$2; shift 2; docker exec "$CP" curl -sSk "$@" "$s://$NODE_IP:$(nodeport)$p"; }
wait_dashboard() {
  kubectl -n kubernetes-dashboard rollout status deploy/kubernetes-dashboard --timeout=300s >/dev/null
}

section "dashboard-insecure.yaml"
check "apply the insecure manifest (from the note)" bash -ec "$(note_block "$NOTE" 2)"
wait_dashboard
check_fails "the old command, kubectl get svc dashboard, finds nothing (the correction)" kubectl get svc dashboard
check_output "the note's command: kubernetes-dashboard, a NodePort, with the 3xxxx port" \
  '^kubernetes-dashboard +NodePort .* 443:3[0-9]{4}/TCP' bash -ec "$(note_block "$NOTE" 3)"
check_output "no socat: the dashboard itself serves plain HTTP" 'enable-insecure-login' \
  kubectl -n kubernetes-dashboard get deploy kubernetes-dashboard -o jsonpath='{.spec.template.spec.containers[0].args}'
retry 30 dash http / -f
check_output "the UI answers over HTTP on the 3xxxx port" '<title>Kubernetes Dashboard' \
  dash http /
check_output "login can be skipped" '"skippable": *true' dash http /api/v1/login/skippable
check_output "and with no login at all we can read kube-system secrets: the backdoor" '"secrets": *\[' \
  dash http /api/v1/secret/kube-system
check "close the backdoor (from the note)" bash -ec "$(note_block "$NOTE" 4)"
kubectl wait --for=delete namespace/kubernetes-dashboard --timeout=180s >/dev/null 2>&1 || true

section "dashboard-with-token.yaml"
check "apply the manifest with a token (from the note)" bash -ec "$(note_block "$NOTE" 5)"
wait_dashboard
check_output "the token Secret is declared in the manifest, under its exact name" \
  '^kubernetes.io/service-account-token$' \
  kubectl -n kubernetes-dashboard get secret cluster-admin-token -o jsonpath='{.type}'
# The token controller fills the Secret a moment after it is created.
retry 30 bash -c "kubectl -n kubernetes-dashboard get secret cluster-admin-token -o jsonpath={.data.token} | grep -q ."
check_output "the note's describe shows a JWT" 'token: +eyJ' bash -ec "$(note_block "$NOTE" 6)"
TOKEN=$(kubectl -n kubernetes-dashboard get secret cluster-admin-token -o jsonpath='{.data.token}' | base64 -d)
kubectl config view --raw --minify -o json \
  | jq --arg t "$TOKEN" '.users[0].user = {token: $t}' >token.kubeconfig
check_output "the token is the cluster-admin ServiceAccount" \
  'system:serviceaccount:kubernetes-dashboard:cluster-admin' env KUBECONFIG="$HOME/token.kubeconfig" kubectl auth whoami
check_output "which may do anything" '^yes$' env KUBECONFIG="$HOME/token.kubeconfig" kubectl auth can-i '*' '*'
check_output "the note's command shows the 3xxxx port" 'kubernetes-dashboard +NodePort .* 443:3[0-9]{4}/TCP' \
  bash -ec "$(note_block "$NOTE" 7)"
retry 30 dash https / -f
check_output "the UI answers over HTTPS (self-signed), not HTTP" '<title>Kubernetes Dashboard' \
  dash https /
check_fails "plain HTTP on that port fails" docker exec "$CP" curl -fsS "http://$NODE_IP:$(nodeport)/"
check_output "login cannot be skipped" '"skippable": *false' dash https /api/v1/login/skippable
check_output "with the token, the dashboard API lists namespaces" '"name": *"kube-system"' \
  dash https /api/v1/namespace -H "Authorization: Bearer $TOKEN"
