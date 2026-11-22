#!/usr/bin/env bash
# note: kubernetes/networking/gateway-api.md
# env: kind
# timeout: 1800
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/networking/gateway-api
use_test_namespace
cleanup() {
  helm uninstall traefik --namespace traefik >/dev/null 2>&1
  kubectl delete namespace traefik --ignore-not-found --timeout=120s >/dev/null 2>&1
  kubectl get crd -o name 2>/dev/null | grep 'gateway.networking.k8s.io' \
    | xargs -r kubectl delete >/dev/null 2>&1
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
# The chart installs the Gateway API CRDs; drop any copy cloud-provider-kind left
# behind, or server-side apply refuses the second owner.
kubectl get crd -o name 2>/dev/null | grep 'gateway.networking.k8s.io' \
  | xargs -r kubectl delete >/dev/null 2>&1 || true

section "Installing Traefik (with hostPort)"
check "the note's DaemonSet install in Gateway API mode" \
  bash -ec "$(note_block "$NOTE" 'Gateway API in action' 2)"
kubectl -n traefik rollout status daemonset/traefik --timeout=300s >/dev/null
check_output "the chart provisioned a Gateway" 'traefik-gateway' \
  kubectl -n traefik get gateways
check_output "and a GatewayClass" 'traefik' kubectl get gatewayclasses

section "A basic HTTP route"
NODE_IP=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
check_output "with no route, Traefik answers 404 (from the note)" '404' \
  curl -s --retry 12 --retry-delay 5 --retry-all-errors -o /dev/null -w '%{http_code}' "http://$NODE_IP"
check "the backend deployment and service (from the note)" \
  bash -ec "$(note_block "$NOTE" 'Gateway API in action' 3)"
kubectl rollout status deployment/blue --timeout=180s >/dev/null
note_block "$NOTE" 'Gateway API in action' 4 | kubectl apply -f - >/dev/null
check_output "the same curl now reaches the blue pod" 'blue' \
  curl -fs --retry 12 --retry-delay 5 --retry-all-errors "http://$NODE_IP/"

section "Filters: redirect and request headers"
kubectl create deployment echo --image=mendhak/http-https-echo:37 >/dev/null
kubectl expose deployment echo --port=8080 >/dev/null
kubectl rollout status deployment/echo --timeout=180s >/dev/null
kubectl apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: filters}
spec:
  parentRefs:
  - {group: gateway.networking.k8s.io, kind: Gateway, name: traefik-gateway, namespace: traefik}
  rules:
  - matches: [{path: {type: PathPrefix, value: /old}}]
    filters:
    - type: RequestRedirect
      requestRedirect: {path: {type: ReplaceFullPath, replaceFullPath: /new}, statusCode: 301}
  - matches: [{path: {type: PathPrefix, value: /hdr}}]
    filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        set: [{name: x-my-header, value: hello}]
    backendRefs: [{name: echo, port: 8080}]
EOF
# the route takes a moment to propagate; until then blue's catch-all answers 200
retry 30 bash -c "curl -s -o /dev/null -w '%{http_code}' http://$NODE_IP/old | grep -q 301"
check_output "RequestRedirect answers 301 with the new path" '301.*/new|/new.*301' bash -c \
  "curl -s --retry 12 --retry-delay 5 --retry-all-errors -o /dev/null -w '%{http_code} %{redirect_url}' http://$NODE_IP/old"
check_output "RequestHeaderModifier sets the header the backend sees" '"x-my-header": *"hello"' \
  curl -fs --retry 12 --retry-delay 5 --retry-all-errors "http://$NODE_IP/hdr"

section "Weighted backends: canary without annotations"
kubectl create deployment red --image=jpetazzo/color >/dev/null
kubectl expose deployment red --port=80 >/dev/null
kubectl rollout status deployment/red --timeout=180s >/dev/null
weights() { kubectl apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: canary}
spec:
  parentRefs:
  - {group: gateway.networking.k8s.io, kind: Gateway, name: traefik-gateway, namespace: traefik}
  rules:
  - matches: [{path: {type: PathPrefix, value: /canary}}]
    backendRefs:
    - {name: blue, port: 80, weight: $1}
    - {name: red, port: 80, weight: $2}
EOF
}
weights 100 0
check_output "weight 100:0 sends everything to the first backend" 'blue' \
  curl -fs --retry 12 --retry-delay 5 --retry-all-errors "http://$NODE_IP/canary"
weights 0 100
check "flipping to 0:100 moves all traffic to the canary" retry 30 bash -c \
  "curl -fs http://$NODE_IP/canary | grep -q red"
