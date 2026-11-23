#!/usr/bin/env bash
# note: security/supply-chain/cosign.md
# env: compose
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

NOTE=security/supply-chain/cosign
COSIGN_IMAGE=ghcr.io/sigstore/cosign/cosign:v3.1.4
CRANE_IMAGE=gcr.io/go-containerregistry/crane:v0.22.1
ORAS_IMAGE=ghcr.io/oras-project/oras:v1.3.6
KYVERNO_IMAGE=ghcr.io/kyverno/kyverno-cli:v1.19.2

# The tools run as the test user: on Linux, their images' own user cannot use its 0700 folder.
# Every tool shares the registry's network namespace: localhost:5000 is the registry,
# and go-containerregistry speaks plain HTTP to localhost. No port is published.
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
  oras:
    image: $ORAS_IMAGE
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
EOF
docker compose up -d --quiet-pull registry 2>/dev/null
retry 30 docker compose exec -T registry wget -qO- http://localhost:5000/v2/

# The note's commands call cosign, crane and oras: run each one in its image.
tool() { docker compose --progress quiet run --rm -T "$@"; }
cosign() { tool cosign "$@"; }
crane() { tool crane "$@"; }
oras() { tool oras "$@"; }
export -f tool cosign crane oras
export COSIGN_PASSWORD=test-passphrase

# An image built with no base and no pull: one file in one layer.
echo hello >hello.txt && tar -cf layer.tar hello.txt
crane append -f layer.tar -t localhost:5000/myapp:1.2.3 >/dev/null 2>&1
DIGEST=$(crane digest localhost:5000/myapp:1.2.3)
export DIGEST
# block HEADING N: the note's block, pointed at the local registry and the real digest.
block() {
  note_block "$NOTE" "$@" | sed -e 's/^> \{0,1\}//' \
    -e "s|myregistry/myapp@sha256:abc123\.\.\.|localhost:5000/myapp@$DIGEST|g" \
    -e 's|myregistry/|localhost:5000/|g' -e 's|internal-registry/|localhost:5000/internal/|g'
}

section "Installation"
check_output "the pinned image is cosign v3" 'GitVersion: +v3\.' cosign version
skip "brew and go install" "the test uses the release image; go install needs a Go toolchain"

section "Key-based signing"
check "generate-key-pair (from the note)" bash -ec "$(block 'Key-based signing' 1)"
assert_file "it writes cosign.key" cosign.key
assert_file "and cosign.pub" cosign.pub
check_output "the private key is encrypted" 'ENCRYPTED SIGSTORE PRIVATE KEY' cat cosign.key
out=$(bash -c "$(block 'Key-based signing' 2)" </dev/null 2>&1 || true)
assert_match "the default sign asks before writing to the public Rekor log (as the note says)" \
  'stored in public transparency logs' "$out"
assert_match "with no terminal the answer is no, and nothing is signed" 'user declined the prompt' "$out"
check "a signing config with no log, then sign and verify (from the note)" \
  bash -ec "$(block 'Key-based signing' 4)"
check_fails "verify without --insecure-ignore-tlog fails: there is no log entry" \
  bash -ec "$(block 'Key-based signing' 3)"
out=$(cosign sign --key cosign.key --tlog-upload=false --signing-config no-tlog.json \
  "localhost:5000/myapp@$DIGEST" 2>&1 || true)
assert_match "--tlog-upload=false is deprecated and refused with a signing config" \
  'tlog-upload=false is not supported' "$out"
check "resolve the digest with crane and sign it (from the note)" \
  bash -ec "$(block 'Key-based signing' 5 | sed 's/--key cosign.key/& --signing-config no-tlog.json/')"
out=$(cosign sign --key cosign.key --signing-config no-tlog.json localhost:5000/myapp:1.2.3 2>&1)
assert_match "signing a tag prints a warning" 'uses a tag, not a digest' "$out"
# Re-push the tag: the signature stays on the old digest.
echo changed >hello.txt && tar -cf layer2.tar hello.txt
crane append -f layer2.tar -t localhost:5000/myapp:1.2.3 >/dev/null 2>&1
check_fails "after a re-push, verifying the tag checks the new, unsigned image" \
  cosign verify --key cosign.pub --insecure-ignore-tlog=true localhost:5000/myapp:1.2.3
check "the old digest still verifies" \
  cosign verify --key cosign.pub --insecure-ignore-tlog=true "localhost:5000/myapp@$DIGEST"
crane tag "localhost:5000/myapp@$DIGEST" 1.2.3 >/dev/null 2>&1

section "Where the signature lives"
check_output "cosign tree shows the signature as an OCI referrer (from the note)" \
  'sigstore.dev/cosign/sign/v1 artifacts via OCI referrer' bash -ec "$(block 'Where the signature lives' 1)"
check_fails "registry:3 has no referrers API" \
  docker compose exec -T registry wget -qO- "http://localhost:5000/v2/myapp/referrers/$DIGEST"
tags=$(crane ls localhost:5000/myapp)
assert_match "so the fallback tag sha256-<hex> holds the referrers" "^sha256-${DIGEST#sha256:}\$" "$tags"
assert_no_match "and there is no .sig tag" '\.sig$' "$tags"
check_output "the fallback tag is an OCI index of Sigstore bundles" 'dev.sigstore.bundle' \
  crane manifest "localhost:5000/myapp:sha256-${DIGEST#sha256:}"
crane append -f layer.tar -t localhost:5000/legacy:1 >/dev/null 2>&1
LDIGEST=$(crane digest localhost:5000/legacy:1)
check "--new-bundle-format=false --use-signing-config=false writes the v2 layout" \
  cosign sign --key cosign.key --new-bundle-format=false --use-signing-config=false \
  --tlog-upload=false "localhost:5000/legacy@$LDIGEST"
check_output "under the tag sha256-<hex>.sig" "^sha256-${LDIGEST#sha256:}\\.sig\$" crane ls localhost:5000/legacy
check "and v3 still verifies it" \
  cosign verify --key cosign.pub --insecure-ignore-tlog=true "localhost:5000/legacy@$LDIGEST"
check_output "cosign triangulate is deprecated" 'deprecated' bash -c 'cosign triangulate localhost:5000/legacy:1 2>&1'
check_output "cosign copy is deprecated" 'deprecated' bash -c 'cosign copy --help 2>&1'
check "save, load, and oras copy -r (from the note)" bash -ec "$(block 'Where the signature lives' 2)"
check "the signature came along with cosign load" \
  cosign verify --key cosign.pub --insecure-ignore-tlog=true "localhost:5000/internal/myapp@$DIGEST"
check_output "and with oras copy -r" 'sigstore.dev/cosign/sign/v1' cosign tree localhost:5000/internal/myapp:1.2.3

section "KMS-backed keys"
skip "awskms:// keys" "needs an AWS account and a KMS key"
check_output "cosign knows the KMS prefixes the note lists" 'awskms://' \
  bash -c 'cosign generate-key-pair --help 2>&1 | tr "\n" " "'

section "Verifying at admission"
# The note shows "..." for the key: put the real one in, at the same indent, then the
# ctlog lines of the second block, which the note says go next to key:.
note_block "$NOTE" "Verifying at admission" 2 >ctlog.yaml
note_block "$NOTE" "Verifying at admission" 1 | sed 's|myregistry/\*|localhost:5000/*|' |
  python3 -c '
import re, sys
key = open("cosign.pub").read().strip().splitlines()
ctlog = open("ctlog.yaml").read().rstrip("\n")
def fill(m):
    return "\n".join(m.group(1) + l for l in key) + "\n" + ctlog
print(re.sub(r"( *)-----BEGIN PUBLIC KEY-----\n.*?-----END PUBLIC KEY-----", fill, sys.stdin.read(), flags=re.S), end="")
' >policy.yaml
check_output "the filled policy has the key and the ctlog settings" 'insecureIgnoreTlog: true' cat policy.yaml
pod() { printf 'apiVersion: v1\nkind: Pod\nmetadata: {name: p}\nspec: {containers: [{name: c, image: "%s"}]}\n' "$1" >pod.yaml; }
kyv() { tool kyverno apply "$1" --resource pod.yaml 2>&1; }
export -f kyv
# The CLI cannot resolve a tag to a digest (the webhook does that): give it digests.
pod "localhost:5000/myapp@$DIGEST"
check_output "the policy admits an image signed with cosign v3 defaults (from the note)" \
  'pass: [1-9][0-9]*, fail: 0' kyv policy.yaml
pod "localhost:5000/legacy@$LDIGEST"
check_output "and one signed with the v2 layout" 'pass: [1-9][0-9]*, fail: 0' kyv policy.yaml
crane append -f layer.tar -t localhost:5000/unsigned:1 >/dev/null 2>&1
pod "localhost:5000/unsigned@$(crane digest localhost:5000/unsigned:1)"
check_output "it rejects an unsigned image with the note's message" 'the image is not signed with our key' \
  bash -c 'kyv policy.yaml; true'
# The correction: the old ClusterPolicy verifyImages rule.
key=$(sed 's/^/                      /' cosign.pub)
cat >old-policy.yaml <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  rules:
    - name: verify-signature
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - failureAction: Enforce
          imageReferences: ["localhost:5000/*"]
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
$key
                    rekor: {ignoreTlog: true}
                    ctlog: {ignoreSCT: true}
EOF
check_output "Kyverno 1.19 says ClusterPolicy is deprecated (the correction)" 'ClusterPolicy is deprecated' \
  bash -c 'kyv old-policy.yaml; true'
pod "localhost:5000/legacy@$LDIGEST"
check_output "the old rule verifies the v2 layout" 'pass: [1-9][0-9]*, fail: 0' kyv old-policy.yaml
pod "localhost:5000/myapp@$DIGEST"
check_output "but finds no signature in the cosign v3 layout (the correction)" 'no signatures found' \
  bash -c 'kyv old-policy.yaml; true'
skip "Kyverno rewrites the image to a digest" "the Kyverno CLI does not mutate; needs a cluster with Kyverno installed"

section "Verifying third-party images"
out=$(bash -c "$(note_block "$NOTE" 'Verifying third-party images' 1)" 2>/dev/null || true)
assert_match "the Chainguard image verifies with the pinned identity (from the note)" \
  '"Subject":"https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main"' "$out"
check_fails "a wrong workflow identity is refused" cosign verify \
  --certificate-identity https://github.com/example/other/.github/workflows/release.yaml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com cgr.dev/chainguard/static

section "Signing other artifacts"
echo data >myfile.tar.gz
check "sign-blob and verify-blob, with the private config the note gives" bash -ec "$(note_block "$NOTE" 'Signing other artifacts' 1 |
  sed -e 's/sign-blob --key cosign.key/& --signing-config no-tlog.json/' -e 's/verify-blob --key cosign.pub/& --insecure-ignore-tlog=true/')"
check_fails "verify-blob without --insecure-ignore-tlog fails on that bundle" \
  cosign verify-blob --key cosign.pub --bundle myfile.bundle myfile.tar.gz
echo tampered >myfile.tar.gz
check_fails "a changed file fails verification" \
  cosign verify-blob --key cosign.pub --insecure-ignore-tlog=true --bundle myfile.bundle myfile.tar.gz
