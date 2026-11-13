# shellcheck shell=bash
# Helpers for tests with `# env: kind` or `# env: k3d`. The runner exports KUBECONFIG
# for the shared cluster and TEST_NS, a fresh namespace that it deletes afterwards.

# use_test_namespace: work in TEST_NS by default, through a private kubeconfig copy,
# so plain `kubectl get pods` in a note's command lands in the right place.
use_test_namespace() {
  : "${TEST_NS:?TEST_NS is set by scripts/test-notes.sh}"
  local copy
  copy=$(mktemp)
  cp "$KUBECONFIG" "$copy"
  export KUBECONFIG=$copy
  kubectl config set-context --current --namespace="$TEST_NS" >/dev/null
}

# Extra kind clusters a test creates. Deleted on exit, even when the test fails.
_k8s_clusters=()
kind_cluster() {
  _k8s_clusters+=("$1")
}
_k8s_cleanup() {
  local c
  for c in "${_k8s_clusters[@]}"; do kind delete cluster --name "$c" >/dev/null 2>&1 || true; done
}

# wait_for_lb_ip KIND NAME [TIMEOUT]: print the load balancer IP of a Service or Ingress.
wait_for_lb_ip() {
  local ip i
  for ((i = 0; i < ${3:-120}; i++)); do
    ip=$(kubectl get "$1" "$2" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    [[ -n $ip ]] && { echo "$ip"; return 0; }
    sleep 1
  done
  return 1
}

# start_cloud_provider_kind: give LoadBalancer Services and Ingresses an IP. In the runner
# (host network) the binary cannot resolve <cluster>-control-plane, so it uses the image on
# the kind network. Stopped on exit. kubernetes/cluster-setup/kind-in-practice explains it.
_k8s_cpk_pid=
start_cloud_provider_kind() {
  local v
  v=$(sed -n 's/^CLOUD_PROVIDER_KIND_VERSION=//p' "$NOTES_ROOT/tests/versions.env")
  if [[ -n ${NOTES_IN_RUNNER:-} ]]; then
    docker rm -f cloud-provider-kind >/dev/null 2>&1 || true
    docker run -d --name cloud-provider-kind --network kind \
      -v /var/run/docker.sock:/var/run/docker.sock \
      "registry.k8s.io/cloud-provider-kind/cloud-controller-manager:$v" >/dev/null
  else
    cloud-provider-kind >"${TMPDIR:-/tmp}/cloud-provider-kind.log" 2>&1 &
    _k8s_cpk_pid=$!
  fi
}
_k8s_stop_cpk() {
  [[ -n $_k8s_cpk_pid || -n ${NOTES_IN_RUNNER:-} ]] || return 0
  # Services and Ingresses it serves carry its finalizer: delete them while it still runs,
  # or the test namespace stays Terminating forever.
  [[ -n ${TEST_NS:-} ]] && kubectl delete service,ingress --all -n "$TEST_NS" --timeout=60s >/dev/null 2>&1
  if [[ -n $_k8s_cpk_pid ]]; then kill "$_k8s_cpk_pid" 2>/dev/null || true
  elif [[ -n ${NOTES_IN_RUNNER:-} ]]; then docker rm -f cloud-provider-kind >/dev/null 2>&1 || true; fi
}

# GitHub serves the chart archives and sometimes answers 504. Retry Helm on network
# errors only, in tests and in note blocks run with bash -c (exported), so a flaky download is not a failure.
helm() {
  local i rc err
  err=$(mktemp)
  for i in 1 2 3 4; do
    if command helm "$@" 2>"$err"; then cat "$err" >&2; rm -f "$err"; return 0; else rc=$?; fi
    grep -qE 'failed to fetch|Gateway Time-?out|i/o timeout|connection reset|TLS handshake timeout|50[234] ' "$err" || break
    sleep 15
  done
  cat "$err" >&2
  rm -f "$err"
  return "$rc"
}
export -f helm

# The assert.sh EXIT trap prints the TAP plan. Chain cluster cleanup in front of it.
_k8s_exit() {
  local rc=$?
  _k8s_stop_cpk
  _k8s_cleanup
  _t_finish "$rc"
}
trap _k8s_exit EXIT
