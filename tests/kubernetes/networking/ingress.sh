#!/usr/bin/env bash
# note: kubernetes/networking/ingress.md
# env: kind
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/networking/ingress
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
use_test_namespace

# The note's lab installs the course's Traefik manifest (DaemonSet, hostPort 80).
HOME=$(mktemp -d)
export HOME
mkdir -p "$HOME/container.training/k8s"
curl -fsSL "$UPSTREAM/k8s/traefik.yaml" >"$HOME/container.training/k8s/traefik.yaml"
cleanup() { kubectl delete -f "$HOME/container.training/k8s/traefik.yaml" --ignore-not-found >/dev/null 2>&1; _k8s_exit; }
trap '_k8s_rc=$?; cleanup' EXIT

section "Deploying the Ingress Controller"
check "install Traefik with the note's command" \
  bash -ec "$(note_block "$NOTE" 'Ingress in action' 1)"
check "the Traefik DaemonSet becomes ready on every node" \
  kubectl -n traefik rollout status daemonset --timeout=300s 2>/dev/null \
  || kubectl rollout status -n kube-system daemonset/traefik --timeout=300s 2>/dev/null \
  || bash -c 'ns=$(kubectl get ds -A | grep -i traefik | awk "{print \$1}" | head -1);
              kubectl -n "$ns" rollout status ds --timeout=300s'
check_output "a modern controller registers an IngressClass (from the note)" 'traefik' \
  kubectl get ingressclasses

section "Creating Ingress resources"
check "the blue Deployment and Service (from the note)" \
  bash -ec "$(note_block "$NOTE" 'Ingress in action' 2)"
kubectl rollout status deployment/blue --timeout=180s >/dev/null
check "an Ingress with a single rule (from the note)" \
  bash -ec "$(note_block "$NOTE" 'Ingress in action' 3)"

section "Testing our new Ingress"
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
check_output "http://<node IP>/blue answers from the blue deployment" 'blue' \
  curl -fs --retry 20 --retry-all-errors "http://$NODE_IP/blue"

section "Using domain names"
check_output "before the Ingress exists, Traefik answers 404 (as the note says)" '404' \
  bash -c "curl -s -o /dev/null -w '%{http_code}' http://blue.$NODE_IP.nip.io"
check "an Ingress whose rule carries the domain" \
  kubectl create ingress blue-with-domain --rule="blue.$NODE_IP.nip.io/=blue:80"
check_output "name-based virtual hosting works" 'blue' \
  curl -fs --retry 20 --retry-all-errors "http://blue.$NODE_IP.nip.io"

section "Exact or prefix matches"
check_output "rules are exact by default: another path is 404" '404' bash -c \
  "sleep 2; curl -s -o /dev/null -w '%{http_code}' http://blue.$NODE_IP.nip.io/hello"
check "a rule ending in * is a prefix match" \
  kubectl create ingress blue-with-prefix --rule="blue.$NODE_IP.nip.io/*=blue:80"
check_output "now the deeper path works too" 'blue' \
  curl -fs --retry 20 --retry-all-errors "http://blue.$NODE_IP.nip.io/hello"

section "What the manifests look like"
y=$(kubectl create ingress -o yaml --dry-run=client exact-route --rule=/blue=blue:80)
assert_match "an exact rule yields pathType Exact" 'pathType: Exact' "$y"
y=$(kubectl create ingress -o yaml --dry-run=client now-with-a-prefix --rule='blue.test/*=blue:80')
assert_match "a * rule yields pathType Prefix" 'pathType: Prefix' "$y"
y=$(kubectl create ingress -o yaml --dry-run=client rgb \
  --rule='/red*=red:80' --rule='/green*=green:80' --rule='/blue*=blue:80')
assert_eq "three rules land in one resource" 3 "$(grep -c 'pathType' <<<"$y")"

section "A word about Ingress NGINX"
check_output "Ingress NGINX retirement is announced, as the note says" '200' \
  curl -s -o /dev/null -w '%{http_code}' https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/
