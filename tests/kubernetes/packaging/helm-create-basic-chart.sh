#!/usr/bin/env bash
# note: kubernetes/packaging/helm-create-basic-chart.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/packaging/helm-create-basic-chart
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
use_test_namespace
# The note's commands read ~/container.training/k8s/...: a fake HOME holds that file.
HOME=$(mktemp -d)
export HOME
cd "$HOME"
mkdir -p container.training/k8s
curl -fsSL "$UPSTREAM/k8s/dockercoins.yaml" >container.training/k8s/dockercoins.yaml
# The note's second namespace, made unique for this run.
HC=$TEST_NS-hc
cleanup() {
  kubectl delete namespace "$HC" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
run() { bash -ec "$1" 2>&1; }
rejected() { "$@" || true; }
hc() { sed "s/namespace=helmcoins/namespace=$HC/g; s/namespace helmcoins/namespace $HC/g" <<<"$1"; }

section "Creating a basic chart"
check "helm create (from the note)" run "$(note_block "$NOTE" 2)"
check "move the sample templates away (from the note)" run "$(note_block "$NOTE" 3)"
check "copy dockercoins.yaml into templates (from the note)" run "$(note_block "$NOTE" 4)"

section "Testing our Helm chart"
# The note's case: the app is already deployed in the current namespace.
kubectl apply -f container.training/k8s/dockercoins.yaml >/dev/null
out=$(rejected run "$(note_block "$NOTE" 5)")
expected=$(note_block "$NOTE" 6 | sed "s/\"default\"/\"$TEST_NS\"/g")
assert_eq "the install fails with the note's error" "$expected" "$out"
# The note's remark: with that label and those annotations, Helm adopts the resources.
for r in $(kubectl get deploy,svc -o name); do
  kubectl label "$r" app.kubernetes.io/managed-by=Helm >/dev/null
  kubectl annotate "$r" meta.helm.sh/release-name=helmcoins meta.helm.sh/release-namespace="$TEST_NS" >/dev/null
done
check "after adding them, the same install adopts the existing resources" run "$(note_block "$NOTE" 5)"
helm uninstall helmcoins --wait >/dev/null

section "Switching to another namespace"
check "create the namespace (from the note)" run "$(hc "$(note_block "$NOTE" 7)")"
check "install in that namespace (from the note)" run "$(hc "$(note_block "$NOTE" 8)")"

section "Helm releases are namespaced"
check_output "helm list in the current namespace: the release does not show up" '^NAME' run "$(note_block "$NOTE" 9)"
assert_no_match "(no helmcoins line)" 'helmcoins' "$(run "$(note_block "$NOTE" 9)")"
check_output "helm list --namespace shows it (from the note)" '^helmcoins\s.*deployed\s+dockercoins-0\.1\.0' \
  run "$(hc "$(note_block "$NOTE" 10)")"

section "Checking our new copy of DockerCoins"
check_output "the web UI Service is a NodePort (from the note)" '^webui +NodePort ' \
  run "$(hc "$(note_block "$NOTE" 11)")"
kubectl -n "$HC" rollout status deploy/worker --timeout=300s >/dev/null
logs=$(hc "$(note_block "$NOTE" 12)" | sed 's/ --follow//')
retry 60 bash -c "$logs | grep -q 'units of work done'" || true
check_output "the worker logs show work (from the note, without --follow)" 'units of work done' run "$logs"

section "Cleaning up"
check "helm delete still works, as an alias of helm uninstall (from the note)" run "$(hc "$(note_block "$NOTE" 13)")"
check_output "the release is gone" '^$' bash -c "helm list -q --namespace=$HC"

section "Tips when writing charts"
helm create my-chart >/dev/null
tips=$(note_block "$NOTE" 14)
check_output "helm template ./my-chart, with no release name: release-name (from the note)" \
  'name: release-name-my-chart' run "$(sed -n 1p <<<"$tips")"
check_output "helm template release-name ./my-chart (from the note)" 'name: release-name-my-chart' \
  run "$(sed -n 2p <<<"$tips")"
printf 'apiVersion: klingon\nkind: Bird\nmetadata: {name: x}\n' >my-chart/templates/klingon.yaml
check_output "helm template does not complain about apiVersion: klingon" 'apiVersion: klingon' helm template ./my-chart
check_fails "the API server does (helm install --dry-run=server)" helm install k ./my-chart --dry-run=server
rm my-chart/templates/klingon.yaml

section "Exploring the templating system"
note_block "$NOTE" 15 >my-chart/templates/explore.yaml
out=$(helm template ./my-chart --show-only templates/explore.yaml 2>&1)
assert_match "the value" '^hello: 80$' "$out"
assert_match "the comment is dropped" '^comment: *$' "$out"
assert_match "typeOf" '^type: map\[string\]interface \{\}$' "$out"
assert_match "toYaml | indent 2" $'^indented:\n  port: 80\n  type: ClusterIP$' "$out"
