#!/usr/bin/env bash
# note: security/supply-chain/sbomasm.md
# env: leap
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/supply-chain/sbomasm
SYFT=1.56.0 SBOMQS=2.1.3 SBOMASM=2.1.2
block() { note_block "$NOTE" "$@"; }
case $(uname -m) in x86_64) a=amd64 x=x86_64 ;; aarch64) a=arm64 x=arm64 ;; esac
gh() { curl -fsSL --retry 5 --retry-all-errors "https://github.com/$1/releases/download/$2"; }
zypper -n -q install --no-recommends go1.26 >/dev/null
(cd /usr/local/bin &&
  gh anchore/syft "v$SYFT/syft_${SYFT}_linux_$a.tar.gz" | tar -xz syft &&
  gh interlynk-io/sbomqs "v$SBOMQS/sbomqs_${SBOMQS}_Linux_$x.tar.gz" | tar -xz sbomqs &&
  gh interlynk-io/sbomasm "v$SBOMASM/sbomasm_${SBOMASM}_Linux_$x.tar.gz" | tar -xz sbomasm)
cd "$(mktemp -d)"
# Three small CycloneDX inputs, standing in for a backend, a frontend and a CLI.
syft scan mirror.gcr.io/library/alpine:3.22 -o cyclonedx-json=backend.cdx.json 2>/dev/null
syft scan mirror.gcr.io/library/busybox:1.37 -o cyclonedx-json=frontend.cdx.json 2>/dev/null
mkdir cli && printf '{"name":"cli","version":"1.0.0","dependencies":{"lodash":"4.17.21"}}\n' >cli/package.json
printf '{"name":"cli","version":"1.0.0","lockfileVersion":3,"packages":{"":{"name":"cli","version":"1.0.0","dependencies":{"lodash":"4.17.21"}},"node_modules/lodash":{"version":"4.17.21","resolved":"https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz"}}}\n' >cli/package-lock.json
syft scan dir:cli -o cyclonedx-json=cli.cdx.json 2>/dev/null

section "Installation"
check_output "the /v2 module path resolves to 2.x (from the note)" '^github.com/interlynk-io/sbomasm/v2 v2\.' \
  go list -m github.com/interlynk-io/sbomasm/v2@latest
check_output "without /v2, go gets 1.0.9 (the correction)" '^github.com/interlynk-io/sbomasm v1\.0\.9$' \
  go list -m github.com/interlynk-io/sbomasm@latest

section "Assembling"
check "sbomasm assemble (from the note)" bash -ec "$(block Assembling 1)"
check_output "the primary component is my-product 2.1.0, an application" '^my-product 2\.1\.0 application$' \
  jq -r '.metadata.component | "\(.name) \(.version) \(.type)"' product.cdx.json
check_output "by default (hierarchical) each input stays one component" '^3$' \
  jq '.components | length' product.cdx.json
check_output "with its own packages nested inside it" 'lodash' \
  jq -r '.components[].components[]?.name' product.cdx.json
help=$(sbomasm assemble --help 2>&1)
for f in hierMerge flatMerge assemblyMerge augmentMerge; do
  assert_match "assemble has --$f (the table)" "[-][-]$f" "$help"
done
for f in hierarchical flat assembly; do
  check_fails "the 1.x flag --$f is gone (the correction)" sbomasm assemble "--$f" -n x -v 1 -t application backend.cdx.json
done
sbomasm assemble -n p -v 1 -t application --flatMerge -o flat.json backend.cdx.json frontend.cdx.json cli.cdx.json
check_output "--flatMerge puts every component in one list" 'lodash' jq -r '.components[].name' flat.json
check_output "with no nesting" '^0$' jq '[.components[] | select(.components)] | length' flat.json

section "Editing"
cp backend.cdx.json sbom.json
check "edit the document metadata (from the note)" bash -ec "$(block Editing 1)"
check_output "author and supplier are set" 'Platform Team.*platform@example.com' jq -c '.metadata.authors' sbom-enriched.json
check_output "supplier" 'Example Corp' jq -r '.metadata.supplier.name' sbom-enriched.json
check_output "the tool is listed" 'syft' jq -c '.metadata.tools' sbom-enriched.json
check_fails "the 1.x -i flag is refused (the correction)" sbomasm edit --subject document --author "a (a@example.com)" -i sbom.json -o x.json
check "edit the primary component (from the note)" bash -ec "$(block Editing 2 | sed -n '1,4p')"
check_output "its version and licence are set" '^2\.1\.0 Apache-2\.0$' \
  jq -r '.metadata.component | "\(.version) \(.licenses[0].license.id // .licenses[0].license.name)"' sbom-fixed.json
lib=$(jq -r '.components[] | select(.type=="library") | "\(.name) (\(.version))"' sbom.json | head -1)
check "edit one component by name and version (from the note)" \
  bash -ec "$(block Editing 2 | sed -n '/component-name-version/,$p' | sed "s/somelib (1.0.0)/$lib/")"
check_output "that component now has the supplier" 'Upstream Project' \
  jq -r --arg n "${lib%% (*}" '.components[] | select(.name==$n) | .supplier.name' sbom-fixed.json

section "Fixing what the generator missed"
cp backend.cdx.json sbom.json
fix=$(block 'Fixing what the generator missed' 1)
score() { sbomqs score sbom.json --category provenance | grep -oE 'SBOM Quality Score: [0-9.]+' | grep -oE '[0-9.]+$'; }
before=$(score)
check "the edit and re-score (from the note)" bash -ec "$fix"
after=$(score)
check "the provenance score rises ($before -> $after)" awk -v a="$after" -v b="$before" 'BEGIN { exit !(a > b) }'
supp() { sbomqs score "$1" | grep -E 'comp_with_supplier' | head -1; }
assert_eq "a document edit leaves comp_with_supplier as it was (as the note says)" "$(supp backend.cdx.json)" "$(supp sbom.json)"

section "In a release pipeline"
mkdir -p artifacts/backend artifacts/frontend
cp backend.cdx.json artifacts/backend/sbom.cdx.json && cp frontend.cdx.json artifacts/frontend/sbom.cdx.json
run_step() { block 'In a release pipeline' 1 | awk -v n="$1" '/^- name:/ { i++ } i == n' | sed -n '/run:/,$p' | sed -e 's/^ *run: |$//' -e 's/^ *run: //' -e 's/^    //'; }
check "assemble step (from the note)" env PRODUCT=my-product RELEASE_VERSION=2.1.0 bash -ec "$(run_step 1)"
check "stamp step (from the note)" bash -ec "$(run_step 2)"
check_output "quality gate step (from the note)" 'product.cdx.json' bash -ec "$(run_step 3)"
skip "sign and publish" "cosign attest is tested in the cosign notes; this needs a registry and a key"
