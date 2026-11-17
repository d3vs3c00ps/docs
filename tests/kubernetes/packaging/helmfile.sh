#!/usr/bin/env bash
# note: kubernetes/packaging/helmfile.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

use_test_namespace
HOME=$(mktemp -d)
export HOME
BIN=$(mktemp -d)
export PATH=$BIN:$PATH
cd "$HOME"
rev() { helm status "$1" -o json | jq .version; }

section "Installing helmfile"
arch=$(uname -m)
case $arch in aarch64) arch=arm64 ;; x86_64) arch=amd64 ;; esac
v=${HELMFILE_VERSION#v}
check "a binary release" bash -ec \
  "curl -fsSL https://github.com/helmfile/helmfile/releases/download/$HELMFILE_VERSION/helmfile_${v}_linux_$arch.tar.gz | tar -xz -C $BIN helmfile"

section "helmfile commands"
check "helmfile init downloads the plugins it needs" helmfile init --force
check_output "(helm-diff, used by apply)" '^diff ' helm plugin list

section "What helmfile can install"
mkdir -p local raw
helm create local/web >/dev/null
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: rawcm}\ndata: {a: "1"}\n' >raw/cm.yaml
# A remote chart (OCI), a local chart and a directory of raw YAML; values from an environment.
cat >helmfile.yaml <<EOF
environments:
  default:
    values:
      - env.yaml
---
releases:
  - name: juice
    namespace: $TEST_NS
    chart: oci://ghcr.io/securecodebox/helm/juice-shop
  - name: web
    namespace: $TEST_NS
    chart: ./local/web
    values:
      - replicaCount: {{ .Values.replicas }}
  - name: raw
    namespace: $TEST_NS
    chart: ./raw
EOF
echo 'replicas: 1' >env.yaml
check_output "a plain helmfile.yaml with templates fails in Helmfile v1 (the note)" 'Add the .gotmpl file extension' \
  bash -c 'helmfile apply 2>&1 || true'
mv helmfile.yaml helmfile.yaml.gotmpl
check "helmfile apply, with helmfile.yaml.gotmpl" helmfile apply
check_output "remote chart, local chart and raw YAML are all releases" '^juice raw web$' \
  bash -c 'helm list -q | sort | xargs'
check_output "the raw YAML was applied" '^1$' kubectl get configmap rawcm -o jsonpath='{.data.a}'
skip "Helm charts from git repositories and Kustomizations" \
  "need a chart in a git repository and the kustomize binary; helmfile init installs the helm-git plugin, checked above only by name"

section "Idempotent, handles updates"
check "a second apply" helmfile apply
check_output "changed nothing: web is still at revision 1" '^1$' rev web
echo 'replicas: 2' >env.yaml
check "an environment value changed: apply again" helmfile apply
check_output "web was updated (revision 2, 2 replicas)" '^2 2$' \
  bash -c 'echo "$(helm status web -o json | jq .version) $(kubectl get deploy web -o jsonpath={.spec.replicas})"'
check_output "and only web: raw is still at revision 1" '^1$' rev raw
check "helmfile sync" helmfile sync
check_output "sync upgrades every release, changed or not" '^2$' rev raw

section "Removing one release (the correction)"
python3 - <<'EOF'
s = open('helmfile.yaml.gotmpl').read()
open('helmfile.yaml.gotmpl', 'w').write(s[:s.index('  - name: raw')])
EOF
check "apply without raw in the file" helmfile apply
check_output "raw is still installed" '^raw$' bash -c 'helm list -q | grep "^raw$"'
cat >>helmfile.yaml.gotmpl <<EOF
  - name: raw
    namespace: $TEST_NS
    chart: ./raw
    installed: false
EOF
check "apply with installed: false" helmfile apply
check_output "now raw is gone, the rest stays" '^juice web$' bash -c 'helm list -q | sort | xargs'

section "helmfile destroy"
check "helmfile destroy" helmfile destroy
check_output "every release is gone" '^$' helm list -q
