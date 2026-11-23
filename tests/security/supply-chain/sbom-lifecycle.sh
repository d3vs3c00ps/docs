#!/usr/bin/env bash
# note: security/supply-chain/sbom-lifecycle.md
# env: leap
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/supply-chain/sbom-lifecycle
SYFT=1.56.0 GRYPE=0.121.2 SBOMQS=2.1.3 VEXCTL=0.4.4 COSIGN=3.1.4 CRANE=0.22.1
block() { note_block "$NOTE" "$@"; }
case $(uname -m) in x86_64) a=amd64 x=x86_64 ;; aarch64) a=arm64 x=arm64 ;; esac
gh() { curl -fsSL --retry 5 --retry-all-errors "https://github.com/$1/releases/download/$2"; }
(cd /usr/local/bin &&
  gh anchore/syft "v$SYFT/syft_${SYFT}_linux_$a.tar.gz" | tar -xz syft &&
  gh anchore/grype "v$GRYPE/grype_${GRYPE}_linux_$a.tar.gz" | tar -xz grype &&
  gh interlynk-io/sbomqs "v$SBOMQS/sbomqs_${SBOMQS}_Linux_$x.tar.gz" | tar -xz sbomqs &&
  gh openvex/vexctl "v$VEXCTL/vexctl-linux-$a" >vexctl &&
  gh sigstore/cosign "v$COSIGN/cosign-linux-$a" >cosign &&
  gh google/go-containerregistry "v$CRANE/go-containerregistry_Linux_$x.tar.gz" | tar -xz crane &&
  chmod +x vexctl cosign)
cd "$(mktemp -d)"
# A local registry holds myregistry/myapp:1.2.3, an old Alpine with known CVEs.
crane registry serve --address 127.0.0.1:5000 >/dev/null 2>&1 &
retry 20 curl -sf http://127.0.0.1:5000/v2/
crane copy mirror.gcr.io/library/alpine:3.18.0 127.0.0.1:5000/myapp:1.2.3 >/dev/null 2>&1
reg() { sed 's|myregistry/|127.0.0.1:5000/|g'; }

section "1. Generate"
check "syft on the tag (from the note)" bash -ec "$(block '1. Generate' 1 | reg)"
check "crane digest, then syft on the digest (from the note)" bash -ec "$(block '1. Generate' 2 | reg)"
DIGEST=$(crane digest 127.0.0.1:5000/myapp:1.2.3)
export DIGEST
check_output "the SBOM names the image by digest" "$DIGEST" jq -r '.metadata.component.version' sbom.json
crane append -f /dev/null -t 127.0.0.1:5000/myapp:1.2.3 >/dev/null 2>&1 || {
  tar -cf empty.tar -T /dev/null && crane append -f empty.tar -t 127.0.0.1:5000/myapp:1.2.3 >/dev/null 2>&1; }
check_fails "a re-push moves the tag away from the digest the SBOM describes" \
  test "$(crane digest 127.0.0.1:5000/myapp:1.2.3)" = "$DIGEST"

section "2. Attest"
export COSIGN_PASSWORD=test KMS_KEY=cosign.key
cosign generate-key-pair >/dev/null 2>&1
cosign signing-config create --out no-tlog.json >/dev/null 2>&1
check "cosign attest --type cyclonedx (from the note, local key, no public log)" \
  bash -ec "$(block '2. Attest' 1 | reg) --signing-config no-tlog.json"
check "the attestation verifies" \
  cosign verify-attestation --key cosign.pub --type cyclonedx --insecure-ignore-tlog=true "127.0.0.1:5000/myapp@$DIGEST"

section "3. Store"
skip "the Dependency-Track upload" "Dependency-Track needs several GB of memory and an API key created through its UI or API"

section "4. Monitor"
out=$(bash -c "$(block '4. Monitor' 1)" 2>&1) && rc=0 || rc=$?
assert_match "grype --fail-on high fails on the old Alpine (from the note)" '^[1-9]' "$rc"
sbom_ids=$(grype sbom:./sbom.json -o json 2>/dev/null | jq -r '.matches[].vulnerability.id' | sort -u)
image_ids=$(grype "127.0.0.1:5000/myapp@$DIGEST" -o json 2>/dev/null | jq -r '.matches[].vulnerability.id' | sort -u)
assert_eq "scanning the SBOM finds the same CVEs as scanning the image" "$image_ids" "$sbom_ids"

section "5. Triage"
V=$(grype sbom:./sbom.json -o json 2>/dev/null | jq -r '[.matches[] | select(.vulnerability.severity == "High")][0].vulnerability.id')
check "vexctl create (from the note)" \
  bash -ec "$(block '5. Triage' 1 | sed -e "s|pkg:oci/myapp@sha256:...|pkg:oci/myapp@$DIGEST|" -e "s|CVE-2026-1234|$V|")"
check_output "the statement is recorded" "\"name\": \"$V\"" cat vex.json

section "Putting it in a pipeline"
step() { block 'Putting it in a pipeline' 1 | awk -v n="$1" '/^- name:/ { i++ } i == n' | sed -n 's/^  run: //p'; }
check "Generate step (from the note)" bash -ec "$(step 1 | reg)"
check_output "Check SBOM quality step: the vulnerability category (from the note)" 'Vulnerability' bash -ec "$(step 2)"
check_output "the old --category quality is refused (the correction)" 'invalid category' \
  bash -c 'sbomqs score sbom.json --category quality 2>&1; true'
check_fails "Scan step fails the job on High findings (from the note)" bash -ec "$(step 3)"
check "Attest step (from the note)" bash -ec "$(step 4 | reg) --signing-config no-tlog.json"
skip "Upload step" "Dependency-Track, as above"
