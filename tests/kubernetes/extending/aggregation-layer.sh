#!/usr/bin/env bash
# note: kubernetes/extending/aggregation-layer.md
# env: kind
# timeout: 1200
# Own cluster: metrics-server registers a cluster-wide APIService.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/extending/aggregation-layer
cd "$(mktemp -d)"
C=notes-agg
kind_cluster "$C"
out=$(kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" 2>&1) || { echo "$out"; kind_diag; exit 1; }
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
NODE=$C-control-plane
run() { bash -ec "$1" 2>&1; }
# v6 BLOCK: the API requests that the note's kubectl -v6 command makes.
v6() { bash -c "${1//node1/$NODE} 2>&1 >/dev/null"; }

section "How are resources organized?"
check_output "a cluster-scope core resource: /api/v1/nodes/NAME (from the note)" "verb=\"GET\" url=\"https://[^\"]*/api/v1/nodes/$NODE\"" v6 "$(note_block "$NOTE" 1)"
check_output "a cluster-scope non-core resource: /apis/GROUP/VERSION/... (from the note)" 'verb="GET" url="https://[^"]*/apis/rbac.authorization.k8s.io/v1/clusterroles/view"' v6 "$(note_block "$NOTE" 2)"
check_output "a namespaced core resource (from the note)" 'verb="GET" url="https://[^"]*/api/v1/namespaces/default/services/kubernetes"' v6 "$(note_block "$NOTE" 4)"
check_output "a namespaced non-core resource, as in the note's diagram" 'verb="GET" url="https://[^"]*/apis/apps/v1/namespaces/kube-system/daemonsets/kube-proxy"' \
  bash -c "kubectl -v6 get daemonset kube-proxy --namespace kube-system 2>&1 >/dev/null"

section "Accessing a subresource"
# On a new cluster, the kube-proxy container may not run yet.
kubectl -n kube-system rollout status ds/kube-proxy --timeout=180s >/dev/null
PODNAME=$(bash -c "{ $(note_block "$NOTE" 6); } >/dev/null; echo \$PODNAME")
check_output "PODNAME: a kube-proxy pod (from the note)" '^kube-proxy-[a-z0-9]{5}$' echo "$PODNAME"
out=$(PODNAME=$PODNAME bash -c "$(note_block "$NOTE" 7) 2>&1" || true)
check_output "the kube-proxy image has no echo: the command fails (the correction)" 'exec: "echo": executable file not found in \$PATH' echo "$out"
check_output "the request goes to the exec subresource, with the command in the query (from the note)" \
  "/api/v1/namespaces/kube-system/pods/$PODNAME/exec\?command=echo&command=hello&command=world&container=kube-proxy&stderr=true&stdout=true" echo "$out"
check_output "(kubectl now sends it as a WebSocket GET, not a POST: the correction)" "verb=\"GET\" url=\"https://[^\"]*/pods/$PODNAME/exec\?" echo "$out"

section "Listing what's supported on the server"
check_output "kubectl api-versions shows apiregistration.k8s.io (from the note)" '^apiregistration.k8s.io/v1$' run "$(note_block "$NOTE" 10)"
check_output "kubectl get apiservices does not list apiregistration.k8s.io (from the note)" '^absent$' bash -c "$(declare -f run); run \"\$1\" | grep -q '^v1.apiregistration.k8s.io ' && echo listed || echo absent" _ "$(note_block "$NOTE" 11)"
check_output "most groups are Local (from the note)" '^0$' bash -c "kubectl get apiservices --no-headers | grep -vc ' Local ' || true"

section "Finding resources"
check "metrics-server, installed as in its note" run "$(note_block kubernetes/observability/metrics-server 2) --wait --timeout 5m"
retry 120 bash -c "kubectl top nodes >/dev/null 2>&1"
check_output "metrics.k8s.io is registered with metrics-server (from the note)" '^v1beta1.metrics.k8s.io +[a-z-]+/metrics-server +True' run "$(note_block "$NOTE" 12)"
check_output "it has nodes and pods (from the note)" ' nodes .*NodeMetrics .*pods .*PodMetrics' bash -c "$(note_block "$NOTE" 13) | tr '\n' ' ' | tr -s ' '"
check_output "two resources named nodes (from the note)" '^nodes +no +v1 +false +Node .*nodes +metrics\.k8s\.io/v1beta1 +false +NodeMetrics' \
  bash -c "$(note_block "$NOTE" 14) | sort -r | tr '\n' ' '"
check_output "kubectl get nodes.metrics.k8s.io (from the note)" "^$NODE +[0-9]+[nm]? +[0-9]+(Ki|Mi)" bash -c "$(note_block "$NOTE" 15) | tail -1"
check_output "-o yaml shows the live CPU and memory (from the note)" 'kind: NodeMetrics.*cpu:.*memory:' bash -c "$(note_block "$NOTE" 16) | tr '\n' ' '"
check_output "kubectl top nodes -v6 reads metrics.k8s.io (from the note)" 'verb="GET" url="https://[^"]*/apis/metrics.k8s.io/v1beta1/nodes' \
  bash -c "kubectl top nodes -v6 2>&1"

section "Aggregation layer in practice"
check_output "kubectl describe apiservices v1beta1.metrics.k8s.io: group priority (from the note)" 'Group Priority Minimum: +100' run "$(note_block "$NOTE" 19)"
check_output "(and the Service it proxies to)" 'Service: +Name: +metrics-server +Namespace: +[a-z-]+' bash -c "$(note_block "$NOTE" 19) | tr '\n' ' '"
