#!/usr/bin/env bash
# note: kubernetes/security/admission.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/security/admission
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
use_test_namespace   # private kubeconfig copy: the note switches its namespace
WORK=$(mktemp -d)
export HOME=$WORK/home
A=$HOME/container.training/webhooks/admission
mkdir -p "$A/k8s" "$A/flask"
for f in k8s/webhook-configuration.yaml k8s/webhook-server.yaml flask/webhook.py; do
  curl -fsSL "$UPSTREAM/webhooks/admission/$f" >"$A/$f"
done
cleanup() {
  # cluster-scoped and matches every Pod: remove it first
  kubectl delete validatingwebhookconfiguration admission.webhook.container.training --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace webhooks --ignore-not-found --wait=false >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
# The note's blocks run in one directory and pass variables along; keep both.
cd "$A"
run() { bash -ec "cd '$A'; $1" 2>&1; }
denied() { ! run "$1" >"$WORK/out" 2>&1 && grep -q 'denied the request' "$WORK/out"; }
# Headings repeat in this note ("Update the webhook configuration" x3), so blocks are
# picked by index; each index is checked against its content first.
b() { note_block "$NOTE" "$1"; }
for spec in '7:run --restart=Never chroma' '8:label pod chroma color=pink' '12:create namespace webhooks' \
  '13:set-context --current --namespace=webhooks' '14:create configmap admission' \
  '15:apply -f k8s/webhook-server.yaml' '16:openssl req -x509' '17:create secret tls admission' \
  '19:apply -f k8s/webhook-configuration.yaml' '20:base64 -w0 < cert.pem' '21:/webhooks/0/clientConfig/caBundle' \
  '22:kubectl patch validatingwebhookconfiguration'; do
  assert_match "block ${spec%%:*} is the expected one" "${spec#*:}" "$(b "${spec%%:*}")"
done

section "Webhook server inside or outside (ngrok)"
skip "running the webhook on our machine, exposed with ngrok" \
  "needs an ngrok account and token; the in-cluster deployment below runs the same webhook code"

section "Let's get to work!"
check "cd, create the webhooks namespace, switch to it (from the note)" run "$(b 12); $(b 13)"
check_output "the context now defaults to webhooks" '^webhooks$' \
  kubectl config view --minify -o jsonpath='{.contexts[0].context.namespace}'

section "Deploying the webhook"
check "the webhook source goes in a ConfigMap (from the note)" run "$(b 14)"
check "the Deployment and Service (from the note)" run "$(b 15)"

section "Generating the key pair and certificate"
check "openssl makes a self-signed cert for admission.webhooks.svc (from the note)" run "$(b 16)"
check_output "with that name as CN and SAN" 'DNS:admission\.webhooks\.svc' \
  openssl x509 -in cert.pem -noout -ext subjectAltName
check "load it in a Secret (from the note)" run "$(b 17)"
# pip installs Flask at start, and the pod waits for the Secret.
check "the webhook server starts (it installs its dependencies first)" \
  kubectl -n webhooks rollout status deploy/admission --timeout=300s
check "gunicorn is listening" retry 120 bash -c "kubectl -n webhooks logs deploy/admission | grep -q 'Listening at: https://0.0.0.0:443'"

section "Update the webhook configuration"
# "Comment out the url: line, uncomment the service: section" (the note uses vim).
sed -i -E 's/^( *)#(service:|  namespace: webhooks|  name: admission)$/\1\2/' k8s/webhook-configuration.yaml
check_output "the service section is active" '^    service:' cat k8s/webhook-configuration.yaml
check "apply it (from the note)" run "$(b 19)"

section 'Add our self-signed cert to the `caBundle`'
check "base64 the cert, build the JSON patch, apply it (the note's three blocks)" run "$(b 20); $(b 21); $(b 22)"
check_output "the caBundle is our certificate" "^$(base64 -w0 <cert.pem)\$" \
  kubectl get validatingwebhookconfiguration admission.webhook.container.training \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}'

section "Try it out!"
check "create a pod (the note's chroma pod)" run "$(b 7)"
check "color=pink is denied by our webhook (the note's label)" denied "$(b 8)"
assert_match "with the webhook's message" "color 'pink' is not in the allowed set" "$(cat "$WORK/out")"
check "color=red is allowed" run "kubectl label pod chroma color=red"
check "changing the color is denied" denied "kubectl label pod chroma color=blue --overwrite"
assert_match "cannot change color" 'cannot change color of a pod' "$(cat "$WORK/out")"
check "removing it is denied" denied "kubectl label pod chroma color-"
assert_match "cannot remove color" 'cannot remove color from a colored pod' "$(cat "$WORK/out")"
check "the webhook server logged the requests" bash -c "kubectl -n webhooks logs deploy/admission | grep -q 'POST /'"
