#!/usr/bin/env bash
# note: kubernetes/observability/metrology/quickstart.md
# env: kind
# timeout: 1800
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/observability/metrology/quickstart
cd "$(mktemp -d)"

# Random local ports: compose tests of other runs may hold 9090 and 3000 on this host.
PPORT=$((20000 + RANDOM % 20000))
GPORT=$((PPORT + 1))
PIDS=()
OWN_MS=0
cleanup() {
  local p
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  helm uninstall kube-prometheus-stack -n monitoring --wait >/dev/null 2>&1 || true
  kubectl -n kube-system delete service kube-prometheus-stack-kubelet --ignore-not-found >/dev/null 2>&1 || true
  kubectl get crd -o name | grep monitoring.coreos.com | xargs -r kubectl delete >/dev/null 2>&1 || true
  kubectl delete namespace monitoring --ignore-not-found >/dev/null 2>&1 || true
  ((OWN_MS)) && { helm uninstall metrics-server -n kube-system >/dev/null 2>&1 || true; }
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT

# fails_with REGEX CMD...: CMD fails and its output matches REGEX.
fails_with() {
  local re=$1 out
  shift
  if out=$("$@" 2>&1); then echo "unexpected success: $out"; return 1; fi
  grep -Eq -- "$re" <<<"$out" || { echo "$out"; return 1; }
}
# promq QUERY: the result vector of an instant query, one "labels value" line per series.
promq() {
  curl -s "localhost:$PPORT/api/v1/query" --data-urlencode "query=$1" |
    jq -r '.data.result[] | "\(.metric | tostring) \(.value[1])"'
}
# promq_has QUERY REGEX: the query returns a series whose line matches REGEX.
promq_has() { local out; out=$(promq "$1") && grep -Eq -- "$2" <<<"$out"; }
promcount() { promq "$1" | grep -c . || true; }
# port_forward BLOCK LOCAL_PORT: start the note's port-forward on another local port.
port_forward() {
  bash -c "$(sed -E "s/ [0-9]+:([0-9]+)\$/ $2:\1/" <<<"$1")" >/dev/null 2>&1 &
  PIDS+=($!)
}

section "Install metrics-server"
if kubectl get apiservice v1beta1.metrics.k8s.io >/dev/null 2>&1; then
  skip "kubectl top fails before metrics-server is installed" "another release already serves the Metrics API on this cluster"
  skip "without --kubelet-insecure-tls, scrapes fail on kind" "another release already serves the Metrics API on this cluster"
else
  OWN_MS=1
  check "with no metrics-server: 'Metrics API not available'" \
    fails_with 'Metrics API not available' kubectl top nodes
  # The note's command without the --set line: the kubelet certificates are refused.
  check "install without --kubelet-insecure-tls" \
    bash -ec "$(note_block "$NOTE" 'Install metrics-server' 1 | grep -v 'kubelet-insecure-tls' | sed 's/--wait --timeout 5m//')"
  check "metrics-server logs: the kubelet certificate has no IP SANs" \
    retry 90 bash -c "kubectl -n kube-system logs deploy/metrics-server | grep -q \"doesn't contain any IP SANs\""
  check_output "and the APIService stays unavailable" '^False$' \
    kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'
  check "install with --kubelet-insecure-tls (from the note)" bash -ec "$(note_block "$NOTE" 'Install metrics-server' 1)"
fi

section "Kubelet certificates on kind"
cert=$(bash -c "$(note_block "$NOTE" 'Kubelet certificates on kind' 1 | sed "s/kind-worker/$CLUSTER-worker/")" 2>&1 || true)
assert_match "the kubelet certificate is signed by its own CA" "issuer=CN=$CLUSTER-worker-ca@" "$cert"
assert_match "it holds the node name" "DNS:$CLUSTER-worker" "$cert"
assert_no_match "and no IP address" 'IP Address' "$cert"

section "Use kubectl top"
check "wait for the Metrics API (from the note)" bash -ec "$(note_block "$NOTE" 'Use `kubectl top`' 1)"
check "kubectl top nodes and pods (from the note)" retry 60 bash -ec "$(note_block "$NOTE" 'Use `kubectl top`' 2)"
check_output "kubectl top nodes has CPU(%) and MEMORY(%) columns" 'CPU\(cores\) +CPU\(%\) +MEMORY\(bytes\) +MEMORY\(%\)' kubectl top nodes
# metrics-server reports the static pods a little later than the nodes.
for _ in $(seq 30); do
  raw=$(bash -ec "$(note_block "$NOTE" 'Use `kubectl top`' 4)" 2>&1 || true)
  grep -q '^etcd-' <<<"$raw" && break
  sleep 2
done
assert_match "the raw Metrics API lists the nodes (from the note)" "\"name\": \"$CLUSTER-control-plane\"" "$raw"
assert_match "with usage in nanocores and KiB" '"cpu": "[0-9]+n"' "$raw"
assert_match "and the kube-system pods" '^etcd-' "$raw"

section "Install kube-prometheus-stack"
check "helm install kube-prometheus-stack 92.18.0 (from the note)" bash -ec "$(note_block "$NOTE" 'Install kube-prometheus-stack' 1)"
pods=$(bash -ec "$(note_block "$NOTE" 'Install kube-prometheus-stack' 2)" 2>&1 || true)
for p in alertmanager-kube-prometheus-stack-alertmanager-0 kube-prometheus-stack-grafana- \
  kube-prometheus-stack-kube-state-metrics- kube-prometheus-stack-operator- \
  kube-prometheus-stack-prometheus-node-exporter- prometheus-kube-prometheus-stack-prometheus-0; do
  assert_match "pod $p is Running" "^${p}[^ ]* +[0-9]/[0-9] +Running" "$pods"
done
check_output "one node-exporter per node" '^3$' bash -c "grep -c node-exporter <<<'$pods'"
check_output "another release name gives longer names and another release label" 'kps-kube-prometheus-stack-prometheus' \
  helm template kps kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version 92.18.0 -n monitoring
check_output "the ServiceMonitor selector follows the release name" 'release: "?kps"?$' \
  bash -c "helm template kps kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version 92.18.0 -n monitoring | grep -A2 'serviceMonitorSelector:'"
check_output "Prometheus data is in an emptyDir by default" 'emptyDir' \
  kubectl -n monitoring get statefulset prometheus-kube-prometheus-stack-prometheus \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="prometheus-kube-prometheus-stack-prometheus-db")]}'

section "Open Prometheus"
port_forward "$(note_block "$NOTE" 'Open Prometheus' 1)" "$PPORT"
check "port-forward to Prometheus (from the note, local port $PPORT)" retry 30 curl -sf -o /dev/null "localhost:$PPORT/-/ready"
check_output "Prometheus keeps 10 days by default" '"10d"' \
  bash -c "curl -s localhost:$PPORT/api/v1/status/runtimeinfo | jq '.data.storageRetention'"
check "up lists the API server as up (from the note)" \
  retry 60 bash -ec "$(note_block "$NOTE" 'Open Prometheus' 2 | sed "s/localhost:9090/localhost:$PPORT/") | grep -Eq '^apiserver .* 1$'"
up_lines() { bash -ec "$(note_block "$NOTE" 'Open Prometheus' 2 | sed "s/localhost:9090/localhost:$PPORT/")"; }
job_up() { up_lines | grep -Eq "^$1 .* 1$"; }
for job in kubelet node-exporter kube-state-metrics coredns; do
  check "target $job is up" retry 90 job_up "$job"
done
check "on kind, the kube-scheduler target is down" \
  retry 90 bash -c "curl -s localhost:$PPORT/api/v1/targets | jq -e '.data.activeTargets[] | select(.labels.job==\"kube-scheduler\" and .health==\"down\")'"

section "Open Grafana"
pw=$(bash -ec "$(note_block "$NOTE" 'Open Grafana' 1)")
check_output "the admin password is random, not prom-operator" '^.{20,}$' echo "$pw"
assert_no_match "it is not prom-operator" '^prom-operator$' "$pw"
port_forward "$(note_block "$NOTE" 'Open Grafana' 2)" "$GPORT"
check "port-forward to Grafana (from the note, local port $GPORT)" retry 30 curl -sf -o /dev/null "localhost:$GPORT/api/health"
check_output "admin/prom-operator is refused" '^401$' \
  curl -s -o /dev/null -w '%{http_code}' -u admin:prom-operator "localhost:$GPORT/api/search"
titles=$(bash -ec "$(note_block "$NOTE" 'Open Grafana' 3 | sed "s/localhost:3000/localhost:$GPORT/")" 2>&1 || true)
assert_match "the API lists the Compute Resources dashboards (from the note)" 'Kubernetes / Compute Resources / Cluster' "$titles"
all=$(curl -s -u "admin:$pw" "localhost:$GPORT/api/search?type=dash-db" | jq -r '.[].title')
for d in 'Kubernetes / Compute Resources / Namespace (Pods)' 'Kubernetes / Compute Resources / Node (Pods)' \
  'Node Exporter / Nodes' 'Kubernetes / API server' 'Kubernetes / Persistent Volumes'; do
  check "dashboard '$d' exists" grep -Fxq "$d" <<<"$all"
done
check_output "about 30 dashboards" '^(2[5-9]|3[0-9])$' bash -c "wc -l <<<'$all' | tr -d ' '"

section "First PromQL queries for a cluster"
# Objects for the queries to find, in the test namespace.
kubectl run crasher --image=busybox:1.37 -- sh -c 'sleep 5; exit 1' >/dev/null
kubectl run stuck --image=busybox:1.37 --overrides='{"spec":{"nodeSelector":{"no-such-label":"x"}}}' -- sleep 3600 >/dev/null
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: never-ready}
spec:
  containers:
    - name: c
      image: busybox:1.37
      command: ["sleep", "3600"]
      readinessProbe: {exec: {command: ["false"]}, periodSeconds: 5}
YAML
q_node_cpu=$(note_block "$NOTE" 'First PromQL' 1)
q_node_mem=$(note_block "$NOTE" 'First PromQL' 2)
q_ns_cpu=$(note_block "$NOTE" 'First PromQL' 3)
q_restarts=$(note_block "$NOTE" 'First PromQL' 4)
q_notready=$(note_block "$NOTE" 'First PromQL' 5)
q_pending=$(note_block "$NOTE" 'First PromQL' 6)
three_series() { [ "$(promcount "$1")" -eq 3 ]; }
check "node CPU %: one series per node" retry 120 three_series "$q_node_cpu"
check "node memory %: one series per node" retry 60 three_series "$q_node_mem"
assert_eq "node memory % is between 0 and 100" ok \
  "$(promq "$q_node_mem" | awk '{ if ($2 > 0 && $2 < 100) print "ok"; else print "bad" }' | sort -u)"
check "pod CPU by namespace includes kube-system" retry 60 promq_has "$q_ns_cpu" '"namespace":"kube-system"'
check "the restarts query finds the crashing pod" retry 240 promq_has "$q_restarts" "\"pod\":\"crasher\""
check "the not-ready query finds the pod with a failing probe" retry 120 promq_has "$q_notready" '"pod":"never-ready"'
check "the Pending query finds the pod that cannot be scheduled" retry 120 promq_has "$q_pending" '"pod":"stuck"'
check_output "the curl block prints CPU per namespace (from the note)" "^$TEST_NS [0-9.e-]+$" \
  bash -ec "$(note_block "$NOTE" 'First PromQL' 7 | sed "s/localhost:9090/localhost:$PPORT/")"
check_output "container!=\"\" removes pod-level cgroup series, which exist" '^\{\} [1-9][0-9]*$' \
  promq 'count(container_cpu_usage_seconds_total{container="", pod!=""})'

section "Clean up"
if ((OWN_MS)); then
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  PIDS=()
  check "the clean-up block (from the note)" bash -ec "$(note_block "$NOTE" 'Clean up' 1)"
  check_output "no monitoring.coreos.com CRD is left" '^0$' bash -c "kubectl get crd -o name | grep -c monitoring.coreos.com || true"
  check_fails "the kubelet Service is gone" kubectl -n kube-system get service kube-prometheus-stack-kubelet
  check_fails "the Metrics API is gone" kubectl get apiservice v1beta1.metrics.k8s.io
else
  skip "the clean-up block (from the note)" "metrics-server belongs to another release here"
fi
