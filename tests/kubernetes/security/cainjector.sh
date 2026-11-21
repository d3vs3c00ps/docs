#!/usr/bin/env bash
# note: kubernetes/security/cainjector.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/security/cainjector
use_test_namespace
cleanup() {
  kubectl delete validatingwebhookconfiguration -l notes-test=cainjector --ignore-not-found >/dev/null 2>&1
  helm uninstall cert-manager --namespace cert-manager >/dev/null 2>&1
  kubectl get crd -o name 2>/dev/null | grep 'cert-manager\.io' | xargs -r kubectl delete >/dev/null 2>&1
  kubectl delete namespace cert-manager --ignore-not-found --timeout=120s >/dev/null 2>&1
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT

# Same install as kubernetes/security/cert-manager (tested there).
helm install cert-manager cert-manager --repo https://charts.jetstack.io \
  --version "$CERT_MANAGER_CHART" --create-namespace --namespace cert-manager \
  --set crds.enabled=true --wait --timeout 5m >/dev/null
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=180s >/dev/null

# A private CA for the "webhook": self-signed Issuer, Certificate, Secret.
ca_yaml=$(mktemp)
cat >"$ca_yaml" <<'EOF'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: {name: selfsigned}
spec: {selfSigned: {}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: webhook-cert}
spec:
  secretName: webhook-cert
  isCA: true
  commonName: webhook
  dnsNames: [webhook.default.svc]
  issuerRef: {name: selfsigned, kind: Issuer}
EOF
# the cert-manager webhook can refuse requests for a few seconds after rollout
retry 30 kubectl apply -f "$ca_yaml"
kubectl wait --for=condition=Ready certificate/webhook-cert --timeout=120s >/dev/null
CA=$(kubectl get secret webhook-cert -o jsonpath='{.data.ca\.crt}')

# vwc NAME ANNOTATION-KEY VALUE: a webhook config that matches only a made-up
# resource, and ignores failures, so it can never affect the cluster.
vwc() {
  kubectl apply -f - >/dev/null <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: $1
  labels: {notes-test: cainjector}
  annotations: {"$2": "$3"}
webhooks:
- name: $1.example.com
  admissionReviewVersions: [v1]
  sideEffects: None
  failurePolicy: Ignore
  clientConfig:
    service: {name: webhook, namespace: default, path: /validate}
  rules:
  - {apiGroups: [example.com], apiVersions: [v1], operations: [CREATE], resources: [widgets]}
EOF
}
bundle() { kubectl get validatingwebhookconfiguration "$1" -o jsonpath='{.webhooks[0].clientConfig.caBundle}'; }

section "Webhook certificates"
check_output "a certificate for an internal webhook Service names <service>.<namespace>.svc" \
  'webhook\.default\.svc' bash -c \
  "kubectl get secret webhook-cert -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName"

section "CA injector - details"
vwc from-cert cert-manager.io/inject-ca-from "$TEST_NS/webhook-cert"
check "inject-ca-from <namespace>/<certificate> fills caBundle" \
  retry 60 bash -c "[ -n \"\$(kubectl get validatingwebhookconfiguration from-cert -o jsonpath='{.webhooks[0].clientConfig.caBundle}')\" ]"
assert_eq "with the Certificate's CA" "$CA" "$(bundle from-cert)"

kubectl create secret generic manual-ca --from-literal=ca.crt="$(echo "$CA" | base64 -d)" >/dev/null
vwc from-secret cert-manager.io/inject-ca-from-secret "$TEST_NS/manual-ca"
sleep 15
assert_eq "inject-ca-from-secret does nothing while the Secret lacks allow-direct-injection" \
  "" "$(bundle from-secret)"
kubectl annotate secret manual-ca cert-manager.io/allow-direct-injection=true >/dev/null
check "once the Secret is annotated, caBundle is filled" \
  retry 60 bash -c "[ -n \"\$(kubectl get validatingwebhookconfiguration from-secret -o jsonpath='{.webhooks[0].clientConfig.caBundle}')\" ]"
assert_eq "with the Secret's ca.crt" "$CA" "$(bundle from-secret)"

vwc from-apiserver cert-manager.io/inject-apiserver-ca true
check "inject-apiserver-ca: true fills caBundle" \
  retry 60 bash -c "[ -n \"\$(kubectl get validatingwebhookconfiguration from-apiserver -o jsonpath='{.webhooks[0].clientConfig.caBundle}')\" ]"
assert_eq "with the API server's CA (the one in kube-root-ca.crt)" \
  "$(kubectl get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}')" \
  "$(bundle from-apiserver | base64 -d)"

assert_match "the note names the three annotations and the Secret opt-in" \
  'inject-ca-from:.*inject-ca-from-secret:.*inject-apiserver-ca: true.*allow-direct-injection: "true"' \
  "$(tr '\n' ' ' <"$NOTES_ROOT/content/$NOTE.md")"
