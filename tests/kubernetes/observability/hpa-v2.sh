#!/usr/bin/env bash
# note: kubernetes/observability/hpa-v2.md
# env: kind
# timeout: 2100
# jpetazzo/httplat is amd64 only: its pod cannot run on arm64 nodes, so the latency
# metric, the adapter rule's output and the final autoscaling are skipped there.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/observability/hpa-v2
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
HOME=$(mktemp -d)
export HOME
cd "$HOME"
mkdir -p container.training/k8s
for f in dockercoins.yaml hpa-v2-pa-httplat.yaml; do curl -fsSL "$UPSTREAM/k8s/$f" >"container.training/k8s/$f"; done
# Own cluster: the lab installs cluster-wide APIs (custom.metrics.k8s.io).
C=notes-hpa2
kind_cluster "$C"
out=$(kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" 2>&1) || { echo "$out"; kind_diag; exit 1; }
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
ARCH=$(kubectl get node "$C-control-plane" -o jsonpath='{.status.nodeInfo.architecture}')
# kns is not installed; on this private kubeconfig, set-context does the same.
run() { bash -ec "${1//kns customscaling/kubectl config set-context --current --namespace customscaling >/dev/null}" 2>&1; }
# hpa_with SNIPPET: an HPA around one item of the metrics list, checked by the API server.
hpa_with() {
  printf 'apiVersion: autoscaling/v2\nkind: HorizontalPodAutoscaler\nmetadata: {name: t}\nspec:\n  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: rng}\n  maxReplicas: 5\n  metrics:\n%s\n' \
    "  ${1//$'\n'/$'\n'  }" | kubectl create --dry-run=server -f - 2>&1
}

section "Deploying DockerCoins"
check "create the namespace and switch to it (from the note)" run "$(note_block "$NOTE" 'Deploying DockerCoins' 1)"
check "apply dockercoins.yaml, 10 workers (from the note)" run "$(note_block "$NOTE" 'Deploying DockerCoins' 2)"
for d in hasher redis rng webui worker; do kubectl rollout status "deploy/$d" --timeout=300s >/dev/null; done
check_output "(10 workers)" '^10$' kubectl get deploy worker -o jsonpath='{.status.readyReplicas}'

section "Current state of affairs"
check_output "kubectl get service webui: a NodePort (from the note)" '^webui +NodePort' run "$(note_block "$NOTE" 'Current state of affairs' 1)"
check_output "kubectl get service rng (from the note)" '^rng +ClusterIP' run "$(note_block "$NOTE" 'Current state of affairs' 2)"
kubectl rollout status deploy/rng --timeout=300s >/dev/null
sleep 20
lat=$(kubectl run lat --rm -i --restart=Never --image=curlimages/curl:8.17.0 -- \
  sh -c 'for i in 1 2 3 4 5; do curl -s -o /dev/null -w "%{time_total}\n" http://rng/; done' 2>/dev/null | sort -n | sed -n 3p || true)
check_output "with 10 workers, rng latency is well above 100 ms (median of 5: ${lat}s)" '^0\.[3-9]|^[1-9]' echo "$lat"

section "Measuring latency"
check "kubectl create deployment httplat (from the note)" run "$(note_block "$NOTE" 'Measuring latency' 1)"
check "kubectl expose deployment httplat (from the note)" run "$(note_block "$NOTE" 'Measuring latency' 2)"
if [ "$ARCH" != amd64 ]; then
  skip "httplat serves metrics on port 9080" "jpetazzo/httplat is amd64 only; these nodes are $ARCH"
fi

section "Install and configure Prometheus"
assert_match "the note pins the tested chart" "--version $PROMETHEUS_CHART" "$(note_block "$NOTE" 'Install Prometheus' 1)"
check "the note's helm command" run "$(note_block "$NOTE" 'Install Prometheus' 1) --wait --timeout 10m"
check_output "Prometheus is a NodePort on 30090 (from the note)" '^30090$' \
  kubectl -n prometheus get svc prometheus-server -o jsonpath='{.spec.ports[0].nodePort}'
check "annotate the httplat service (from the note)" run "$(note_block "$NOTE" 'Configure Prometheus' 1)"
kubectl -n prometheus port-forward svc/prometheus-server 29090:80 >/dev/null 2>&1 &
PF=$!
trap '_k8s_rc=$?; kill $PF 2>/dev/null || true; _k8s_exit' EXIT
retry 120 bash -c "curl -s 'localhost:29090/api/v1/query?query=up%7Bjob%3D%22kubernetes-service-endpoints%22%7D' | jq -e '.data.result | length > 0' >/dev/null"
labels=$(curl -s 'localhost:29090/api/v1/query?query=up%7Bjob%3D%22kubernetes-service-endpoints%22%7D' | jq -r '.data.result[0].metric | keys | join(" ")')
check_output "annotated Services get the 'namespace' and 'service' labels (used by the mapping rule)" '(^| )namespace( |$).*(^| )service( |$)' echo "$labels"
check_output "(not kubernetes_name / kubernetes_namespace, as the old text said)" '^$' bash -c "grep -o 'kubernetes_name' <<<'$labels' || true"

section "Details about the metrics list"
check_output "Resource (from the note)" 'created \(server dry run\)' hpa_with "$(note_block "$NOTE" '`Resource`' 1)"
check_output "Pods (from the note)" 'created \(server dry run\)' hpa_with "$(note_block "$NOTE" '`Pods`' 1)"
check_output "Object (from the note, with type: Value)" 'created \(server dry run\)' hpa_with "$(note_block "$NOTE" '`Object`' 1)"
check_output "the original Object example (AverageValue with value:) is accepted, but has no averageValue (the correction)" '^\{"type":"AverageValue","value":"100"\}$' \
  bash -c "hpa_with \"\$1\" >/dev/null; printf '%s' \"\$1\" | sed 's/^/  /' | { printf 'apiVersion: autoscaling/v2\nkind: HorizontalPodAutoscaler\nmetadata: {name: t}\nspec:\n  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: rng}\n  maxReplicas: 5\n  metrics:\n'; cat; } | kubectl create --dry-run=server -f - -o jsonpath='{.spec.metrics[0].object.target}'" _ "$(note_block "$NOTE" '`Object`' 1 | sed 's/type: Value/type: AverageValue/')"
check_output "External (from the note, with a matchLabels selector)" 'created \(server dry run\)' \
  hpa_with "$(note_block "$NOTE" '`External`' 1)"
check_output "the original string selector is refused (the correction)" 'cannot unmarshal string .*selector of type v1.LabelSelector' \
  bash -c "$(declare -f hpa_with); hpa_with \"\$1\"; true" _ "$(note_block "$NOTE" '`External`' 1 | sed -n '/selector:/q;p'; printf '        selector: \"queue=worker_tasks\"\n      target:\n        type: AverageValue\n        averageValue: 30\n')"
assert_match "the full YAML is the upstream file" "$(sed -n 1p container.training/k8s/hpa-v2-pa-httplat.yaml)" "$(note_block "$NOTE" 'One more thing ...' 1)"

section "Creating the autoscaling policy"
check "kubectl apply hpa-v2-pa-httplat.yaml (from the note)" run "$(note_block "$NOTE" 'Registering the autoscaling policy' 1)"
check_output "no custom.metrics.k8s.io APIService yet (from the note)" '^$' bash -c "kubectl get apiservices -o name | grep custom.metrics || true"
retry 120 bash -c "kubectl get hpa rng -o jsonpath='{.status.conditions}' | grep -q 'custom.metrics.k8s.io'"
check_output "the HPA cannot get its metric: no custom metrics API (from the note)" 'no custom metrics API \(custom.metrics.k8s.io\) registered|custom.metrics.k8s.io' \
  bash -c "kubectl -n kube-system logs kube-controller-manager-$C-control-plane --tail=200 | grep -m1 custom.metrics"

section "Deploying the Prometheus adapter"
assert_match "the note pins the tested chart" "--version $PROMETHEUS_ADAPTER_CHART" "$(note_block "$NOTE" 'Deploying the Prometheus adapter' 1)"
check "the note's helm command" run "$(note_block "$NOTE" 'Deploying the Prometheus adapter' 1) --wait --timeout 5m"
retry 120 bash -c "kubectl get apiservice v1beta1.custom.metrics.k8s.io -o jsonpath='{.status.conditions[0].status}' | grep -qx True"
check_output "the adapter registered itself (from the note)" 'v1beta1.custom.metrics.k8s.io +prometheus-adapter/prometheus-adapter +True' \
  run "$(note_block "$NOTE" 'Troubleshooting the adapter' 1)"
check_output "and serves the API (from the note)" '"groupVersion":"custom.metrics.k8s.io/v1beta1"' run "$(note_block "$NOTE" 'Troubleshooting the adapter' 2)"

section "Configuring the Prometheus adapter"
kubectl -n prometheus-adapter get configmap prometheus-adapter -o jsonpath='{.data.config\.yaml}' >config.yaml
check_output "the ConfigMap has a rules section (from the note)" '^rules:' cat config.yaml
note_block "$NOTE" 'The mapping rule' 1 | sed 's/^    //' >rule.yaml
awk 'FNR==NR{r=r $0 "\n"; next} {print} /^rules:/{printf "%s", r}' rule.yaml config.yaml >new.yaml
check_output "the rule lands in the rules list" '^- seriesQuery: .httplat_latency_seconds_sum' bash -c "sed -n '/^rules:/,\$p' new.yaml | grep httplat_latency_seconds_sum"
kubectl -n prometheus-adapter create configmap prometheus-adapter --from-file=config.yaml=new.yaml --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
check "restart the adapter (from the note)" run "$(note_block "$NOTE" 'Editing the adapter' 2)"
check "it accepts the new configuration" kubectl -n prometheus-adapter rollout status deploy/prometheus-adapter --timeout=180s
check_output "(no configuration error in its logs)" '^$' bash -c \
  "kubectl -n prometheus-adapter logs deploy/prometheus-adapter 2>/dev/null | grep -iE 'unable to load|error parsing|invalid' || true"
if [ "$ARCH" != amd64 ]; then
  skip "the httplat_latency_seconds metric through the API, and the rng scaling" "needs httplat (amd64 only); these nodes are $ARCH"
fi
