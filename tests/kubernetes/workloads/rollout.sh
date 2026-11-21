#!/usr/bin/env bash
# note: kubernetes/workloads/rollout.md
# env: kind
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/rollout
cd "$(mktemp -d)"

# dockercoins/worker:v0.2 is amd64-only. On other nodes, an image string that differs
# but runs everywhere stands in for it, so the same rollout steps run on both.
arch=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')
V02=dockercoins/worker:v0.2
[[ $arch == amd64 ]] || V02=docker.io/dockercoins/worker:v0.1
# block HEADING [N]: the note's block, with the stand-in image when needed.
block() { note_block "$NOTE" "$@" | sed "s|dockercoins/worker:v0.2|$V02|g"; }
image() { kubectl get deploy worker -o jsonpath='{.spec.template.spec.containers[0].image}'; }
rs_of() { kubectl get rs -l app=worker -o jsonpath="{range .items[?(@.spec.template.spec.containers[0].image==\"$1\")]}{.metadata.name}{end}"; }
rs_replicas() { kubectl get rs "$(rs_of "$1")" -o jsonpath='{.status.replicas}'; }
export -f rs_of rs_replicas

# DockerCoins as in ourapponkube and kubectlscale: worker at v0.1, 10 replicas.
for s in hasher rng webui worker; do kubectl create deployment $s --image=dockercoins/$s:v0.1 >/dev/null; done
kubectl create deployment redis --image=redis >/dev/null
kubectl expose deployment redis --port 6379 >/dev/null
kubectl expose deployment rng --port 80 >/dev/null
kubectl expose deployment hasher --port 80 >/dev/null
kubectl scale deployment worker --replicas=10 >/dev/null
check "DockerCoins runs, with 10 workers" kubectl wait --for=condition=available deploy --all --timeout=300s

section "Update strategy"
check_output "maxUnavailable and maxSurge default to 25%" '^25% 25%$' \
  kubectl get deploy worker -o jsonpath='{.spec.strategy.rollingUpdate.maxUnavailable} {.spec.strategy.rollingUpdate.maxSurge}'

section "Checking current rollout parameters"
check_output "the jq report (from the note)" '^\{"name":"worker","max(Surge|Unavailable)":"25%","max(Surge|Unavailable)":"25%"\}$' \
  bash -ec "$(block 'Checking current rollout parameters') | jq -c 'select(.name == \"worker\")'"

section "Rolling updates in practice"
check_output "kubectl rollout works with deployments, daemonsets and statefulsets" \
  'deployments.*daemonsets.*statefulsets' bash -c "kubectl rollout --help | tr '\n' ' '"
check_output "a DaemonSet uses RollingUpdate by default" '^RollingUpdate$' bash -c '
  kubectl apply --dry-run=server -o jsonpath="{.spec.updateStrategy.type}" -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: ds}
spec:
  selector: {matchLabels: {app: ds}}
  template:
    metadata: {labels: {app: ds}}
    spec: {containers: [{name: c, image: alpine}]}
EOF'

section "Rolling out the new worker service"
[[ $arch == amd64 ]] || skip "dockercoins/worker:v0.2 itself" "amd64-only image; on $arch the test uses $V02 for it"
while read -r cmd; do
  check_output "$cmd (from the note) watches" '^NAME' bash -c "timeout 3 $cmd; true"
done < <(block 'Rolling out the new' 1)
old_pod=$(kubectl get pods -l app=worker -o name | sed -n 1p)
check "kubectl set image (from the note)" bash -ec "$(block 'Rolling out the new' 2)"

section "Give it some time"
check_output "the grace period is 30 seconds" '^30$' \
  kubectl get deploy worker -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}'
# The worker ignores SIGTERM: an old Pod stays Terminating until SIGKILL, 30 s later.
check "an old Pod goes Terminating" retry 300 bash -c "[ -n \"\$(kubectl get $old_pod -o jsonpath='{.metadata.deletionTimestamp}')\" ]"
start=$(date +%s)
kubectl wait --for=delete "$old_pod" --timeout=120s >/dev/null
gone=$(($(date +%s) - start))
check "it stays Terminating for about the 30 s grace period (${gone}s)" test "$gone" -ge 25
check "the rollout completes" kubectl rollout status deploy worker --timeout=300s

section "Rolling out something invalid"
check "set image to the non-existent v0.3 (from the note)" bash -ec "$(block 'Rolling out something invalid' 1)"
check_fails "kubectl rollout status does not succeed: the rollout is stuck" \
  bash -c "$(block 'Rolling out something invalid' 2) --timeout=60s"
check_output "the new Pods cannot pull the image" 'ErrImagePull|ImagePullBackOff' \
  kubectl get pods -l app=worker -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}'
check_output "the progress deadline is 600 seconds by default" '^600$' \
  kubectl get deploy worker -o jsonpath='{.spec.progressDeadlineSeconds}'
# A small copy with a 10 s deadline, to see the message without waiting 10 minutes.
kubectl create deployment stuck --image=dockercoins/worker:v0.3 --dry-run=client -o yaml |
  sed 's/^spec:/spec:\n  progressDeadlineSeconds: 10/' | kubectl apply -f - >/dev/null
check_output "past the deadline, rollout status fails: exceeded its progress deadline" 'exceeded its progress deadline' \
  bash -c 'kubectl rollout status deploy stuck --timeout=120s 2>&1; true'

section "What's going on with our rollout?"
check "the rollout settles at 5 new replicas" retry 60 bash -c '[ "$(rs_replicas dockercoins/worker:v0.3)" = 5 ]'
check_output "and 8 old ones (2 stopped)" '^8$' rs_replicas "$V02"
check_output "the app is not dead: 8 workers available" '^8$' kubectl get deploy worker -o jsonpath='{.status.availableReplicas}'
skip "the app is 20-25% slower" "throughput depends on the machine; the test checks the Pod counts behind it"

section "Checking the dashboard during the bad rollout"
skip "the dashboard" "needs the dashboard from kubernetes/tooling/dashboard"

section "Recovering from a bad rollout"
check "rollout undo, then status (from the note)" bash -ec "$(block 'Recovering from a bad rollout')"
check_output "we are back on v0.2" "^$V02\$" image

section "Multiple undos"
check "rollout undo again (from the note)" bash -ec "$(block 'Multiple "undos"' 1)"
check_output "that did not work: back on the broken v0.3" '^dockercoins/worker:v0.3$' image
check "undo once more (from the note)" bash -ec "$(block "Multiple \"undos\" don't work" 1)"
check_output "back on v0.2: undo swaps the last two versions" "^$V02\$" image
check "that rollout completes" kubectl rollout status deploy worker --timeout=300s

section "Listing versions"
check_output "rollout history shows revisions 1, 5 and 6 (from the note)" '^1 5 6$' \
  bash -c "$(block 'Listing versions') | awk '/^[0-9]/ { print \$1 }' | xargs"

section "Explaining deployment revisions"
check_output "the revision is a ReplicaSet annotation (from the note)" 'deployment.kubernetes.io/revision: *6' \
  bash -ec "$(block 'Explaining deployment revisions')"
check_output "the missing revisions are in revision-history" '^2,4$' \
  kubectl get rs "$(rs_of "$V02")" -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision-history}'

section "Rolling back to an older version"
check "undo --to-revision=1 (from the note)" bash -ec "$(note_block "$NOTE" 'Rolling back to an older version' 1)"
check_output "the worker is back on v0.1" '^dockercoins/worker:v0.1$' image
check "that rollout completes" kubectl rollout status deploy worker --timeout=300s
out=$(bash -ec "$(note_block "$NOTE" 'Applying changes through a YAML patch')" 2>&1) && rc=0 || rc=$?
assert_eq "the patch block runs (from the note)" 0 "$rc"
assert_match "its report shows maxUnavailable 0" '"maxUnavailable": 0' "$out"
assert_match "and maxSurge 1" '"maxSurge": 1' "$out"
check_output "minReadySeconds is 10" '^10$' kubectl get deploy worker -o jsonpath='{.spec.minReadySeconds}'
