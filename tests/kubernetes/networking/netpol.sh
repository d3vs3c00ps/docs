#!/usr/bin/env bash
# note: kubernetes/networking/netpol.md
# env: kind
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/networking/netpol
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
use_test_namespace

# The note's commands read ~/container.training/k8s/...: a fake HOME holds those files.
HOME=$(mktemp -d)
export HOME
cd "$HOME"
mkdir -p container.training/k8s
for f in netpol-deny-all-for-testweb.yaml netpol-allow-testcurl-for-testweb.yaml netpol-dockercoins.yaml; do
  curl -fsSL "$UPSTREAM/k8s/$f" >"container.training/k8s/$f"
done

# wget_from LABEL: fetch http://$IP from a pod labelled run=LABEL, 3s timeout.
wget_from() { kubectl run "$1" --rm -i --image=alpine --restart=Never -- wget -qO- -T3 "$IP" 2>&1; }

section "Running our test web server"
check "the note's lab: deployment testweb" \
  bash -ec "$(note_block "$NOTE" 'A first network policy' 1 | sed -n 1p)"
kubectl rollout status deployment/testweb --timeout=180s >/dev/null
IP=$(kubectl get pods -l app=testweb -o json | jq -r .items[0].status.podIP)
export IP   # the note's lab commands reference $IP
check "the pod IP was found with the note's command" test -n "$IP"
check_output "the server answers before any policy" 'Welcome to nginx!' wget_from pretest

section "Deny everything to the web server"
assert_eq "the inlined YAML matches the upstream file the lab applies" \
  "$(cat container.training/k8s/netpol-deny-all-for-testweb.yaml)" \
  "$(note_block "$NOTE" 'Deny everything' 1)"
check "apply the deny-all policy (from the note)" \
  bash -ec "$(note_block "$NOTE" 'Deny everything' 2 | sed -n 1p)"
check_fails "curl now times out" wget_from denied

section "Allow specific pods back in"
assert_eq "the inlined YAML matches the upstream file" \
  "$(cat container.training/k8s/netpol-allow-testcurl-for-testweb.yaml)" \
  "$(note_block "$NOTE" 'Allow specific pods' 1)"
labblock=$(note_block "$NOTE" 'Allow specific pods' 2)
check "apply the allow policy (from the note)" bash -ec "$(sed -n 1p <<<"$labblock")"
check_output "a pod labelled run=testcurl gets through" 'Welcome to nginx!' \
  bash -ec "$(sed -n 2p <<<"$labblock")"
check_fails "a pod with another label still times out" bash -ec "$(sed -n 3p <<<"$labblock")"

section "kubectl port-forward ignores network policies"
check_output "port-forward reaches the denied pod anyway" 'Welcome to nginx!' bash -c '
  kubectl port-forward deployment/testweb 18088:80 >/dev/null 2>&1 &
  pf=$!; sleep 3
  out=$(curl -fs http://127.0.0.1:18088); rc=$?
  kill $pf 2>/dev/null; echo "$out"; exit $rc'

section "Isolating a whole namespace"
kubectl delete networkpolicies --all >/dev/null
kubectl create deployment webui --image=nginx >/dev/null
kubectl create deployment internal --image=nginx >/dev/null
kubectl label deployment webui app=webui --overwrite >/dev/null
kubectl patch deployment webui -p '{"spec":{"template":{"metadata":{"labels":{"app":"webui"}}}}}' >/dev/null
kubectl rollout status deployment/webui deployment/internal --timeout=180s >/dev/null 2>&1 || {
  kubectl rollout status deployment/webui --timeout=180s >/dev/null
  kubectl rollout status deployment/internal --timeout=180s >/dev/null
}
WEBUI_IP=$(kubectl get pods -l app=webui -o json | jq -r '.items[0].status.podIP')
INT_IP=$(kubectl get pods -l app=internal -o json | jq -r '.items[0].status.podIP')
note_block "$NOTE" 'Isolating a whole namespace' 1 | kubectl apply -f - >/dev/null
note_block "$NOTE" 'Isolating a whole namespace' 2 | kubectl apply -f - >/dev/null
OTHER=$TEST_NS-other
kubectl create namespace "$OTHER" >/dev/null
trap '_k8s_rc=$?; kubectl delete namespace "$OTHER" --ignore-not-found >/dev/null 2>&1; _k8s_exit' EXIT
check_output "same namespace: pods still talk to each other" 'Welcome to nginx!' \
  kubectl run same-ns --rm -i --image=alpine --restart=Never -- wget -qO- -T3 "$INT_IP"
check_fails "other namespace: internal pods are blocked" \
  kubectl run cross-ns -n "$OTHER" --rm -i --image=alpine --restart=Never -- wget -qO- -T3 "$INT_IP"
check_output "other namespace: the webui pod stays reachable (allow-webui)" 'Welcome to nginx!' \
  kubectl run cross-ui -n "$OTHER" --rm -i --image=alpine --restart=Never -- wget -qO- -T3 "$WEBUI_IP"

section "Cleaning up our network policies"
cleanup_block=$(note_block "$NOTE" 'Isolating a whole namespace' 3)
assert_eq "the note's cleanup block (end of 'Isolating a whole namespace')" \
  'kubectl delete networkpolicies --all' "$cleanup_block"
check "the note's cleanup command" bash -ec "$cleanup_block"
check_output "traffic to testweb is unrestricted again" 'Welcome to nginx!' wget_from posttest
