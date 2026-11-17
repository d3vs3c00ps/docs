#!/usr/bin/env bash
# note: kubernetes/packaging/helm-intro.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/packaging/helm-intro
use_test_namespace
# A fresh HOME: no Helm repositories or cache from earlier runs.
HOME=$(mktemp -d)
export HOME
cd "$HOME"
CP=$CLUSTER-control-plane
run() { bash -ec "$1" 2>&1; }
rejected() { "$@" || true; }

section "Installing Helm"
check_output "'helm' alone prints its usage (from the note)" 'Usage:' rejected run "$(note_block "$NOTE" 1)"
BIN=$(mktemp -d)
check "the note's install script (get-helm-4), into a scratch directory" \
  env HELM_INSTALL_DIR="$BIN" USE_SUDO=false bash -ec "$(note_block "$NOTE" 2)"
check_output "it installs Helm 4" '^v4\.' "$BIN/helm" version --template '{{ .Version }}'

section "Finding charts from the CLI"
check_output "helm search hub finds the Juice Shop chart (from the note)" 'artifacthub.io/packages/helm/juice-shop' \
  run "$(note_block "$NOTE" 3)"
check_output "the YAML output gives the full URL the note links to" \
  'url: https://artifacthub.io/packages/helm/juice-shop/juice-shop$' run "$(note_block "$NOTE" 4)"
check_output "Artifact Hub knows the chart under juice-shop/juice-shop, from the OCI registry" \
  '^oci://ghcr.io/securecodebox/helm/juice-shop$' \
  bash -c 'curl -fsSL https://artifacthub.io/api/v1/packages/helm/juice-shop/juice-shop | jq -r .repository.url'

section "Installing the chart"
check_fails "the old repository is gone (the correction)" helm repo add juice https://charts.securecodebox.io
check "install the chart from its OCI registry (from the note)" run "$(note_block "$NOTE" 5)"

section "Charts and releases"
check_output "helm list shows the release (from the note)" '^my-juice-shop\s.*deployed\s+juice-shop-' \
  run "$(note_block "$NOTE" 6)"
kubectl rollout status deployment/my-juice-shop --timeout=300s >/dev/null
check_output "there is a my-juice-shop-... Pod running (from the note)" '^my-juice-shop-\S+ +1/1 +Running' \
  run "$(note_block "$NOTE" 7)"

section "Viewing resources of a release"
check_output "the selector finds the release's Deployment and Service (from the note)" \
  'deployment.apps/my-juice-shop' run "$(note_block "$NOTE" 8)"
check_output "and its Service" 'service/my-juice-shop +ClusterIP' run "$(note_block "$NOTE" 8)"

section "Checking possible values"
check_output "helm show readme (from the note)" 'Juice Shop' run "$(note_block "$NOTE" 9)"
check_output "helm show values: service.type defaults to ClusterIP" '^  type: ClusterIP' run "$(note_block "$NOTE" 10)"
check "helm inspect is still an alias of helm show" helm inspect values oci://ghcr.io/securecodebox/helm/juice-shop

section "Setting values"
check "helm upgrade --set service.type=NodePort (from the note)" run "$(note_block "$NOTE" 11)"
check_output "the release is at revision 2" '^my-juice-shop\s+\S+\s+2\s' helm list

section "Connecting to the Juice Shop"
check_output "the Service is now a NodePort (from the note)" 'my-juice-shop +NodePort .*3000:3[0-9]{4}/TCP' \
  run "$(note_block "$NOTE" 12)"
PORT=$(kubectl get service my-juice-shop -o jsonpath='{..nodePort}')
check_output "curl on a node reaches the app (from the note, run in a kind node)" '<title>OWASP Juice Shop' \
  docker exec -e PORT="$PORT" "$CP" bash -ec "$(note_block "$NOTE" 13)"
