#!/usr/bin/env bash
# note: kubernetes/networking/ingress-advanced.md
# env: kind
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
use_test_namespace
WORK=$(mktemp -d); cd "$WORK"
curl -fsSL "$UPSTREAM/k8s/traefik.yaml" >traefik.yaml
cleanup() { kubectl delete -f "$WORK/traefik.yaml" --ignore-not-found >/dev/null 2>&1; _k8s_exit; }
trap '_k8s_rc=$?; cleanup' EXIT
kubectl apply -f traefik.yaml >/dev/null

# An echo backend that reports the request headers it received.
kubectl create deployment echo --image=mendhak/http-https-echo:37 >/dev/null
kubectl expose deployment echo --port=8080 >/dev/null
kubectl rollout status deployment/echo --timeout=180s >/dev/null
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
kubectl create ingress echo --rule="echo.$NODE_IP.nip.io/*=echo:8080" >/dev/null

section "External traffic policy"
check_output "externalTrafficPolicy accepts Cluster and Local" 'Local' bash -c '
  kubectl create service nodeport etp --tcp=80 >/dev/null
  kubectl patch service etp -p "{\"spec\":{\"externalTrafficPolicy\":\"Local\"}}" >/dev/null
  kubectl get service etp -o jsonpath={.spec.externalTrafficPolicy}'
check "internalTrafficPolicy is stable: the field is accepted (note's callout)" \
  kubectl patch service etp -p '{"spec":{"internalTrafficPolicy":"Local"}}'
# The "no local pod → connection refused" behaviour is exercised in
# kubernetes/networking/service-types ("Local is a hard rule").

section "Other ways to save hops: DaemonSet on port 80"
check_output "the controller answers directly on each node's port 80" '404' \
  curl -s --retry 20 --retry-all-errors -o /dev/null -w '%{http_code}' "http://$NODE_IP/does-not-exist"

section "Source IP address"
body=$(curl -fs --retry 20 --retry-all-errors "http://echo.$NODE_IP.nip.io/ip-probe")
assert_match "the controller injects x-forwarded-for (scenario 1: direct connection)" \
  '"x-forwarded-for"' "$body"
assert_match "and the app sees a real client address in it" \
  '"x-forwarded-for": *"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$body"
