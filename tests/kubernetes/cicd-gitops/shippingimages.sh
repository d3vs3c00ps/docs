#!/usr/bin/env bash
# note: kubernetes/cicd-gitops/shippingimages.md
# env: compose
# timeout: 600
# registry.mycompany.io:5000 is replaced by a throwaway local registry.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

NOTE=kubernetes/cicd-gitops/shippingimages
cd "$(mktemp -d)"
PORT=$((20000 + RANDOM % 20000))
REG=notes-registry-$PORT
_ship_exit() {
  local rc=$?
  docker rm -fv "$REG" >/dev/null 2>&1 || true
  docker rmi "localhost:$PORT/myimage:awesome" >/dev/null 2>&1 || true
  _t_finish "$rc"
}
trap _ship_exit EXIT

section "How Docker registries work"
check "docker pull alpine" docker pull -q alpine:latest
id=$(docker image inspect -f '{{.Id}}' alpine:latest)
check "docker pull docker.io/library/alpine:latest" docker pull -q docker.io/library/alpine:latest
check_output "alpine, library/alpine and docker.io/library/alpine are one image" "^$id\$" \
  bash -c "docker image inspect -f '{{.Id}}' library/alpine:latest; docker image inspect -f '{{.Id}}' docker.io/library/alpine:latest | grep -x '$id'"
check_output "the digest is recorded under the short name" '^alpine@sha256:' \
  docker image inspect -f '{{index .RepoDigests 0}}' alpine:latest
check "the gcr.io example still pulls (served by Artifact Registry)" \
  docker pull -q "$(note_block "$NOTE" 1 | awk '/docker pull/{print $3}')"

section "A registry name in the image name"
docker run -d --name "$REG" -p "$PORT:5000" registry:3 >/dev/null
wait_http "http://localhost:$PORT/v2/" 60
printf 'FROM alpine:latest\nRUN echo awesome >/awesome\n' >Dockerfile
build=$(note_block "$NOTE" 1 | grep -E 'docker (build|push)' | sed "s/registry.mycompany.io:5000/localhost:$PORT/")
check "docker build -t <registry>/myimage:awesome, then push (from the note)" bash -ec "$build"
check_output "the image is in that registry, not on Docker Hub" '"tags":\["awesome"\]' \
  curl -s "http://localhost:$PORT/v2/myimage/tags/list"
