#!/usr/bin/env bash
# note: security/supply-chain/sbomqs.md
# env: leap
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/supply-chain/sbomqs
SYFT=1.56.0 SBOMQS=2.1.3
block() { note_block "$NOTE" "$@"; }
case $(uname -m) in x86_64) a=amd64 x=x86_64 ;; aarch64) a=arm64 x=arm64 ;; esac
gh() { curl -fsSL --retry 5 --retry-all-errors "https://github.com/$1/releases/download/$2"; }
zypper -n -q install --no-recommends go1.26 >/dev/null
(cd /usr/local/bin &&
  gh anchore/syft "v$SYFT/syft_${SYFT}_linux_$a.tar.gz" | tar -xz syft &&
  gh interlynk-io/sbomqs "v$SBOMQS/sbomqs_${SBOMQS}_Linux_$x.tar.gz" | tar -xz sbomqs)
cd "$(mktemp -d)"
# The image of the note's sample output.
syft scan mirror.gcr.io/library/alpine:3.18.0 -o cyclonedx-json=sbom.json 2>/dev/null
cp sbom.json sbom-old.json && cp sbom.json sbom-new.json

section "Installation"
check_output "the module path with /v2 resolves to a 2.x release (from the note)" '^github.com/interlynk-io/sbomqs/v2 v2\.' \
  go list -m github.com/interlynk-io/sbomqs/v2@latest
check_output "without /v2, go fetches the last 1.x" '^github.com/interlynk-io/sbomqs v1\.' \
  go list -m github.com/interlynk-io/sbomqs@latest
check_output "the pinned release is 2.x" 'v?2\.1\.3' sbomqs version

section "Scoring"
out=$(bash -c "$(block Scoring 1)" 2>&1)
assert_match "overall score out of 10, with a grade (from the note)" 'SBOM Quality Score: [0-9.]+/10\.0.*Grade: [A-F]' "$out"
for p in 'Interlynk' 'NTIA Minimum Elements \(2026\)' 'BSI TR-03183-2 v1\.1'; do
  assert_match "profile row: $p" "\\| $p " "$out"
done
for c in Identification Provenance Integrity Completeness Licensing Vulnerability Structural; do
  assert_match "category row: $c" "\\| $c " "$out"
done
for f in comp_with_purl_or_cpe comp_with_supplier comp_with_valid_licenses; do
  assert_match "feature named in the note: $f" "$f" "$out"
done
while read -r line; do
  check "$line (from the note)" bash -ec "$line"
done < <(block Scoring 3)
check_output "the 1.x category NTIA-minimum-elements fails (the correction)" 'invalid category' \
  bash -c 'sbomqs score sbom.json --category NTIA-minimum-elements 2>&1; true'
check "--legacy still gives the 1.x scoring" sbomqs score --legacy sbom.json
check_output "the ntia-2021 and bsi profiles exist" 'NTIA' sbomqs score sbom.json --profile ntia-2021
check "and bsi" sbomqs score sbom.json --profile bsi

section "As a build gate"
basic=$(bash -c "$(block 'As a build gate' 1)" 2>&1)
assert_eq "--basic prints one line (from the note)" 1 "$(grep -c . <<<"$basic")"
gate=$(block 'As a build gate' 2 | sed -n '/run: |/,$p' | sed 1d | sed 's/^    //')
out=$(bash -c "$gate" 2>&1) && rc=0 || rc=$?
assert_match "the gate reads .files[0].sbom_quality_score (from the note)" '^SBOM score: [0-9]+\.[0-9]+' "$out"
assert_eq "and fails this Alpine SBOM, under 7.0" 1 "$rc"
assert_match "with the note's message" 'SBOM quality below threshold' "$out"
check_output "the 1.x field avg_score is gone (the correction)" '^null$' \
  bash -c "sbomqs score sbom.json --json | jq -r '.files[0].avg_score'"

section "Comparing and listing"
cmp=$(block 'Comparing and listing' 1)
check_output "score several at once (from the note)" 'sbom-new.json' bash -c "$(sed -n 1p <<<"$cmp" | sed 's/ *#.*//')"
check_output "list the components missing a licence (from the note)" '[a-z]' bash -c "$(sed -n 2p <<<"$cmp")"
