#!/usr/bin/env bash
# note: kubernetes/cicd-gitops/harbor.md
# env: kind
# timeout: 600
# Harbor images are amd64 only, and the demo needs a real domain: the test checks the
# note's files, kubectl commands and Helm values, without installing Harbor or cert-manager.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"
use_test_namespace

NOTE=kubernetes/cicd-gitops/harbor
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
export DOMAIN=example.com
cd "$(mktemp -d)"
run() { bash -ec "$1" 2>&1; }
# url_of BLOCK: the first URL or ~/container.training path in a block, as an upstream URL.
url_of() { grep -oE 'https://[^ ]+|~/container\.training/[^ ]+' <<<"$1" | head -1 | sed "s|^~/container.training|$UPSTREAM|"; }

section "Automating TLS certificates"
for i in 2 4; do
  u=$(url_of "$(note_block "$NOTE" $i)")
  check_output "the upstream file exists: ${u##*/} (from the note)" '^200$' curl -s -o /dev/null -w '%{http_code}' "$u"
done
assert_match "the note pins the tested cert-manager" "download/$CERT_MANAGER_CHART/cert-manager.yaml" "$(note_block "$NOTE" 3)"
check_output "the cert-manager release file exists" '^200$' curl -sL -o /dev/null -w '%{http_code}' "$(url_of "$(note_block "$NOTE" 3)")"
check_output "the upstream ClusterIssuer is named letsencrypt-staging (hence the note's warning)" 'name: letsencrypt-staging' \
  curl -fsSL "$UPSTREAM/k8s/cm-clusterissuer.yaml"
check_output "and its production server line is commented out" '#server: https://acme-v02' \
  curl -fsSL "$UPSTREAM/k8s/cm-clusterissuer.yaml"

section "Checking that it works"
check "deployment, service and TLS ingress (from the note)" run "$(note_block "$NOTE" 5)"
check_output "the Ingress has the host, TLS and the issuer annotation" \
  '^blue.example.com blue.example.com letsencrypt-production$' \
  kubectl get ingress blue -o jsonpath='{.spec.rules[0].host} {.spec.tls[0].hosts[0]} {.metadata.annotations.cert-manager\.io/cluster-issuer}'

section "Deploying Harbor"
helm=$(note_block "$NOTE" 7)
check "the chart renders with the note's values" bash -ec \
  "$(sed 's/helm upgrade --install/helm template/; s/--create-namespace//' <<<"$helm") >harbor.yaml"
check_output "the Ingress is for harbor.\$DOMAIN" '^ *(- )?host: "?harbor\.example\.com"?$' bash -c "sed -n '/^kind: Ingress/,/^---/p' harbor.yaml"
check_output "with the issuer annotation" 'cert-manager\.io/cluster-issuer: "?letsencrypt-production"?$' bash -c "sed -n '/^kind: Ingress/,/^---/p' harbor.yaml"
check_output "no PersistentVolumeClaims with persistence.enabled=false" '^0$' bash -c "grep -c '^kind: PersistentVolumeClaim' harbor.yaml || true"
check_output "the default admin password is Harbor12345 (from the note)" '^harborAdminPassword: "?Harbor12345"?$' \
  helm show values --repo https://helm.goharbor.io harbor --version 1.18.0
check_output "(the images are amd64 only, which is why Harbor is not installed here)" '^amd64$' bash -c \
  "curl -s https://hub.docker.com/v2/repositories/goharbor/harbor-core/tags/v2.14.0 | jq -r '[.images[].architecture] | unique | join(\",\")'"

section "Create a Secret for the pull account"
check "kubectl create secret docker-registry (from the note)" run "$(note_block "$NOTE" 8)"
check_output "the single quotes keep \$ in the user name (from the note)" '"username":"robot\$dockercoins-pull"' bash -c \
  "kubectl get secret dockercoins-pull -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d"
check_output "(with double quotes, the shell expands \$dockercoins)" '"username":"robot-pull"' bash -c \
  "kubectl create secret docker-registry x --docker-username \"robot\$dockercoins-pull\" --docker-password p --docker-server s --dry-run=client -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d"

section "Use the Secret"
check "kubectl patch serviceaccount default (from the note)" run "$(note_block "$NOTE" 9)"
check_output "the default ServiceAccount has the pull secret" '^dockercoins-pull$' \
  kubectl get serviceaccount default -o jsonpath='{.imagePullSecrets[*].name}'
kubectl run sa-check --image=busybox:1.37 --restart=Never -- true >/dev/null
check_output "and new Pods get it" '^dockercoins-pull$' kubectl get pod sa-check -o jsonpath='{.spec.imagePullSecrets[*].name}'
check_output "the upstream dockercoins.yaml uses dockercoins/* images (to replace, from the note)" 'image: dockercoins/worker' \
  curl -fsSL "$UPSTREAM/k8s/dockercoins.yaml"
