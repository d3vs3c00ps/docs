#!/usr/bin/env bash
# note: security/supply-chain/sbom.md
# env: leap
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/supply-chain/sbom
SYFT=1.56.0 COSIGN=3.1.4 CRANE=0.22.1 GOMOD=1.12.0
IMAGE=mirror.gcr.io/library/alpine:3.22
block() { note_block "$NOTE" "$@"; }
case $(uname -m) in x86_64) a=amd64 x=x86_64 ;; aarch64) a=arm64 x=arm64 ;; esac
gh() { curl -fsSL --retry 5 --retry-all-errors "https://github.com/$1/releases/download/$2"; }
zypper -n -q install --no-recommends go1.26 nodejs22 npm22 >/dev/null
cd /usr/local/bin
gh anchore/syft "v$SYFT/syft_${SYFT}_linux_$a.tar.gz" | tar -xz syft
gh sigstore/cosign "v$COSIGN/cosign-linux-$a" >cosign && chmod +x cosign
gh google/go-containerregistry "v$CRANE/go-containerregistry_Linux_$x.tar.gz" | tar -xz crane
gh CycloneDX/cyclonedx-gomod "v$GOMOD/cyclonedx-gomod_${GOMOD}_linux_$a.tar.gz" | tar -xz cyclonedx-gomod
cd "$(mktemp -d)"

section "Producing one: at build time"
mkdir -p app && cd app
printf 'package main\n\nimport (\n\t"fmt"\n\n\t"golang.org/x/text/width"\n)\n\nfunc main() { fmt.Println(width.Narrow.String("x")) }\n' >main.go
go mod init example.com/myapp >/dev/null 2>&1 && go get golang.org/x/text@v0.21.0 >/dev/null 2>&1
go build -o myapp .
# cyclonedx-gomod takes the main module's version from git, as in a real project.
git init -q && git add . && git -c user.name=t -c user.email=t@example.com commit -qm init && git tag v1.0.0
gomod=$(block 'Producing one' 1)
check_output "go version -m lists the module's dependencies (from the note)" 'dep\s+golang.org/x/text\s+v0\.21\.0' \
  bash -c "$(grep '^go version' <<<"$gomod")"
check "cyclonedx-gomod app (from the note)" bash -ec "$(grep '^cyclonedx-gomod' <<<"$gomod")"
check_output "the SBOM has x/text with a purl" '^pkg:golang/golang.org/x/text@v0\.21\.0' \
  jq -r '.components[].purl' sbom.json
cd .. && mkdir -p web && cd web
npm init -y >/dev/null && npm install --silent lodash@4.17.21 >/dev/null 2>&1
check_output "npm sbom --sbom-format cyclonedx (from the note)" '"bomFormat": "CycloneDX"' \
  bash -c "$(grep '^npm' <<<"$gomod")"
check_output "it lists lodash with the purl the note shows" '^pkg:npm/lodash@4\.17\.21$' \
  bash -c "npm sbom --sbom-format cyclonedx | jq -r '.components[].purl'"
cd ..

section "Producing one: after the fact"
scan=$(block 'Producing one' 2)
check "syft on an image, CycloneDX (from the note)" \
  bash -ec "$(grep -m1 '^syft myregistry' <<<"$scan" | sed "s|myregistry/myapp:1.2.3|$IMAGE|")"
check_output "the components carry purls" '^pkg:apk/alpine/' jq -r '.components[].purl // empty' sbom.json
check_output "and a distribution-specific purl tells Alpine's openssl from others" 'pkg:apk/alpine/libssl3@' \
  jq -r '.components[].purl // empty' sbom.json
cp -r app/* . 2>/dev/null || true
check "syft dir:., SPDX (from the note)" bash -ec "$(grep '^syft dir' <<<"$scan")"
check_output "it is SPDX JSON" '^SPDX-2\.3$' jq -r .spdxVersion sbom.spdx.json
check_output "and found x/text from go.mod" 'golang.org/x/text' jq -r '.packages[].name' sbom.spdx.json

section "Attaching it to the artifact"
crane registry serve --address 127.0.0.1:5000 >/dev/null 2>&1 &
retry 20 curl -sf http://127.0.0.1:5000/v2/
crane copy "$IMAGE" 127.0.0.1:5000/myapp:1.2.3 2>&1 | tail -1
out=$(bash -c "$(block 'Attaching it' 1 | sed 's|myregistry/myapp:1.2.3|127.0.0.1:5000/myapp:1.2.3|') 2>&1") && rc=0 || rc=$?
assert_eq "cosign attach sbom still works in cosign 3.1 (from the note)" 0 "$rc"
assert_match "and says it is deprecated" 'deprecated.*attestation|deprecated' "$out"
check_output "the SBOM is stored next to the image" 'sha256-.*\.sbom' crane ls 127.0.0.1:5000/myapp

section "The two formats"
check_output "syft writes both formats" 'cyclonedx-json.*spdx-json|spdx-json.*cyclonedx-json' \
  bash -c 'syft convert --help 2>&1 | tr "\n" " "'
