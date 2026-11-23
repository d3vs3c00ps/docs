#!/usr/bin/env bash
# note: security/supply-chain/cosign-troubleshooting.md
# env: compose
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

NOTE=security/supply-chain/cosign-troubleshooting
COSIGN_IMAGE=ghcr.io/sigstore/cosign/cosign:v3.1.4
CRANE_IMAGE=gcr.io/go-containerregistry/crane:v0.22.1
ORAS_IMAGE=ghcr.io/oras-project/oras:v1.3.6

# Two registries in one network namespace: localhost:5000 open, localhost:5005 with a
# password (5001 is taken by the registry's debug server). The tools join it too, so
# localhost is plain HTTP and no port is published.
mkdir -p auth
docker run --rm --entrypoint htpasswd httpd:2.4-alpine -Bbn robot s3cret >auth/htpasswd
cat >compose.yaml <<EOF
services:
  registry:
    image: registry:3
  authreg:
    image: registry:3
    network_mode: service:registry
    environment:
      REGISTRY_HTTP_ADDR: ":5005"
      REGISTRY_HTTP_DEBUG_ADDR: ":5006"
      REGISTRY_AUTH: htpasswd
      REGISTRY_AUTH_HTPASSWD_REALM: test
      REGISTRY_AUTH_HTPASSWD_PATH: /auth/htpasswd
    volumes: ["./auth:/auth:ro"]
  cosign:
    image: $COSIGN_IMAGE
    network_mode: service:registry
    working_dir: /w
    user: "$(id -u):$(id -g)"
    volumes: [".:/w"]
    environment: [COSIGN_PASSWORD, HOME=/w/.home, COSIGN_DOCKER_MEDIA_TYPES, DOCKER_CONFIG=/w/.docker]
  crane:
    image: $CRANE_IMAGE
    network_mode: service:registry
    working_dir: /w
    user: "$(id -u):$(id -g)"
    volumes: [".:/w"]
    environment: [DOCKER_CONFIG=/w/.docker]
  oras:
    image: $ORAS_IMAGE
    network_mode: service:registry
    working_dir: /w
    user: "$(id -u):$(id -g)"
    volumes: [".:/w"]
EOF
docker compose up -d --quiet-pull registry authreg 2>/dev/null
retry 30 docker compose exec -T registry wget -qO- http://localhost:5000/v2/

tool() { docker compose --progress quiet run --rm -T "$@"; }
cosign() { tool cosign "$@"; }
crane() { tool crane "$@"; }
oras() { tool oras "$@"; }
export -f tool cosign crane oras
export COSIGN_PASSWORD=test-passphrase
cosign generate-key-pair >/dev/null 2>&1
cosign signing-config create --out no-tlog.json >/dev/null 2>&1

# image REPO: push a one-layer image with no base to REPO:1.2.3, print its digest.
image() {
  echo "$1" >f.txt && tar -cf layer.tar f.txt
  crane append -f layer.tar -t "$1:1.2.3" >/dev/null 2>&1
  crane digest "$1:1.2.3"
}
DIGEST=$(image localhost:5000/myapp)
export DIGEST IMG="localhost:5000/myapp@$DIGEST"
cosign sign --key cosign.key --signing-config no-tlog.json "$IMG" >/dev/null 2>&1
block() {
  note_block "$NOTE" "$@" | sed -e 's|myregistry/|localhost:5000/|g' -e 's|internal-registry/|localhost:5000/internal/|g'
}

section "no matching signatures"
check_output "crane digest and cosign tree (from the note)" 'sigstore.dev/cosign/sign/v1' \
  bash -ec "$(block 'no matching signatures' 1)"
check "oras copy -r (from the note)" bash -ec "$(block 'no matching signatures' 2)"
check "the copy carries the signature" \
  cosign verify --key cosign.pub --insecure-ignore-tlog=true "localhost:5000/internal/myapp@$DIGEST"
crane copy localhost:5000/myapp:1.2.3 localhost:5000/plain/myapp:1.2.3 >/dev/null 2>&1
check_fails "a plain image copy leaves the signature behind" \
  cosign verify --key cosign.pub --insecure-ignore-tlog=true "localhost:5000/plain/myapp@$DIGEST"
check_output "cosign triangulate is deprecated (the correction)" 'deprecated' \
  bash -c "cosign triangulate $IMG 2>&1"
check_output "cosign copy is deprecated (the correction)" 'deprecated' bash -c 'cosign copy --help 2>&1'
check_output "no log entry: the plain verify fails with the note's message" \
  'not enough verified log entries from transparency log: 0 < 1' \
  bash -c "cosign verify --key cosign.pub $IMG 2>&1; true"
cosign generate-key-pair --output-key-prefix other >/dev/null 2>&1
check_fails "the wrong public key fails" cosign verify --key other.pub --insecure-ignore-tlog=true "$IMG"
check_output "cosign tree lists what is attached (from the note)" 'OCI referrer' bash -ec "$(block 'no matching signatures' 3 | sed "s|localhost:5000/myapp@sha256:abc123...|$IMG|")"

section "certificate expired"
skip "expired Fulcio certificate" "needs a keyless signature, which needs a real OIDC identity"
check_output "verify takes --trusted-root (from the note)" '\-\-trusted-root' bash -c 'cosign verify --help 2>&1'

section "Air-gapped verification fails"
check_output "cosign initialize takes --mirror and --root (from the note)" 'mirror.*root' \
  bash -c 'cosign initialize --help 2>&1 | grep -E "^ +--(mirror|root)=" | tr "\n" " "'
skip "initialize against a mirror" "needs a TUF mirror; https://internal-tuf.example.com is a placeholder"

section "UNAUTHORIZED or denied when signing"
ADIGEST=$(crane digest localhost:5000/myapp:1.2.3)
crane auth login localhost:5005 -u robot -p s3cret >/dev/null 2>&1
crane copy localhost:5000/myapp:1.2.3 localhost:5005/myapp:1.2.3 >/dev/null 2>&1
rm -rf .docker
out=$(cosign sign --key cosign.key --signing-config no-tlog.json "localhost:5005/myapp@$ADIGEST" 2>&1 || true)
assert_match "signing with no credentials is refused" 'UNAUTHORIZED|unauthorized|denied' "$out"
check "cosign login (from the note)" env USER=robot TOKEN=s3cret \
  bash -ec "$(note_block "$NOTE" 'UNAUTHORIZED' 1 | sed 's/myregistry/localhost:5005/')"
check "then signing works" cosign sign --key cosign.key --signing-config no-tlog.json "localhost:5005/myapp@$ADIGEST"
check_output "and wrote the fallback tag sha256-<digest>" "^sha256-${ADIGEST#sha256:}\$" crane ls localhost:5005/myapp

section "unsupported media type"
DIGEST=$(image localhost:5000/legacy)
check "COSIGN_DOCKER_MEDIA_TYPES with the v2 layout (from the note)" \
  bash -ec "export DIGEST=$DIGEST; $(block 'unsupported media type' 1 | sed -e 's|/myapp@|/legacy@|' -e 's/--key cosign.key/& --tlog-upload=false/')"
check_output "writes a Docker media type manifest under the .sig tag" 'application/vnd.docker.distribution.manifest.v2' \
  crane manifest "localhost:5000/legacy:sha256-${DIGEST#sha256:}.sig"
DIGEST=$(image localhost:5000/newlayout)
COSIGN_DOCKER_MEDIA_TYPES=1 cosign sign --key cosign.key --signing-config no-tlog.json \
  "localhost:5000/newlayout@$DIGEST" >/dev/null 2>&1
check_output "alone, with the v3 layout, it changes nothing (the correction)" 'application/vnd.oci.image.index.v1' \
  crane manifest "localhost:5000/newlayout:sha256-${DIGEST#sha256:}"

section "Kyverno admits an unsigned image"
skip "Kyverno events and Audit vs Deny" "needs a cluster with Kyverno; the policy itself is tested with the cosign note"

section "verify-attestation passes but the predicate is wrong"
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
echo '{"bomFormat":"CycloneDX","specVersion":"1.6","version":1,"components":[{"type":"library","name":"x","version":"1","licenses":[{"license":{"id":"GPL-3.0-only"}}]}]}' >sbom.json
DIGEST=$(image localhost:5000/gplapp)
export IMG="localhost:5000/gplapp@$DIGEST"
cosign attest --signing-config no-tlog.json --predicate sbom.json --type cyclonedx --key cosign.key "$IMG" >/dev/null 2>&1
v() { note_block "$NOTE" 'predicate is wrong' 1 | grep "^cosign" | sed -n "$1p" | sed 's/verify-attestation /&--insecure-ignore-tlog=true /'; }
check "without --policy, a GPL SBOM passes (from the note)" bash -ec "$(v 1)"
check_fails "with --policy, it fails (from the note)" bash -ec "$(v 2)"

section "Debugging generally"
IMG="localhost:5000/myapp@$(crane digest localhost:5000/myapp:1.2.3)"
export IMG
dbg() { block 'Debugging generally' 1 | grep "^$1" | sed 's/ *#.*//'; }
check_output "cosign tree (from the note)" 'OCI referrer' bash -ec "$(dbg 'cosign tree')"
check_output "verify --verbose prints debug output (from the note)" 'GET|HEAD|DEBUG|debug' \
  bash -ec "$(dbg 'cosign verify' | sed "s|\.\.\.|--key cosign.pub --insecure-ignore-tlog=true $IMG|")"
check_output "crane ls shows the sha256-<digest> fallback tag (from the note)" '^sha256-[0-9a-f]{64}$' \
  bash -ec "$(dbg 'crane ls')"
check_output "crane manifest on it lists the referrers (from the note)" 'dev.sigstore.bundle' \
  bash -ec "$(dbg 'crane manifest' | sed "s|sha256-<digest>|sha256-${IMG##*sha256:}|")"
check_fails "COSIGN_VERBOSE does not exist (the correction)" bash -c 'cosign env 2>&1 | grep -q COSIGN_VERBOSE'
