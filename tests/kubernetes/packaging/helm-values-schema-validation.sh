#!/usr/bin/env bash
# note: kubernetes/packaging/helm-values-schema-validation.md
# env: kind
# timeout: 600
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/packaging/helm-values-schema-validation
use_test_namespace
HOME=$(mktemp -d)
export HOME
cd "$HOME"
run() { bash -ec "$1" 2>&1; }
rejected() { "$@" || true; }
# intro N: the note's intro command N, as a dry run of our chart.
intro() { note_block "$NOTE" "$1" | sed 's/helm install \.\.\. /helm template x . /'; }

section "A chart to try it on"
check "create the small chart (from the note)" run "$(note_block "$NOTE" 'A chart to try it on' 1)"
cd schematest

section "Making mistakes (no schema yet)"
check_output "image.tag=v1.0 is used" 'image: "nginx:v1.0"' run "$(intro 1)"
check_output "imagetag=v1.0 is ignored: the default tag is used" 'image: "nginx:1.29"' run "$(intro 2)"
check_output "image=v1.0: Helm fails on image.tag" 'error calling|nil pointer|can.t evaluate|executing' \
  rejected run "$(intro 3)"

section "values.schema.json"
note_block "$NOTE" '`values.schema.json`' 1 >values.schema.json
check "it is valid JSON" jq . values.schema.json

section "Testing our schema"
check_output "an invalid pullPolicy is refused (from the note)" \
  "at '/image/pullPolicy': 'ShallNotPass' does not match pattern" rejected run "$(note_block "$NOTE" 'Testing our schema' 1)"
check_output "an unknown value still passes (from the note)" 'STATUS: deployed' run "$(note_block "$NOTE" 'Testing our schema' 2)"
check_output "image as a string is refused before rendering" "at '/image': got string, want object" \
  rejected helm template x . --set image=v1.0
check_output "the original commands, without a chart, fail before the schema (the correction)" \
  'must either provide a name or specify --generate-name' rejected helm install broken --set image.pullPolicy=ShallNotPass

section "Bailing out on unknown properties"
assert_match "the note's edit adds additionalProperties at the top" '"additionalProperties": false' \
  "$(note_block "$NOTE" 'Bailing out on unknown properties' 1)"
jq '. + {additionalProperties: false}' values.schema.json >s.json && mv s.json values.schema.json

section "Testing with unknown properties"
check_output "an extra property now breaks (from the note)" "additional properties 'ImAgeTAg' not allowed" \
  rejected run "$(note_block "$NOTE" 'Testing with unknown properties' 1)"
check_output "an extra nested property does not (from the note)" 'STATUS: deployed' \
  run "$(note_block "$NOTE" 'Testing with unknown properties' 2)"
check "a plain install still works: the schema lists every value of this chart" helm template x .

section "Every value must then be in the schema"
cd "$HOME"
helm create big >/dev/null
cp schematest/values.schema.json big/
check_output "on a helm create chart, the top-level additionalProperties rejects a plain install" \
  "additional properties .*'replicaCount'" rejected helm template x big
