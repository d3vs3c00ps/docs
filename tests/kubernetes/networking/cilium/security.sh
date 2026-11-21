#!/usr/bin/env bash
# note: kubernetes/networking/cilium/security.md
# env: kind
# timeout: 1800
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
source "$NOTES_ROOT/tests/kubernetes/networking/cilium/cilium-lib.bash"

NOTE=kubernetes/networking/cilium/security
WORK=$(mktemp -d)
cd "$WORK"
C=cil-sec
cilium_cluster "$C" 1

kubectl create namespace shop >/dev/null
# http-https-echo answers 200 on any path on 8080, so the note's L7 rules apply as-is.
kubectl -n shop create deployment backend --image=mendhak/http-https-echo:37 >/dev/null
kubectl -n shop rollout status deployment/backend --timeout=180s >/dev/null
kubectl -n shop expose deployment backend --port=8080 >/dev/null
kubectl -n shop run frontend --image=curlimages/curl --labels=app=frontend \
  --command -- sleep 3600 >/dev/null
kubectl -n shop run intruder --image=curlimages/curl --labels=app=intruder \
  --command -- sleep 3600 >/dev/null
kubectl -n shop wait --for=condition=Ready pod/frontend pod/intruder --timeout=180s >/dev/null
fe() { kubectl -n shop exec frontend -- "$@"; }

section "L7: policy on requests, not just connections"
note_block "$NOTE" 'L7' 1 >l7.yaml
check "the note's L7 policy applies" kubectl apply -f l7.yaml
sleep 5
check_output "an allowed request (GET /api/products) goes through" '200' \
  fe curl -s -o /dev/null -w '%{http_code}' -m 10 http://backend.shop:8080/api/products
check_output "an L4-allowed but L7-denied request gets HTTP 403, not a drop" '403' \
  fe curl -s -o /dev/null -w '%{http_code}' -m 10 http://backend.shop:8080/admin
check_fails "a pod the policy does not allow cannot connect at all" \
  kubectl -n shop exec intruder -- curl -s -m 5 http://backend.shop:8080/api/products

section "DNS-based egress"
kubectl -n shop run payments --image=curlimages/curl --labels=app=payments \
  --command -- sleep 3600 >/dev/null
kubectl -n shop wait --for=condition=Ready pod/payments --timeout=180s >/dev/null
note_block "$NOTE" 'DNS-based egress' 1 >fqdn.yaml
check "the note's toFQDNs policy applies" kubectl apply -f fqdn.yaml
sleep 5
# no -f: an HTTP error page still proves the connection was allowed
check "egress to an allowed FQDN works" \
  kubectl -n shop exec payments -- curl -s -o /dev/null -m 15 https://api.stripe.com
check_fails "egress to any other name fails closed" \
  kubectl -n shop exec payments -- curl -s -o /dev/null -m 8 https://example.com

section "Audit before you enforce"
# Per-endpoint audit mode, as the corrected note shows: the intruder's denied
# request is then reported but allowed.
node=$(kubectl -n shop get pod -l app=backend -o jsonpath='{.items[0].spec.nodeName}')
agent=$(kubectl -n kube-system get pod -l k8s-app=cilium \
  --field-selector "spec.nodeName=$node" -o name | head -1)
ep=$(kubectl -n kube-system exec "$agent" -c cilium-agent -- \
  cilium-dbg endpoint get -l k8s:app=backend -o json | jq -r '.[0].id')
check "enable audit mode on the backend endpoint (from the note)" \
  kubectl -n kube-system exec "$agent" -c cilium-agent -- \
  cilium-dbg endpoint config "$ep" PolicyAuditMode=Enabled
sleep 3
check_output "the denied request is now allowed (reported, not dropped)" '200|403' \
  kubectl -n shop exec intruder -- curl -s -o /dev/null -w '%{http_code}' -m 10 \
  http://backend.shop:8080/api/products
kubectl -n kube-system exec "$agent" -c cilium-agent -- \
  cilium-dbg endpoint config "$ep" PolicyAuditMode=Disabled >/dev/null

section "Deny rules"
# The note's example blocks the cloud metadata IP, unreachable here either way.
# Same shape against a reachable IP, plus an allow-all, to show deny wins.
kubectl create namespace shop2 >/dev/null
kubectl -n shop2 run probe --image=curlimages/curl --command -- sleep 3600 >/dev/null
kubectl -n shop2 wait --for=condition=Ready pod/probe --timeout=180s >/dev/null
cat >deny.yaml <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: deny-beats-allow
  namespace: shop2
spec:
  endpointSelector: {}
  egress:
    - toCIDR:
        - 0.0.0.0/0
  egressDeny:
    - toCIDR:
        - 1.1.1.1/32
EOF
check "an explicit deny applies alongside an allow-all" kubectl apply -f deny.yaml
sleep 5
check "traffic allowed by the broad rule still works" \
  kubectl -n shop2 exec probe -- curl -skf -o /dev/null -m 15 https://8.8.8.8
check_fails "the denied CIDR is blocked despite the allow" \
  kubectl -n shop2 exec probe -- curl -sk -o /dev/null -m 8 https://1.1.1.1

section "Host firewall"
skip "host firewall policy" \
  "a CiliumClusterwideNetworkPolicy on the nodes can cut kubectl off from the test cluster, as the note's own danger callout warns"

section "Verifying policy does what you think"
check_output "cilium-dbg endpoint list shows the endpoints and their policy state" \
  'Enabled' kubectl -n kube-system exec "$agent" -c cilium-agent -- cilium-dbg endpoint list
check_output "the realized policy of an endpoint is inspectable (from the note)" \
  'allowed|Allowed|l4' bash -c \
  "kubectl -n kube-system exec $agent -c cilium-agent -- cilium-dbg endpoint get $ep -o json \
   | jq '.[0].status.policy.realized'"
check "kubectl describe cnp -A" kubectl describe cnp -A
check "kubectl get cnp,ccnp -A" kubectl get cnp,ccnp -A
