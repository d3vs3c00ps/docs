#!/usr/bin/env bash
# note: kubernetes/networking/cilium/hubble.md
# env: kind
# timeout: 1800
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
source "$NOTES_ROOT/tests/kubernetes/networking/cilium/cilium-lib.bash"

NOTE=kubernetes/networking/cilium/hubble
WORK=$(mktemp -d)
cd "$WORK"
C=cil-hubble
cilium_cluster "$C" 1

section "Enabling it"
check "the note's helm upgrade enables hubble, relay and the UI" \
  bash -ec "$(note_block "$NOTE" 'Enabling it' 1)"
check "hubble-relay comes up" \
  kubectl -n kube-system rollout status deploy/hubble-relay --timeout=300s
check "the UI comes up" \
  kubectl -n kube-system rollout status deploy/hubble-ui --timeout=300s
check "the note's download block verifies the checksum and installs the hubble CLI" \
  bash -ec "$(note_block "$NOTE" 'Enabling it' 3 | sed 's/^sudo //')"

section "Connecting"
# The note's manual alternative: relay listens on 4245, the CLI defaults to it.
kubectl -n kube-system port-forward service/hubble-relay 4245:80 >/dev/null 2>&1 &
PF=$!
trap '_k8s_rc=$?; kill $PF 2>/dev/null; _k8s_exit' EXIT
check "relay answers through the port-forward" retry 60 hubble status
check_output "hubble status sees every node through relay" '2/2 nodes|Connected Nodes: 2/2' \
  bash -c 'hubble status | tr "\n" " "'
check_output "the per-node ring buffer is 4095 flows by default (from the note)" \
  '4,?095|8,?190' bash -c 'hubble status'

section "Querying flows"
# Generate some traffic, including DNS, then run the note's query shapes.
kubectl create deployment frontend --image=nginx:1.29 >/dev/null
kubectl expose deployment frontend --port=80 >/dev/null
kubectl rollout status deployment/frontend --timeout=180s >/dev/null
kubectl run client --image=busybox --restart=Never -- \
  sh -c 'for i in 1 2 3; do wget -qO- http://frontend >/dev/null; sleep 1; done' >/dev/null
sleep 10
check_output "flows are labelled with workloads, not only IPs" 'frontend' \
  hubble observe --pod default/frontend --last 20
check "only what was dropped (the note's most useful query)" \
  hubble observe --verdict DROPPED --last 20
check "DNS lookups" hubble observe --protocol dns --last 20
check "the note's jq one-liner aggregates drops" \
  bash -ec "$(note_block "$NOTE" 'Querying flows' 2)"

section "Metrics"
# The note's block is flags only; eval would brace-expand {dns,drop,...}.
assert_match "the note's metric list includes the drop metric" \
  'hubble.metrics.enabled=.*drop' "$(note_block "$NOTE" 'Metrics' 1)"
check "enable the note's flow metrics" \
  helm upgrade cilium oci://quay.io/cilium/charts/cilium \
  --version "$CILIUM_VERSION" --namespace kube-system --reuse-values \
  --set 'hubble.metrics.enabled={dns,drop,tcp,flow,port-distribution,icmp,httpV2}' \
  --set hubble.metrics.enableOpenMetrics=true \
  --set prometheus.enabled=true \
  --set operator.prometheus.enabled=true
kubectl -n kube-system rollout status ds/cilium --timeout=300s >/dev/null
kubectl -n kube-system port-forward ds/cilium 9965:9965 >/dev/null 2>&1 &
PF2=$!
trap '_k8s_rc=$?; kill $PF $PF2 2>/dev/null; _k8s_exit' EXIT
retry 30 curl -sf http://localhost:9965/metrics >/dev/null
check_output "hubble metrics are exposed for Prometheus" 'hubble_' \
  curl -sf http://localhost:9965/metrics
