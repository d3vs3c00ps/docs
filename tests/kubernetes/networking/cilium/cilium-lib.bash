# shellcheck shell=bash
# Shared setup for the cilium/* note tests. Each test gets its own throwaway kind
# cluster without a default CNI, then installs the pinned Cilium chart into it.
# Requires tests/lib/assert.sh and tests/lib/k8s.sh to be sourced already.

# shellcheck source=../../../versions.env
source "$NOTES_ROOT/tests/versions.env"

# cilium_cluster NAME [WORKERS] [HELM_SET...]: create the cluster, install Cilium,
# wait until nodes and the agent are ready. Registers the cluster for cleanup.
cilium_cluster() {
  local name=$1 workers=${2:-1} i cfg
  shift 2 2>/dev/null || shift $#
  cfg=$(mktemp)
  {
    echo 'kind: Cluster'
    echo 'apiVersion: kind.x-k8s.io/v1alpha4'
    echo 'networking: {disableDefaultCNI: true}'
    echo 'nodes:'
    echo '  - role: control-plane'
    for ((i = 0; i < workers; i++)); do echo '  - role: worker'; done
  } >"$cfg"
  kind_cluster "$name"
  kind create cluster --name "$name" --config "$cfg" --image "$KIND_NODE_IMAGE" >/dev/null 2>&1
  helm install cilium oci://quay.io/cilium/charts/cilium \
    --version "$CILIUM_VERSION" --namespace kube-system \
    --kube-context "kind-$name" \
    --set operator.replicas=1 "$@" >/dev/null
  kubectl --context "kind-$name" -n kube-system rollout status ds/cilium --timeout=300s >/dev/null
  kubectl --context "kind-$name" wait --for=condition=Ready nodes --all --timeout=300s >/dev/null
}

# cilium_dbg CLUSTER ARGS...: run cilium-dbg inside the agent on some node.
cilium_dbg() {
  local name=$1
  shift
  kubectl --context "kind-$name" -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg "$@"
}
