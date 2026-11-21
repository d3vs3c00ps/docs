#!/usr/bin/env bash
# note: kubernetes/observability/logs-centralized.md
# env: kind
# timeout: 600
# efk.yaml is not deployed: Elasticsearch 5 / Kibana 5 images are amd64 only and EOL.
# The log-file claims are checked on a kind node.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2

section "Deploying EFK on our cluster"
efk=$(curl -fsSL "$UPSTREAM/k8s/efk.yaml")
kinds=$(grep -E '^kind:' <<<"$efk" | awk '{print $2}' | sort | uniq -c | awk '{print $1, $2}' | xargs)
check_output "a daemon set, two deployments, two services, roles and bindings (from the note)" \
  'DaemonSet.*Deployment.*Service' echo "$kinds"
assert_match "(1 DaemonSet)" '(^| )1 DaemonSet' "$kinds"
assert_match "(2 Deployments)" '(^| )2 Deployment' "$kinds"
assert_match "(2 Services)" '(^| )2 Service( |$)' "$kinds"
assert_match "(the images are the old ones flagged by the note)" 'elasticsearch:5' "$efk"
skip "kubectl apply efk.yaml, Kibana" "Elasticsearch 5 and Kibana 5 are amd64-only, unsupported images"

section "The itinerary of a log line"
kubectl run logger --image=alpine:3.22 -- sh -c 'echo to-stdout; echo to-stderr >&2; sleep 3600' >/dev/null
kubectl wait --for=condition=Ready pod/logger --timeout=120s >/dev/null
N=$(kubectl get pod logger -o jsonpath='{.spec.nodeName}')
f=$(docker exec "$N" sh -c "ls /var/log/containers/logger_${TEST_NS}_logger-*.log")
check_output "the file is /var/log/containers/<pod>_<namespace>_<container>-<id>.log" \
  "^/var/log/containers/logger_${TEST_NS}_logger-[0-9a-f]{64}\.log\$" echo "$f"
check_output "a symlink into /var/log/pods" "^/var/log/pods/${TEST_NS}_logger_" docker exec "$N" readlink -f "$f"
retry 30 bash -c "docker exec $N grep -q to-stderr $f"
check_output "not JSON: CRI format, timestamp stream tag message (the correction)" \
  '^[0-9-]+T[0-9:.]+(Z|[+-][0-9:]+) stdout F to-stdout$' docker exec "$N" grep to-stdout "$f"
check_output "with the stream added (from the note)" ' stderr F to-stderr$' docker exec "$N" grep to-stderr "$f"
check_output "kubectl logs reads that file (from the note)" '^to-stdout$' bash -c "kubectl logs logger | grep to-stdout"
