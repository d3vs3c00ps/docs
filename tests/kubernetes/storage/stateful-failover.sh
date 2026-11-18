#!/usr/bin/env bash
# note: kubernetes/storage/stateful-failover.md
# env: kind
# timeout: 1800
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/storage/stateful-failover
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
HOME=$(mktemp -d)
export HOME
cd "$HOME"
mkdir -p container.training/k8s
curl -fsSL "$UPSTREAM/k8s/postgres.yaml" >container.training/k8s/postgres.yaml
# The lab disconnects a node and deletes it: own cluster.
C=notes-failover
kind_cluster "$C"
printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes: [{role: control-plane}, {role: worker}, {role: worker}]\n' >kind.yaml
out=$(kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" --config kind.yaml 2>&1) || { echo "$out"; kind_diag; exit 1; }
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
run() { bash -ec "$1" 2>&1; }
# pg N: the note's block N, run as the postgres user in postgres-0 (the note's `su postgres` shell).
pg() { kubectl exec postgres-0 -- su postgres -c "$(note_block "$NOTE" "$1")" 2>&1; }
count() { kubectl exec postgres-0 -- su postgres -c "psql -tA demo -c 'select count(*) from $1'"; }

section "Our Postgres Stateful set"
assert_eq "the inline YAML is the upstream file" "$(cat container.training/k8s/postgres.yaml)" "$(note_block "$NOTE" 2)"
check "apply it (from the note)" run "$(note_block "$NOTE" 3)"
check "postgres-0 runs" kubectl rollout status statefulset/postgres --timeout=300s
check_output "a 1Gi PVC from the claim template" '^postgres-postgres-0 1Gi$' \
  kubectl get pvc -o jsonpath='{.items[0].metadata.name} {.items[0].spec.resources.requests.storage}'

section "Testing our PostgreSQL pod"
retry 60 bash -c 'kubectl exec postgres-0 -- su postgres -c "psql -l" >/dev/null 2>&1'
out=$(pg 5)
for db in postgres template0 template1; do assert_match "psql -l lists $db (from the note)" "^ $db " "$out"; done

section "Inserting data in PostgreSQL"
check "createdb demo (from the note)" pg 6
check "pgbench -i demo (from the note)" pg 7
check_output "demo exists (from the note)" '^ demo ' pg 8
check_output "pgbench_accounts has 100000 rows (from the note)" '^ +100000$' pg 9
check_output "pgbench_history is empty (from the note)" '^ +0$' pg 10

section "Testing the load generator"
check_output "pgbench for 10 seconds, with progress every second (from the note)" 'progress: 10\.0 s' pg 11
check_output "the history table has rows now" '^[1-9][0-9]*$' count pgbench_history

section "Generating transactions, disconnecting the node"
kubectl exec postgres-0 -- su postgres -c "$(note_block "$NOTE" 13)" >/dev/null 2>&1 &
PGBENCH=$!
sleep 30
NODE=$(run "$(note_block "$NOTE" 15 | sed -n 1p)")
check_output "the node running the database (from the note)" "postgres-0 .* $NODE " run "$(note_block "$NOTE" 14)"
check_output "the note's way to find the interface: ip route ls default" '^default via \S+ dev \S+' \
  docker exec "$NODE" ip route ls default
# On kind, a node is a container: leaving the docker network is like unplugging it.
before=$(count pgbench_history)
t0=$(date +%s)
check "disconnect the node" docker network disconnect kind "$NODE"

section "Node Ready → NotReady"
retry 180 bash -c "kubectl get node $NODE --no-headers | grep -q NotReady"
t1=$(date +%s)
check_output "the node becomes NotReady" 'NotReady' kubectl get node "$NODE" --no-headers
echo "# NotReady after $((t1 - t0))s"
check "within about a minute (50s grace period in current Kubernetes)" test $((t1 - t0)) -le 90
check_output "it gets a NoSchedule taint" 'node.kubernetes.io/unreachable' \
  kubectl get node "$NODE" -o jsonpath='{.spec.taints[*].key}'
check_output "the pod is not ready" '^False$' \
  kubectl get pod postgres-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'

section "Pod eviction"
# Pods tolerate node.kubernetes.io/unreachable for 300s, then they are evicted.
check_output "pods tolerate the unreachable node for 300s" '^300$' \
  kubectl get pod postgres-0 -o jsonpath='{.spec.tolerations[?(@.key=="node.kubernetes.io/unreachable")].tolerationSeconds}'
retry 420 bash -c "[ -n \"\$(kubectl get pod postgres-0 -o jsonpath='{.metadata.deletionTimestamp}')\" ]"
t2=$(date +%s)
check_output "after about 5 minutes, postgres-0 is Terminating" '^20' \
  kubectl get pod postgres-0 -o jsonpath='{.metadata.deletionTimestamp}'
echo "# Terminating after $((t2 - t0))s"
sleep 60
check_output "and stays Terminating: no replacement for a StatefulSet pod (no split brain)" "^$NODE\$" \
  kubectl get pod postgres-0 -o jsonpath='{.spec.nodeName}'

section "The Node is gone"
check "kubectl delete the node (from the note)" kubectl delete node "$NODE"
kill "$PGBENCH" 2>/dev/null || true
retry 180 bash -c "[ \"\$(kubectl get pod postgres-0 -o jsonpath='{.spec.nodeName}')\" != $NODE ]" || true
check_output "the Terminating pod is removed, and a replacement postgres-0 is created" '^postgres-0$' \
  kubectl get pod postgres-0 -o jsonpath='{.metadata.name}'
sleep 20
check_output "but it doesn't start" '^Pending$' kubectl get pod postgres-0 -o jsonpath='{.status.phase}'
check_output "here because kind's local-path volume only exists on the lost node" 'volume node affinity conflict|node affinity' \
  kubectl describe pod postgres-0
skip "multiple attachment, force-detach, failover is complete" \
  "needs storage that survives the loss of a node (cloud disks, a SAN, Portworx, OpenEBS replicated); kind's local-path volumes stay on their node"
echo "# history rows before the disconnection: $before"
