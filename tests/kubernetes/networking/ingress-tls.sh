#!/usr/bin/env bash
# note: kubernetes/networking/ingress-tls.md
# env: kind
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/networking/ingress-tls
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
use_test_namespace
WORK=$(mktemp -d)
cd "$WORK"
curl -fsSL "$UPSTREAM/k8s/traefik.yaml" >traefik.yaml
cleanup() { kubectl delete -f "$WORK/traefik.yaml" --ignore-not-found >/dev/null 2>&1; _k8s_exit; }
trap '_k8s_rc=$?; cleanup' EXIT
kubectl apply -f traefik.yaml >/dev/null
kubectl create deployment hello --image=jpetazzo/color >/dev/null
kubectl expose deployment hello --port=80 >/dev/null
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
export DOMAIN=hello.$NODE_IP.nip.io

section "Method 1, self-signed certificate"
check "the note's openssl one-liner" bash -ec "$(note_block "$NOTE" 'Method 1' 1)"
assert_file "it creates privkey.pem" privkey.pem
assert_file "and cert.pem" cert.pem
check_output "the certificate is PEM, as the note shows" 'BEGIN CERTIFICATE' cat cert.pem
check_output "the CN is the domain" "CN *= *$DOMAIN" \
  openssl x509 -in cert.pem -noout -subject

section "Methods 2 and 3, certbot"
skip "Let's Encrypt HTTP-01 methods" \
  "need a public domain reaching this machine on port 80; the local cluster is unreachable from the internet"
check_output "the certbot Ingress helper manifest exists upstream (method 3)" 'acme-challenge' \
  curl -fsSL "$UPSTREAM/k8s/certbot.yaml"

section "Creating the Secret"
check "kubectl create secret tls (from the note)" \
  bash -ec "$(note_block "$NOTE" 'Creating the Secret' 1)"

section "Ingress with TLS"
check "kubectl create ingress with ,tls= (from the note's pattern)" \
  kubectl create ingress hello --rule="$DOMAIN/*=hello:80,tls=$DOMAIN"
y=$(kubectl get ingress hello -o yaml)
assert_match "the tls section references the secret" "secretName: $DOMAIN" "$y"
assert_match "the domain was inferred into tls.hosts" "hosts:" "$y"
check "with Traefik, the route must also be told to terminate TLS (from the note)" \
  kubectl annotate ingress hello traefik.ingress.kubernetes.io/router.tls=true
kubectl rollout status deployment/hello --timeout=180s >/dev/null
check_output "the URL works over https (self-signed, hence -k)" 'hello' \
  curl -ksf --retry 12 --retry-delay 5 --retry-all-errors "https://$DOMAIN/"
check_output "the controller serves our certificate for that SNI name" "CN *= *$DOMAIN" \
  bash -c "echo | openssl s_client -connect $NODE_IP:443 -servername $DOMAIN 2>/dev/null | openssl x509 -noout -subject"
