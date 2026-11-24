#!/usr/bin/env bash
# note: security/supply-chain/cosign-advanced.md
# env: compose
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

NOTE=security/supply-chain/cosign-advanced
COSIGN_IMAGE=ghcr.io/sigstore/cosign/cosign:v3.1.4
CRANE_IMAGE=gcr.io/go-containerregistry/crane:v0.22.1
KYVERNO_IMAGE=ghcr.io/kyverno/kyverno-cli:v1.19.2
REKOR_CLI_IMAGE=gcr.io/projectsigstore/rekor-cli:v1.5.5

# The tools share the registry's network namespace: localhost:5000, plain HTTP, no port published.
cat >compose.yaml <<EOF
services:
  registry:
    image: registry:3
  cosign:
    image: $COSIGN_IMAGE
    network_mode: service:registry
    working_dir: /w
    user: "$(id -u):$(id -g)"
    volumes: [".:/w"]
    environment: [COSIGN_PASSWORD, HOME=/w/.home]
  crane:
    image: $CRANE_IMAGE
    network_mode: service:registry
    working_dir: /w
    user: "$(id -u):$(id -g)"
    volumes: [".:/w"]
  kyverno:
    image: $KYVERNO_IMAGE
    network_mode: service:registry
    working_dir: /w
    user: "$(id -u):$(id -g)"
    volumes: [".:/w"]
  rekor-cli:
    image: $REKOR_CLI_IMAGE
EOF
docker compose up -d --quiet-pull registry 2>/dev/null
retry 30 docker compose exec -T registry wget -qO- http://localhost:5000/v2/

tool() { docker compose --progress quiet run --rm -T "$@"; }
cosign() { tool cosign "$@"; }
crane() { tool crane "$@"; }
export -f tool cosign crane
export COSIGN_PASSWORD=test-passphrase
cosign generate-key-pair >/dev/null 2>&1
cosign signing-config create --out no-tlog.json >/dev/null 2>&1

# image NAME: push a one-layer image with no base, print its digest.
image() {
  echo "$1" >f.txt && tar -cf layer.tar f.txt
  crane append -f layer.tar -t "localhost:5000/$1:1" >/dev/null 2>&1
  crane digest "localhost:5000/$1:1"
}
DIGEST=$(image myapp)
export DIGEST KMS_KEY=cosign.key
# block HEADING N: the note's block on the local registry, signed with no public log.
block() {
  note_block "$NOTE" "$@" | sed -e 's|myregistry/|localhost:5000/|g' \
    -e 's/cosign attest /&--signing-config no-tlog.json /' \
    -e 's/cosign verify-attestation /&--insecure-ignore-tlog=true /'
}

section "Keyless signing"
skip "keyless sign and verify" "needs a real OIDC identity (CI token or browser login); never done from a test"
check_output "--yes skips the prompt" 'skip confirmation prompts' bash -c 'cosign sign --help 2>&1'
check_output "cosign initialize has --mirror and --root" '\-\-mirror.*\-\-root|\-\-root.*\-\-mirror' \
  bash -c 'cosign initialize --help 2>&1 | tr "\n" " "'

section "The transparency log"
check_output "rekor-cli search takes --artifact" '\-\-artifact' tool rekor-cli search --help
check_output "COSIGN_EXPERIMENTAL is not a cosign v3 setting (the correction)" '^0$' \
  bash -c 'grep -rc COSIGN_EXPERIMENTAL <(cosign sign --help 2>&1) || true'
skip "Rekor v2 has no search index" "a claim about the public service, from the Sigstore Rekor v2 announcement"

section "Attestations"
cat >sbom.json <<'EOF'
{"bomFormat":"CycloneDX","specVersion":"1.6","version":1,"components":[{"type":"library","name":"left-pad","version":"1.3.0","licenses":[{"license":{"id":"MIT"}}]}]}
EOF
echo '{"critical":0,"high":1}' >scan-results.json
check "attest an SBOM and a custom predicate (from the note)" bash -ec "$(block Attestations 1)"
check_output "cosign tree shows both" 'cyclonedx.org/bom.*example.com/scan/v1|example.com/scan/v1.*cyclonedx.org/bom' \
  bash -c "cosign tree localhost:5000/myapp@$DIGEST | tr '\n' ' '"
check_output "verify-attestation | jq prints the predicate (from the note)" '"bomFormat": "CycloneDX"' \
  bash -ec "$(block Attestations 2)"
out=$(cosign attach sbom --sbom sbom.json --type cyclonedx "localhost:5000/myapp@$DIGEST" 2>&1)
assert_match "attach sbom warns that it does not sign" 'does not sign' "$out"
check_output "attach sbom is deprecated" 'deprecated' bash -c 'cosign attach sbom --help 2>&1'

section "SLSA provenance"
skip "verify slsa-github-generator provenance (from the note)" "needs an image built and signed keyless by the generator"
prov() { printf '{"buildDefinition":{"buildType":"https://example.com/build","externalParameters":{"workflow":{"ref":"%s"}}},"runDetails":{"builder":{"id":"https://example.com/builder"}}}\n' "$1"; }
prov refs/heads/main >prov.json
check "attest v1 provenance with --type slsaprovenance1" cosign attest --signing-config no-tlog.json \
  --type slsaprovenance1 --predicate prov.json --key cosign.key "localhost:5000/myapp@$DIGEST"
check "verify-attestation --type slsaprovenance1 finds it" cosign verify-attestation --insecure-ignore-tlog=true \
  --key cosign.pub --type slsaprovenance1 "localhost:5000/myapp@$DIGEST"
check_fails "--type slsaprovenance (v0.2) does not find it" cosign verify-attestation --insecure-ignore-tlog=true \
  --key cosign.pub --type slsaprovenance "localhost:5000/myapp@$DIGEST"

section "Policies that check the predicate"
cat >no-gpl.rego <<'EOF'
package signature
import rego.v1
default allow := false
allow if {
  every c in input.predicate.components {
    every l in c.licenses { not startswith(l.license.id, "GPL") }
  }
}
EOF
check "the --policy check passes on an MIT SBOM (from the note)" bash -ec "$(block 'Policies that check' 1)"
DIGEST=$(image gplapp)
sed 's/"MIT"/"GPL-3.0-only"/' sbom.json >sbom-gpl.json
cosign attest --signing-config no-tlog.json --predicate sbom-gpl.json --type cyclonedx --key cosign.key \
  "localhost:5000/gplapp@$DIGEST" >/dev/null 2>&1
check "without --policy, a GPL SBOM attestation passes" cosign verify-attestation --insecure-ignore-tlog=true \
  --key cosign.pub --type cyclonedx "localhost:5000/gplapp@$DIGEST"
check_fails "with --policy, it fails (from the note)" bash -ec "$(block 'Policies that check' 1 | sed 's|/myapp@|/gplapp@|')"

# image + signed v1 provenance with the given ref, in the cosign v3 layout.
attest_ref() {
  local d
  d=$(image "$1")
  prov "$2" >p.json
  cosign attest --signing-config no-tlog.json --type slsaprovenance1 --predicate p.json \
    --key cosign.key "localhost:5000/$1@$d" >/dev/null 2>&1
  echo "$d"
}
MAIN=$(attest_ref frommain refs/heads/main)
FEATURE=$(attest_ref fromfeature refs/heads/feature)
# The key replaces "...", and the ctlog lines from the cosign note go next to key: (no log here).
note_block security/supply-chain/cosign "Verifying at admission" 2 >ctlog.yaml
note_block "$NOTE" "Policies that check" 2 | sed 's|myregistry/\*|localhost:5000/*|' |
  python3 -c '
import re, sys
key = open("cosign.pub").read().strip().splitlines()
ctlog = open("ctlog.yaml").read().rstrip("\n")
def fill(m):
    return "\n".join(m.group(1) + l for l in key) + "\n" + ctlog
print(re.sub(r"( *)-----BEGIN PUBLIC KEY-----\n.*?-----END PUBLIC KEY-----", fill, sys.stdin.read(), flags=re.S), end="")
' >policy.yaml
pod() { printf 'apiVersion: v1\nkind: Pod\nmetadata: {name: p}\nspec: {containers: [{name: c, image: "%s"}]}\n' "$1" >pod.yaml; }
kyv() { tool kyverno apply policy.yaml --resource pod.yaml 2>&1; }
export -f kyv
pod "localhost:5000/frommain@$MAIN"
check_output "Kyverno admits an image whose provenance says main (from the note)" 'pass: [1-9][0-9]*, fail: 0' kyv
pod "localhost:5000/fromfeature@$FEATURE"
check_output "and rejects one built from another branch, with the note's message" 'not built from main' \
  bash -c 'kyv; true'
pod "localhost:5000/gplapp@$DIGEST"
check_output "and one with no provenance" 'no signed SLSA v1 provenance' bash -c 'kyv; true'
# The correction: the old fragment, in a ClusterPolicy, with the default action.
cat >policy.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: {name: old}
spec:
  rules:
    - name: old
      match: {any: [{resources: {kinds: [Pod]}}]}
      verifyImages:
        - imageReferences: ["localhost:5000/*"]
          attestations:
            - type: https://slsa.dev/provenance/v1
              conditions:
                - all:
                    - key: "{{ predicate.buildDefinition.externalParameters.workflow.ref }}"
                      operator: Equals
                      value: "refs/heads/main"
EOF
check_output "the old fragment is refused with the default Audit action (the correction)" \
  'mutateDigest must be set to false' bash -c 'kyv; true'
