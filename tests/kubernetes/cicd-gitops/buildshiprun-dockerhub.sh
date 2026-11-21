#!/usr/bin/env bash
# note: kubernetes/cicd-gitops/buildshiprun-dockerhub.md
# env: compose
# timeout: 300
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

NOTE=kubernetes/cicd-gitops/buildshiprun-dockerhub
section "Using images from the Docker Hub"
images=$(grep -oE '`dockercoins/[a-z]+:v0\.1`' "$NOTES_ROOT/content/$NOTE.md" | tr -d '`')
check_output "the note lists the four images" '^4$' bash -c "wc -l <<<'$images' | tr -d ' '"
for i in $images; do
  check_output "$i exists, for amd64 and arm64" 'amd64.*arm64|arm64.*amd64' \
    bash -c "for t in 1 2 3; do m=\$(docker manifest inspect $i) && break; sleep 5; done; jq -r '[.manifests[].platform.architecture] | join(\" \")' <<<\"\$m\""
done
