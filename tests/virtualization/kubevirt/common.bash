# shellcheck shell=bash
# Shared setup for the KubeVirt note tests (sourced, so not named *.sh: the runner
# would take it for a test). No cluster here runs KubeVirt: the tests check the
# notes' manifests against KubeVirt's own API schema, at a pinned release, and run
# virtctl and the notes' jq pipelines offline.

# Pinned here until tests/versions.env has them.
KUBEVIRT_VERSION=${KUBEVIRT_VERSION:-v1.9.1}
CDI_VERSION=${CDI_VERSION:-v1.66.1}
KV_RAW=https://raw.githubusercontent.com/kubevirt/kubevirt/$KUBEVIRT_VERSION
KV_DL=https://github.com/kubevirt/kubevirt/releases/download/$KUBEVIRT_VERSION
CDI_RAW=https://raw.githubusercontent.com/kubevirt/containerized-data-importer/$CDI_VERSION
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')

# Every download is from GitHub or a registry, which fail now and then (502, 504).
curl() { command curl --retry 4 --retry-all-errors --retry-delay 3 "$@"; }
export -f curl

zypper -n -q install --no-recommends python313-PyYAML python313-jsonschema >/dev/null
cd "$(mktemp -d)"
curl -fsSL -o kubevirt.json "$KV_RAW/api/openapi-spec/swagger.json"

# validate FILE|- [--def NAME] [--partial]: check YAML against KubeVirt's API schema.
validate() { python3 "$NOTES_ROOT/tests/virtualization/kubevirt/schema.py" kubevirt.json "$@"; }

# kv_source PATH: a file of the KubeVirt source tree at the pinned release.
kv_source() { curl -fsSL "$KV_RAW/$1"; }

install_virtctl() {
  curl -fsSL -o /usr/local/bin/virtctl "$KV_DL/virtctl-$KUBEVIRT_VERSION-linux-$ARCH"
  chmod +x /usr/local/bin/virtctl
}

# fake_nodes: a `kubectl get nodes -o json` answer, one node with KVM and one without.
fake_nodes() {
  cat <<'EOF'
{"items": [
  {"metadata": {"name": "node-kvm"}, "status": {"allocatable": {"cpu": "8", "devices.kubevirt.io/kvm": "1k", "memory": "32Gi"}}},
  {"metadata": {"name": "node-nokvm"}, "status": {"allocatable": {"cpu": "8", "memory": "32Gi"}}}
]}
EOF
}

# virtctl_parses CMDLINE: virtctl accepts the arguments. With no cluster, it then
# fails to reach the API server, which is how we know it got that far.
virtctl_parses() {
  local out
  out=$(bash -c "$1" 2>&1) || true
  if grep -q 'connection refused' <<<"$out" && ! grep -Eqi 'accepts [0-9]+ arg|unknown (flag|command)|must contain' <<<"$out"; then
    return 0
  fi
  echo "$out"
  return 1
}

# k8s_validate FILE|- [--def NAME] [--partial]: the same check for built-in kinds,
# against the Kubernetes API schema of the pinned kubectl release.
k8s_validate() {
  # shellcheck source=../../versions.env
  [[ -f k8s.json ]] || { source "$NOTES_ROOT/tests/versions.env" &&
    curl -fsSL -o k8s.json "https://raw.githubusercontent.com/kubernetes/kubernetes/$KUBECTL_VERSION/api/openapi-spec/swagger.json"; }
  python3 "$NOTES_ROOT/tests/virtualization/kubevirt/schema.py" k8s.json "$@"
}
