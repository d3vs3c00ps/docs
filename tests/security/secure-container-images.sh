#!/usr/bin/env bash
# note: security/secure-container-images.md
# env: compose
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

NOTE=security/secure-container-images
CRANE_IMAGE=gcr.io/go-containerregistry/crane:v0.22.1
HADOLINT_IMAGE=ghcr.io/hadolint/hadolint:v2.15.1
KYVERNO_IMAGE=ghcr.io/kyverno/kyverno-cli:v1.19.2
TAG=notes-test/secure-images-$COMPOSE_PROJECT_NAME

crane() { docker run -q --rm -i "$CRANE_IMAGE" "$@"; }
# build DIR ARGS...: BuildKit build of DIR. Exports to files, so no image is left behind,
# except with --load, which the test removes at the end.
build() { local d=$1; shift; docker buildx build -q "$@" "$d" >/dev/null; }

section "Base image selection"
mkdir app && cd app
cat >go.mod <<'EOF'
module example.com/myservice

go 1.27
EOF
cat >main.go <<'EOF'
package main

import (
	"crypto/x509"
	"fmt"
	"os"
	"time"
)

func main() {
	loc, err := time.LoadLocation("Europe/Paris")
	if err != nil {
		fmt.Println("tz:", err)
		os.Exit(1)
	}
	pool, err := x509.SystemCertPool()
	if err != nil || len(pool.Subjects()) == 0 {
		fmt.Println("no CA certificates")
		os.Exit(1)
	}
	fmt.Println(loc, len(pool.Subjects()), "CAs")
}
EOF
# The same Docker Hub image through Google's mirror: several test runs share the
# anonymous Docker Hub pull limit.
note_block "$NOTE" "Base image selection" 1 | sed 's|^FROM golang:|FROM mirror.gcr.io/library/golang:|' >Dockerfile
cd ..
check "the scratch Dockerfile builds (from the note)" build app --load -t "$TAG:scratch"
check_output "the binary finds the time zone and the CA store in scratch" '^Europe/Paris [0-9]+ CAs$' \
  docker run --rm "$TAG:scratch"
check_output "the image has one file system layer per COPY, and no OS packages" '^3$' \
  docker image inspect "$TAG:scratch" --format '{{len .RootFS.Layers}}'
check_output "it runs as 65532, not root" '^65532:65532$' docker image inspect "$TAG:scratch" --format '{{.Config.User}}'
grep -v zoneinfo app/Dockerfile >app/Dockerfile.notz
check "without the zoneinfo copy it still builds" build app -f app/Dockerfile.notz --load -t "$TAG:notz"
check_output "but the time zone is missing: the copy is needed" 'tz: unknown time zone' \
  bash -c "docker run --rm $TAG:notz; true"
check_output "Hadolint accepts the note's Dockerfile" '^$' \
  bash -c "docker run -q --rm -i $HADOLINT_IMAGE hadolint - <app/Dockerfile"

# The Chainguard claims, read from the registry: no image is pulled.
cfg=$(docker buildx imagetools inspect cgr.dev/chainguard/static:latest --format '{{json .Image}}')
assert_match "Chainguard static runs as UID 65532 (the note's runAsUser)" '"User": *"65532"' "$cfg"
files=$(crane export cgr.dev/chainguard/static:latest - | tar -t)
assert_match "static has the CA store" 'etc/ssl/certs/ca-certificates.crt' "$files"
assert_match "and tzdata" 'usr/share/zoneinfo/Europe/Paris' "$files"
files=$(crane export cgr.dev/chainguard/python:latest - | tar -t)
assert_no_match "the python image has no shell" '^(usr/)?bin/(sh|bash|busybox)$' "$files"
files=$(crane export cgr.dev/chainguard/python:latest-dev - | tar -t)
assert_match "the -dev variant has one" '^(usr/)?bin/(sh|bash|busybox)$' "$files"
check_fails "a version tag is not free: python:3.12 cannot be pulled" crane manifest cgr.dev/chainguard/python:3.12

section "Rootless execution and runtime hardening"
# The note's securityContext fragments, merged into one container.
{
  printf 'apiVersion: v1\nkind: Pod\nmetadata: {name: app}\nspec:\n'
  printf '  automountServiceAccountToken: false\n  containers:\n    - name: app\n      image: example.com/app@sha256:%064d\n' 0
  printf '      securityContext:\n        readOnlyRootFilesystem: true\n'
  for n in 1 2 3; do
    h=$( ((n == 1)) && echo 'Rootless execution' || echo 'Runtime hardening')
    i=$( ((n == 3)) && echo 2 || echo 1)
    note_block "$NOTE" "$h" "$i" | grep -v '^securityContext:' | sed 's/^/      /'
  done
} >pod.yaml
cat >psa.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: {name: psa-restricted}
spec:
  rules:
    - name: restricted
      match: {any: [{resources: {kinds: [Pod]}}]}
      validate:
        failureAction: Enforce
        podSecurity: {level: restricted, version: latest}
EOF
# As the test user: the image's own user cannot read this 0700 folder on Linux.
kyv() { docker run -q --rm --user "$(id -u):$(id -g)" -e HOME=/w/.home -v "$PWD:/w" -w /w "$KYVERNO_IMAGE" apply psa.yaml --resource "$1" 2>&1; }
export -f kyv
export KYVERNO_IMAGE
check_output "the note's settings pass the Pod Security Standard 'restricted'" 'pass: 1, fail: 0' kyv pod.yaml
printf 'apiVersion: v1\nkind: Pod\nmetadata: {name: bare}\nspec:\n  containers:\n    - name: app\n      image: example.com/app\n' >bare.yaml
check_output "a pod without them fails it" 'fail: 1' bash -c 'kyv bare.yaml; true'

section "Minimal attack surface"
skip "Kubernetes ignores HEALTHCHECK" "needs a cluster; the kubelet only runs probes"

section "Image build"
mkdir add && cd add
echo inside >inside.txt && tar -cf a.tar inside.txt && rm inside.txt
printf 'FROM scratch\nADD a.tar /\n' >Dockerfile.add
printf 'FROM scratch\nCOPY a.tar /\n' >Dockerfile.copy
cd ..
check "ADD with a local archive (as the note warns)" build add -f add/Dockerfile.add --output type=local,dest=out-add
assert_file "ADD extracted it" out-add/inside.txt
check "COPY with the same archive" build add -f add/Dockerfile.copy --output type=local,dest=out-copy
assert_file "COPY kept the archive as a file" out-copy/a.tar
check_output "Hadolint flags ADD of a plain file (DL3020)" 'DL3020' \
  bash -c "printf 'FROM scratch\nADD inside.txt /\n' | docker run -q --rm -i $HADOLINT_IMAGE hadolint -; true"
check_output "and a :latest base (DL3007)" 'DL3007' \
  bash -c "printf 'FROM cgr.dev/chainguard/node:latest\n' | docker run -q --rm -i $HADOLINT_IMAGE hadolint -; true"

mkdir sec && cd sec
echo "TOPSECRET-$RANDOM$RANDOM" >secret.txt
printf 'FROM mirror.gcr.io/library/busybox:1.37\nCOPY secret.txt /\nRUN rm /secret.txt\n' >Dockerfile.layer
printf 'FROM mirror.gcr.io/library/busybox:1.37\nRUN --mount=type=secret,id=tok test -s /run/secrets/tok\n' >Dockerfile.secret
cd ..
secret=$(cat sec/secret.txt)
check "a secret copied, then deleted in a later layer" \
  build sec -f sec/Dockerfile.layer --output type=oci,dest=layer.tar,compression=uncompressed
check_output "is still in the image (as the note warns)" '^[1-9]' bash -c "grep -ac '$secret' layer.tar"
check "a BuildKit --secret mount" build sec -f sec/Dockerfile.secret --secret id=tok,src=sec/secret.txt \
  --output type=oci,dest=secret.tar,compression=uncompressed
check_output "leaves no trace in the image" '^0$' bash -c "grep -ac '$secret' secret.tar; true"

section "Image signing and verification"
skip "KMS key generation and signing" "needs a cloud KMS or Vault; the signing commands are tested with the cosign note"

docker image rm "$TAG:scratch" "$TAG:notz" >/dev/null
