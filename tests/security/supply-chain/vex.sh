#!/usr/bin/env bash
# note: security/supply-chain/vex.md
# env: leap
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/supply-chain/vex
SYFT=1.56.0 GRYPE=0.121.2 VEXCTL=0.4.4 COSIGN=3.1.4 CRANE=0.22.1 TRIVY=0.76.2
block() { note_block "$NOTE" "$@"; }
case $(uname -m) in x86_64) a=amd64 x=x86_64 tv=64bit ;; aarch64) a=arm64 x=arm64 tv=ARM64 ;; esac
gh() { curl -fsSL --retry 5 --retry-all-errors "https://github.com/$1/releases/download/$2"; }
zypper -n -q install --no-recommends go1.26 >/dev/null
(cd /usr/local/bin &&
  gh anchore/syft "v$SYFT/syft_${SYFT}_linux_$a.tar.gz" | tar -xz syft &&
  gh anchore/grype "v$GRYPE/grype_${GRYPE}_linux_$a.tar.gz" | tar -xz grype &&
  gh openvex/vexctl "v$VEXCTL/vexctl-linux-$a" >vexctl &&
  gh sigstore/cosign "v$COSIGN/cosign-linux-$a" >cosign &&
  gh google/go-containerregistry "v$CRANE/go-containerregistry_Linux_$x.tar.gz" | tar -xz crane &&
  gh aquasecurity/trivy "v$TRIVY/trivy_${TRIVY}_Linux-$tv.tar.gz" | tar -xz trivy &&
  chmod +x vexctl cosign)
cd "$(mktemp -d)"
# An old Alpine, so the scan has real High findings to rule out.
syft scan mirror.gcr.io/library/alpine:3.18.0 -o cyclonedx-json=sbom.json 2>/dev/null
grype sbom:./sbom.json -o json >scan.json 2>/dev/null || true
V=$(jq -r '[.matches[] | select(.vulnerability.severity == "High")][0].vulnerability.id' scan.json)
P=$(jq -r --arg v "$V" '[.matches[] | select(.vulnerability.id == $v)][0].artifact.purl' scan.json)
W=$(jq -r --arg v "$V" '[.matches[] | select(.vulnerability.id != $v)][0].vulnerability.id' scan.json)
# The purl holds '&', which sed reads as "the match": escape it for the replacements.
Ps=${P//&/\\&}
# vexed STATEMENT_BLOCK: the note's create command, for the package and CVE found above.
vexed() { sed -e "s|pkg:oci/myapp@sha256:abc123...|$Ps|" -e "s|CVE-2026-1234|$1|" -e "s|vex.json|$2|"; }

section "vexctl"
check_output "go install path resolves (from the note)" '^github.com/openvex/vexctl v' go list -m github.com/openvex/vexctl@latest
check "vexctl create (from the note)" bash -ec "$(block vexctl 2 | vexed "$V" team-a.vex.json)"
check_output "an OpenVEX document with the status and justification" '^not_affected vulnerable_code_not_in_execute_path$' \
  jq -r '.statements[0] | "\(.status) \(.justification)"' team-a.vex.json
block vexctl 2 | vexed "$W" team-b.vex.json | sed 's/vulnerable_code_not_in_execute_path/inline_mitigations_already_exist/' | bash -e
check_output "not_affected with no justification is refused" 'justification or impact statement must be defined' \
  bash -c "vexctl create --product='$P' --vuln='$V' --status=not_affected 2>&1; true"
check "an impact statement is accepted instead" vexctl create --product="$P" --vuln="$V" --status=not_affected --impact-statement "not reachable"
for j in component_not_present vulnerable_code_not_present vulnerable_code_not_in_execute_path \
  vulnerable_code_cannot_be_controlled_by_adversary inline_mitigations_already_exist; do
  check_output "justification $j exists" "$j" vexctl list justification
done
for st in not_affected affected fixed under_investigation; do
  check_output "status $st exists" "$st" vexctl list status
done
check "vexctl merge (from the note)" bash -ec "$(block vexctl 3 | sed "s|pkg:oci/myapp@sha256:abc123...|$Ps|")"
check_output "merged.vex.json has both statements" '^2$' jq '.statements | length' merged.vex.json
check_output "for the scanned package" '^1$' jq --arg p "$P" '[.statements[].products[]."@id"] | unique | map(select(. == $p)) | length' merged.vex.json
out=$(vexctl filter scan.json merged.vex.json 2>/dev/null || true)
assert_no_match "on grype's JSON, vexctl filter gives no .matches (the correction)" '"matches"' "$out"
grype sbom:./sbom.json -o sarif >scan-results.sarif 2>/dev/null || true
before=$(grep -c "$V" scan-results.sarif)
check "vexctl filter on SARIF (from the note)" bash -ec "$(block vexctl 4) >filtered.sarif"
after=$(grep -c "$V" filtered.sarif || true)
check "it removes the ruled-out result ($before -> $after mentions of $V)" test "$after" -lt "$before"

section "In a scanning pipeline"
pipe=$(block 'In a scanning pipeline' 1)
bash -c "$(grep '^grype' <<<"$pipe")" 2>/dev/null || true
check_output "grype --vex moves the ruled-out match to ignoredMatches (from the note)" '^[1-9]' \
  jq --arg v "$V" --arg p "$P" '[.ignoredMatches[] | select(.vulnerability.id == $v and .artifact.purl == $p)] | length' actionable.json
check_output "and keeps it out of matches" '^0$' \
  jq --arg v "$V" --arg p "$P" '[.matches[] | select(.vulnerability.id == $v and .artifact.purl == $p)] | length' actionable.json
check_fails "the gate still fails: other High findings are left (from the note)" bash -ec "$(grep '^jq' <<<"$pipe")"
check_output "trivy has --vex too (as the note says)" '[-][-]vex ' bash -c 'trivy image --help 2>&1'

section "Attaching VEX to an artifact"
crane registry serve --address 127.0.0.1:5000 >/dev/null 2>&1 &
retry 20 curl -sf http://127.0.0.1:5000/v2/
DIGEST=$(crane copy mirror.gcr.io/library/alpine:3.18.0 127.0.0.1:5000/myapp:1 2>&1 | grep -o 'sha256:[0-9a-f]*' | tail -1)
export DIGEST COSIGN_PASSWORD=test KMS_KEY=cosign.key
cosign generate-key-pair >/dev/null 2>&1
cosign signing-config create --out no-tlog.json >/dev/null 2>&1
check "cosign attest --type openvex (from the note, local key, no public log)" \
  bash -ec "$(block 'Attaching VEX' 1 | sed 's|myregistry/myapp|127.0.0.1:5000/myapp|') --signing-config no-tlog.json"
check "the attestation verifies" cosign verify-attestation --key cosign.pub --type openvex --insecure-ignore-tlog=true "127.0.0.1:5000/myapp@$DIGEST"
