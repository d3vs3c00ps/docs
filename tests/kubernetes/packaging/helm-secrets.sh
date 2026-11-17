#!/usr/bin/env bash
# note: kubernetes/packaging/helm-secrets.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/packaging/helm-secrets
use_test_namespace
HOME=$(mktemp -d)
export HOME
cd "$HOME"
run() { bash -ec "$1" 2>&1; }

section "We need a release"
check "install the release orange (from the note)" run "$(note_block "$NOTE" 1)"
check "upgrade it with a value (from the note)" run "$(note_block "$NOTE" 2)"
check_output "the value went through: an Ingress exists" '^orange-juice-shop ' kubectl get ingress --no-headers

section "Release history"
check_output "helm history shows 2 revisions (from the note)" '^2\s.*deployed' run "$(note_block "$NOTE" 3)"

section "Investigate"
check_output "secrets of TYPE helm.sh/release.v1 (from the note)" \
  'secret/sh.helm.release.v1.orange.v2 +helm.sh/release.v1' run "$(note_block "$NOTE" 4)"
check_output "no ConfigMap holds the release" '^1$' bash -c 'kubectl get configmaps --no-headers | wc -l'

section "Unpacking a secret"
check_output "describe shows a key named release (from the note)" '^release: +[0-9]+ bytes' \
  run "$(note_block "$NOTE" 5)"

section "Decoding"
check_output "the raw data is base64 (from the note)" '^[A-Za-z0-9+/=]+$' run "$(note_block "$NOTE" 6)"
check_output "decoded once, it still looks like base64 (from the note)" '^H4sI' run "$(note_block "$NOTE" 7)"
check "decoded twice: binary data (from the note)" run "$(note_block "$NOTE" 8)"
check_output "file says gzip (from the note)" 'gzip compressed data' run "$(note_block "$NOTE" 9)"
check "gunzip -c to release-info (from the note)" run "$(note_block "$NOTE" 10)"
check_output "cat release-info: it is JSON (from the note)" '^\{"name":"orange"' run "$(note_block "$NOTE" 11)"

section "Looking at the JSON"
check_output "jq keys release-info lists the note's keys, with Helm 4's apply_method and hooks" \
  '^\["apply_method","chart","config","hooks","info","manifest","name","namespace","version"\]$' \
  jq -c keys release-info
check_output "config holds the values we set" '^\{"ingress":\{"enabled":true\}\}$' jq -c .config release-info
check_output "name and version" '^"orange" 2$' bash -c 'echo "$(jq .name release-info) $(jq .version release-info)"'
check_output "manifest is the generated YAML" 'kind: Ingress' jq -r .manifest release-info
check_output "chart holds the whole chart (templates included)" 'templates/deployment.yaml' \
  jq -r '.chart.templates[].name' release-info
check_output "apply_method is ssa: Helm 4 uses server-side apply" '^ssa$' jq -r .apply_method release-info
check_output "hooks holds the chart's test hook" 'juice-shop-test-connection' jq -r '.hooks[].name' release-info

section "Conclusions"
check "this allows rollbacks" helm rollback orange 1
check_output "back to no Ingress" '^$' kubectl get ingress -o name
check_output "values can be read back without the chart source" 'enabled: true' helm get values orange --revision 2
