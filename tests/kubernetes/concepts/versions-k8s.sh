#!/usr/bin/env bash
# note: kubernetes/concepts/versions-k8s.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/concepts/versions-k8s
cd "$(mktemp -d)"
minor() { kubectl version -o json | jq -r ".$1.minor" | tr -dc '0-9'; }

section "Versions installed"
block=$(note_block "$NOTE" 'Versions installed' 1)
check_output "kubectl version shows the client and server versions (from the note)" \
  '^Client Version: v1\.[0-9]+' bash -ec "$(sed -n 1p <<<"$block")"
check_output "with a Server Version line" '^Server Version: v1\.[0-9]+' bash -ec "$(sed -n 1p <<<"$block")"
check_output "docker version (from the note)" '^Client:' bash -ec "$(sed -n 2p <<<"$block")"
check_output "docker compose version, the Compose v2 plugin (from the note)" '^Docker Compose version v[2-9]' bash -ec "$(sed -n 3p <<<"$block")"
check_fails "kubectl version --short was removed" kubectl version --short
check_output "the nodes use containerd, not Docker Engine (from the note)" '^containerd://' \
  bash -ec "$(note_block "$NOTE" 'Kubernetes and Docker compatibility' 1)"

section "Kubernetes version compatibility"
client=$(minor clientVersion) server=$(minor serverVersion)
check "this kubectl (1.$client) is within one minor version of the cluster (1.$server)" \
  test "$(( client > server ? client - server : server - client ))" -le 1
case $(uname -m) in x86_64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; esac
old=1.$((server - 2)).0
curl -fsSLo kubectl-old "https://dl.k8s.io/release/v$old/bin/linux/$arch/kubectl"
chmod +x kubectl-old
expected=$(note_block "$NOTE" 'Kubernetes version compatibility' 1 | sed "s/^ *//; s/(1\.35)/(1.$((server - 2)))/; s/(1\.37)/(1.$server)/")
check_output "kubectl $old warns about the skew, with the note's message" "^$(sed 's/[.()+/]/\\&/g' <<<"$expected")\$" \
  bash -c "./kubectl-old version 2>&1"
check_output "kubectl 1.$client does not warn" '^$' bash -c "kubectl version 2>&1 | grep -i warning; true"
