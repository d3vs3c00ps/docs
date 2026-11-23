#!/usr/bin/env bash
# note: security/devsecops-chain.md
# env: go
# timeout: 1500
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/devsecops-chain
GITLEAKS=8.30.1 HADOLINT=2.15.1 GOLANGCI=2.15.0 GOVULNCHECK=v1.9.0 SEMGREP=1.184.0
SYFT=1.56.0 SBOMQS=2.1.3 GRYPE=0.121.2 TRIVY=0.76.2 COSIGN=3.1.4 CRANE=0.22.1

case $(uname -m) in
  x86_64) a=amd64 x=x86_64 gl=x64 tv=64bit ;;
  aarch64) a=arm64 x=arm64 gl=arm64 tv=ARM64 ;;
esac
gh() { curl -fsSL --retry 5 --retry-all-errors "https://github.com/$1/releases/download/$2"; }
cd /usr/local/bin
gh gitleaks/gitleaks "v$GITLEAKS/gitleaks_${GITLEAKS}_linux_$gl.tar.gz" | tar -xz gitleaks
gh hadolint/hadolint "v$HADOLINT/hadolint-linux-$x" >hadolint
gh golangci/golangci-lint "v$GOLANGCI/golangci-lint-$GOLANGCI-linux-$a.tar.gz" | tar -xz --strip-components=1 "golangci-lint-$GOLANGCI-linux-$a/golangci-lint"
gh anchore/syft "v$SYFT/syft_${SYFT}_linux_$a.tar.gz" | tar -xz syft
gh interlynk-io/sbomqs "v$SBOMQS/sbomqs_${SBOMQS}_Linux_$x.tar.gz" | tar -xz sbomqs
gh anchore/grype "v$GRYPE/grype_${GRYPE}_linux_$a.tar.gz" | tar -xz grype
gh aquasecurity/trivy "v$TRIVY/trivy_${TRIVY}_Linux-$tv.tar.gz" | tar -xz trivy
gh sigstore/cosign "v$COSIGN/cosign-linux-$a" >cosign
gh google/go-containerregistry "v$CRANE/go-containerregistry_Linux_$x.tar.gz" | tar -xz crane
chmod +x hadolint cosign
GOBIN=/usr/local/bin go install "golang.org/x/vuln/cmd/govulncheck@$GOVULNCHECK" 2>/dev/null
apt-get -qq update >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y python3-venv jq >/dev/null
python3 -m venv /opt/semgrep && /opt/semgrep/bin/pip -q install "semgrep==$SEMGREP" && ln -s /opt/semgrep/bin/semgrep .

# A small Go service: a vulnerable golang.org/x/text that the code never calls into the
# vulnerable part of, a Dockerfile that runs as root, and a staged secret.
mkdir -p /src && cd /src
git init -q && git config user.email ci@example.com && git config user.name ci
cat >main.go <<'GO'
package main

import (
	"fmt"
	"net/http"

	"golang.org/x/text/width"
)

func handler(w http.ResponseWriter, r *http.Request) {
	_, _ = fmt.Fprintln(w, width.Narrow.String(r.URL.Query().Get("q")))
}

func main() {
	http.HandleFunc("/", handler)
	_ = http.ListenAndServe(":8080", nil)
}
GO
go mod init example.com/app >/dev/null 2>&1
go get golang.org/x/text@v0.3.5 >/dev/null 2>&1
go mod tidy >/dev/null 2>&1
printf 'FROM golang:1.26\nCOPY . /src\nRUN cd /src && go build -o /app .\nCMD ["/app"]\n' >Dockerfile
git add . && git commit -qm init

# pipeline STAGE N: line N of a stage's list in the note's pipeline block.
pipeline() { note_block "$NOTE" 'Placing the gates' 1 | sed -n "/^$1:/,/^\$/p" | grep '^  - ' | sed -n "${2}p" | sed -e 's/^  - //' -e 's/ *#.*$//'; }

section "Placing the gates: Code"
help=$(gitleaks --help 2>&1)
assert_match "gitleaks lists the git command" '^  git ' "$help"
assert_no_match "and no longer lists detect or protect (deprecated, hidden)" '^  (detect|protect) ' "$help"
check_fails "the old line: detect has no --staged flag (the correction)" gitleaks detect --staged
check "gitleaks on a clean staged change (from the note)" bash -ec "$(pipeline pre-commit 1)"
# A made-up AWS key, assembled at run time so this file holds no key-shaped string.
printf 'aws_access_key_id = %s%s\naws_secret_access_key = %s\n' AKIA QYLPMN5HHHFPZAM2 \
  "$(head -c 30 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)" >config.ini
git add config.ini
check_output "gitleaks blocks a staged AWS key before the commit exists" 'leaks found: [1-9]' \
  bash -c "$(pipeline pre-commit 1) 2>&1; [ \$? -ne 0 ] && echo blocked"
check_fails "and exits non-zero, so the hook stops the commit" bash -ec "$(pipeline pre-commit 1)"
git rm -q --cached config.ini && rm config.ini
check_output "hadolint Dockerfile reports the missing USER and the unpinned base (from the note)" 'DL' \
  bash -c "$(pipeline pre-commit 2) 2>&1; true"
check "golangci-lint run (from the note)" bash -ec "$(pipeline pre-commit 3)"

section "Placing the gates: Build"
semgrep_out=$(bash -c "$(pipeline build 1) 2>&1") && rc=0 || rc=$?
assert_eq "semgrep --config=auto --error fails the build on findings (from the note)" 1 "$rc"
assert_match "it finds the query string written to the response (XSS)" 'no-fprintf-to-responsewriter' "$semgrep_out"
check_output "govulncheck: the vulnerable x/text is not reachable from this code (from the note)" \
  'Your code is affected by 0 vulnerabilities' bash -ec "$(pipeline build 2)"
check "syft writes a CycloneDX SBOM (from the note)" bash -ec "$(pipeline build 3)"
check_output "it lists golang.org/x/text" 'golang.org/x/text' jq -r '.components[].name' sbom.json
check_output "sbomqs score --basic (from the note)" '[0-9]+\.[0-9]+' bash -ec "$(pipeline build 4)"
grype_out=$(bash -c "$(pipeline build 5) 2>&1") && rc=0 || rc=$?
assert_match "grype --fail-on high fails the build on the old x/text (from the note)" '^[1-9]' "$rc"
assert_match "it matched x/text against a High CVE" 'golang.org/x/text .*High' "$grype_out"
check_output "trivy config finds the root-user Dockerfile (from the note)" 'DS-?0002' bash -ec "$(pipeline build 6)"
assert_match "Dependency scanning cannot tell you if you are exploitable: grype flags what govulncheck clears" \
  'golang.org/x/text' "$grype_out"

section "Placing the gates: Release"
crane registry serve --address 127.0.0.1:5000 >/dev/null 2>&1 &
retry 20 curl -sf http://127.0.0.1:5000/v2/
tar -cf /tmp/empty.tar -T /dev/null
IMAGE=127.0.0.1:5000/app
DIGEST=$(crane append -f /tmp/empty.tar -t "$IMAGE:1" 2>/dev/null | sed 's/.*@//')
export IMAGE DIGEST COSIGN_PASSWORD=test KMS_KEY=/tmp/cosign.key
(cd /tmp && cosign generate-key-pair >/dev/null 2>&1)
# A private registry and key: no upload to the public Rekor log (see the cosign note).
cosign signing-config create --out /tmp/no-tlog.json >/dev/null 2>&1
check "cosign sign --key (from the note)" bash -ec "$(pipeline release 1) --signing-config /tmp/no-tlog.json"
check "cosign attest --type cyclonedx (from the note)" \
  bash -ec "$(pipeline release 2) --signing-config /tmp/no-tlog.json"
check "the signature verifies with the public key" \
  cosign verify --key /tmp/cosign.pub --insecure-ignore-tlog=true "$IMAGE@$DIGEST"
check_output "the attestation verifies, with a CycloneDX predicate" '^https://cyclonedx.org/bom$' \
  bash -c 'cosign verify-attestation --key /tmp/cosign.pub --type cyclonedx --insecure-ignore-tlog=true "$IMAGE@$DIGEST" 2>/dev/null |
    jq -r .payload | base64 -d | jq -r .predicateType'
skip "a real KMS key (\$KMS_KEY)" "needs a cloud KMS; the test uses a local key file in its place"
skip "Deploy and Operate stages" "comments in the block; Kyverno and Pod Security Admission are tested in kubernetes/security/*"
