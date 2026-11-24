#!/usr/bin/env bash
# note: security/supply-chain/guac.md
# env: leap
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/supply-chain/guac
GUAC=1.1.0 SYFT=1.56.0
block() { note_block "$NOTE" "$@"; }
case $(uname -m) in x86_64) a=amd64 ;; aarch64) a=arm64 ;; esac
gh() { curl -fsSL --retry 5 --retry-all-errors "https://github.com/$1/releases/download/$2"; }
(cd /usr/local/bin &&
  gh guacsec/guac "v$GUAC/guacgql-linux-$a" >guacgql &&
  gh guacsec/guac "v$GUAC/guacone-linux-$a" >guacone &&
  gh anchore/syft "v$SYFT/syft_${SYFT}_linux_$a.tar.gz" | tar -xz syft &&
  chmod +x guacgql guacone)
cd "$(mktemp -d)"
mkdir my-sboms
syft scan mirror.gcr.io/library/alpine:3.18.0 -o spdx-json=my-sboms/alpine.spdx.json 2>/dev/null
PURL=$(jq -r '.packages[].externalRefs[]? | select(.referenceType == "purl") | .referenceLocator' my-sboms/alpine.spdx.json |
  grep '^pkg:apk/alpine/libcrypto3@' | head -1)
Ps=${PURL//&/\\&}   # '&' means "the match" in a sed replacement

section "Running it"
check_output "make start-service exists in the release's Makefile" '^start-service:' \
  bash -c "curl -fsSL https://raw.githubusercontent.com/guacsec/guac/v$GUAC/Makefile"
skip "make start-service" "starts the full compose stack in the foreground; the test runs the GraphQL server alone"
bash -c "$(block 'Running it' 2) >gql.log 2>&1 &"
retry 30 curl -s -o /dev/null http://localhost:8080/query
check_output "guacgql serves GraphQL with the keyvalue backend (from the note)" 'keyvalue' \
  bash -c 'guacgql --help 2>&1 | grep -- "--gql-backend"'
check_output "guacone collect files (from the note)" 'completed ingesting 1 documents|ingested 1|1 documents' \
  bash -c "$(block 'Running it' 3 | sed -n 1p) 2>&1"
skip "collect ./attestations/" "the test has no SLSA provenance to ingest"

section "Querying"
q=$(block 'Running it' 4)
check_output "query known package finds the ingested package (from the note)" 'Origin: file:///my-sboms/alpine\.spdx\.json' \
  bash -c "$(sed -n 1p <<<"$q" | sed "s|pkg:golang/github.com/some/library@v1.2.3|$Ps|") 2>&1"
help=$(guacone query --help 2>&1)
for c in known vuln patch bad; do
  assert_match "query $c exists" "^  $c " "$help"
done
check_output "query dependents does not (the correction)" 'unknown command|Usage' \
  bash -c 'guacone query dependents x 2>&1; true'
check_output "query vuln needs a type first" 'purl' bash -c 'guacone query vuln --help 2>&1'

section "Certifiers"
help=$(guacone certifier --help 2>&1)
for c in osv scorecard cd eol; do
  assert_match "certifier $c exists" "^  $c " "$help"
done
assert_no_match "deps.dev is not a certifier (the correction)" '^  deps' "$help"
check_output "it is a collector" '^  deps_dev ' bash -c 'guacone collect --help 2>&1'
check "guacone certifier osv runs once against the graph (from the note)" \
  timeout 300 bash -c "$(block 'Certifiers' 1) >certifier.log 2>&1"
check_output "then query vuln purl finds a vulnerability the SBOM did not carry (from the note)" 'CVE-|GHSA-|vulnerab' \
  bash -c "$(sed -n 2p <<<"$q" | sed "s|pkg:oci/myapp@sha256:abc123...|$Ps|") 2>&1"
