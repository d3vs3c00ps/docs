#!/usr/bin/env bash
# note: kubernetes/security/cert-manager.md
# env: kind
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/security/cert-manager
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
use_test_namespace
WORK=$(mktemp -d)
cd "$WORK"
# The note's commands use ~/container.training/k8s/...: give them a fake HOME.
export HOME=$WORK/home
mkdir -p "$HOME/container.training/k8s"
for f in cm-clusterissuer.yaml cm-certificate.yaml; do
  curl -fsSL "$UPSTREAM/k8s/$f" >"$HOME/container.training/k8s/$f"
done
cleanup() {
  # Delete while cert-manager still runs: ACME Challenges carry a finalizer that
  # only its controller removes, and an orphaned one blocks the CRD deletion.
  kubectl delete certificates.cert-manager.io,ingress --all --timeout=90s >/dev/null 2>&1
  kubectl delete challenges.acme.cert-manager.io,orders.acme.cert-manager.io --all --timeout=90s >/dev/null 2>&1
  kubectl delete clusterissuer letsencrypt-staging selfsigned --ignore-not-found --timeout=60s >/dev/null 2>&1
  helm uninstall cert-manager --namespace cert-manager >/dev/null 2>&1
  # crds.keep defaults to true: remove the CRDs ourselves so the next run starts clean
  kubectl get crd -o name 2>/dev/null | grep 'cert-manager\.io' | xargs -r kubectl delete >/dev/null 2>&1
  kubectl delete namespace cert-manager --ignore-not-found --timeout=120s >/dev/null 2>&1
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT

section "Installing cert-manager"
assert_match "the note pins the chart version the tests use" "--version $CERT_MANAGER_CHART" \
  "$(note_block "$NOTE" 'Installing cert-manager' 1)"
check "the note's helm install" bash -ec "$(note_block "$NOTE" 'Installing cert-manager' 1)"
for d in cert-manager cert-manager-cainjector cert-manager-webhook; do
  check "deployment $d is ready" kubectl -n cert-manager rollout status "deploy/$d" --timeout=300s
done
check_output "the chart installed the CRDs (Certificate, Issuer, ClusterIssuer...)" \
  'certificates.cert-manager.io' kubectl get crd

section "ClusterIssuer manifest"
assert_eq "the note shows the upstream file, minus its email and the comment about it" \
  "$(grep -v -e 'email:' -e 'Remember to update' "$HOME/container.training/k8s/cm-clusterissuer.yaml")" \
  "$(note_block "$NOTE" 'ClusterIssuer manifest' 1)"

section "Creating the ClusterIssuer"
# The webhook may refuse requests for a few seconds after its rollout.
check "the note's command creates it" retry 30 bash -ec "$(note_block "$NOTE" 'Creating the ClusterIssuer' 1)"
check "the ACME account registers with Let's Encrypt staging (Ready=True)" \
  retry 90 bash -c "kubectl get clusterissuer letsencrypt-staging \
    -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True"
check_output "with the upstream example.com email, registration fails (the note's correction)" \
  'forbidden domain' bash -c "
    sed 's/name: letsencrypt-staging/name: le-email-probe/; s/issuer-letsencrypt-staging/le-email-probe/' \
      '$HOME/container.training/k8s/cm-clusterissuer.yaml' | kubectl apply -f - >/dev/null
    for i in \$(seq 60); do
      m=\$(kubectl get clusterissuer le-email-probe -o jsonpath='{.status.conditions[0].message}')
      [ -n \"\$m\" ] && break; sleep 1
    done
    kubectl delete clusterissuer le-email-probe >/dev/null
    echo \"\$m\""

section "Certificate manifest"
assert_eq "the note shows the upstream file" \
  "$(cat "$HOME/container.training/k8s/cm-certificate.yaml")" \
  "$(note_block "$NOTE" 'Certificate manifest' 1)"

section "Creating the Certificate"
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
# "Edit the Certificate to update the domain name"
sed -i "s/A\.B\.C\.D/$NODE_IP/g" "$HOME/container.training/k8s/cm-certificate.yaml"
check "the note's command creates it" bash -ec "$(note_block "$NOTE" 'Creating the Certificate' 1)"

section "What's happening?"
check "the solver resources appear" retry 60 bash -c \
  "kubectl get ingress --selector=acme.cert-manager.io/http01-solver=true -o name | grep -q ."
solver=$(bash -c "$(note_block "$NOTE" "What's happening?" 1)" 2>&1)
assert_match "the note's command lists a solver Pod" 'pod/cm-acme-http-solver' "$solver"
assert_match "a solver Service" 'service/cm-acme-http-solver' "$solver"
assert_match "and a solver Ingress" 'ingress.networking.k8s.io/cm-acme-http-solver' "$solver"

section "HTTP challenge"
check_output "the Ingress path is /.well-known/acme-challenge/<token> (from the note)" \
  '/\.well-known/acme-challenge/[A-Za-z0-9_-]+' bash -ec "$(note_block "$NOTE" 'HTTP challenge' 1)"

section "What's missing ?"
skip "obtaining the Let's Encrypt certificate" \
  "Let's Encrypt must reach http://xyz.<node IP>.nip.io from the internet; the kind node IP is private"

section "Signing and storing (self-signed issuer)"
# The note's first claims, end to end with an issuer that works offline:
# cert-manager creates the key, signs it, stores key+cert in a Secret.
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: selfsigned}
spec: {selfSigned: {}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: demo}
spec:
  secretName: demo-tls
  dnsNames: [demo.example.com]
  issuerRef: {name: selfsigned, kind: ClusterIssuer}
EOF
check "the Certificate becomes Ready" \
  kubectl wait --for=condition=Ready certificate/demo --timeout=120s
check_output "the result is a kubernetes.io/tls Secret" 'kubernetes.io/tls' \
  kubectl get secret demo-tls -o jsonpath='{.type}'
check_output "holding a certificate for the requested name" 'DNS:demo.example.com' bash -c \
  "kubectl get secret demo-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName"

section "Automatic TLS Ingress with annotations"
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: annotated
  annotations: {cert-manager.io/cluster-issuer: selfsigned}
spec:
  tls:
  - secretName: annotated-tls
    hosts: [annotated.example.com]
  rules:
  - host: annotated.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend: {service: {name: nothing, port: {number: 80}}}
EOF
check "the annotation makes cert-manager create a Certificate for the tls section" \
  retry 60 kubectl get certificate annotated-tls
check "and fill the Secret named in the tls section" \
  kubectl wait --for=condition=Ready certificate/annotated-tls --timeout=120s
