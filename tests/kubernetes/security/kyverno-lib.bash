# shellcheck shell=bash
# Shared setup for the kyverno* note tests: install the pinned chart on the shared
# cluster, remove it all on exit. Requires tests/lib/assert.sh and tests/lib/k8s.sh.

# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

kyverno_install() {
  helm upgrade --install --repo https://kyverno.github.io/kyverno/ \
    --namespace kyverno --create-namespace kyverno kyverno \
    --version "$KYVERNO_CHART" --wait --timeout 6m >/dev/null
}

kyverno_wait() {
  local d
  for d in admission background cleanup reports; do
    kubectl -n kyverno rollout status "deploy/kyverno-$d-controller" --timeout=300s >/dev/null
  done
}

# Policies first, while Kyverno still runs (it owns their webhooks and finalizers).
# Runs in the EXIT trap under `set -euo pipefail`: every step must tolerate failure
# (the chart's uninstall already removes its CRDs, so the grep can find nothing),
# or the trap stops before _k8s_exit prints the TAP plan.
kyverno_cleanup() {
  kubectl delete clusterpolicies.kyverno.io --all --timeout=60s >/dev/null 2>&1 || true
  helm uninstall kyverno --namespace kyverno --wait >/dev/null 2>&1 || true
  { kubectl get crd -o name 2>/dev/null | grep -E 'kyverno\.io|wgpolicyk8s\.io' \
    | xargs -r kubectl delete --timeout=60s >/dev/null 2>&1; } || true
  kubectl delete namespace kyverno --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
}

# reindent N: strip the common leading indentation of stdin, then indent by N spaces.
reindent() {
  awk -v n="$1" '
    { lines[NR] = $0 }
    /[^ ]/ { match($0, /^ */); if (min == "" || RLENGTH < min) min = RLENGTH }
    END { pad = sprintf("%" n "s", ""); for (i = 1; i <= NR; i++) print (lines[i] ~ /[^ ]/ ? pad substr(lines[i], min + 1) : "") }'
}
