#!/usr/bin/env bash
# note: kubernetes/workloads/disruptions.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/disruptions
cd "$(mktemp -d)"
# Other tests share this cluster: drain one worker only, restricted to our own Pods
# (--pod-selector), and always uncordon it on exit.
node=$CLUSTER-worker2
cleanup() {
  local rc=$?
  kubectl uncordon "$node" >/dev/null 2>&1 || true
  _k8s_stop_cpk
  _k8s_cleanup
  _t_finish "$rc"
}
trap cleanup EXIT
image=registry.k8s.io/pause:3.10

# deploy NAME REPLICAS: a Deployment of pause Pods, labelled app=NAME. They prefer $node,
# but can move to another worker when it is drained.
deploy() {
  kubectl create deployment "$1" --image="$image" --replicas="$2" --dry-run=client -o json |
    jq --arg n "$node" '.spec.template.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution =
      [{"weight": 100, "preference": {"matchExpressions": [{"key": "kubernetes.io/hostname", "operator": "In", "values": [$n]}]}}]' |
    kubectl apply -f - >/dev/null
  kubectl rollout status "deploy/$1" --timeout=120s >/dev/null
}
# pdb NAME SPEC-JSON: a PDB for app=NAME.
pdb() {
  kubectl apply -f - >/dev/null <<EOF
{"apiVersion": "policy/v1", "kind": "PodDisruptionBudget", "metadata": {"name": "$1"},
 "spec": $(jq -c --arg n "$1" '. + {selector: {matchLabels: {app: $n}}}' <<<"$2")}
EOF
}
# allowed PDB N: wait until the PDB allows N disruptions.
allowed() {
  retry 60 bash -c "[ \"\$(kubectl get pdb $1 -o jsonpath='{.status.observedGeneration}/{.status.disruptionsAllowed}')\" = \
\"\$(kubectl get pdb $1 -o jsonpath='{.metadata.generation}')/$2\" ]"
}
# evict POD: call the eviction API, as kubectl drain does.
evict() {
  kubectl create --raw "/api/v1/namespaces/$TEST_NS/pods/$1/eviction" -f - <<EOF
{"apiVersion": "policy/v1", "kind": "Eviction", "metadata": {"name": "$1", "namespace": "$TEST_NS"}}
EOF
}
# evict_out POD: the eviction API's answer, even a refusal.
evict_out() { evict "$1" 2>&1 || true; }
first() { kubectl get pods -l "app=$1" -o jsonpath='{.items[0].metadata.name}'; }

section "Node outage play-by-play"
check_output "each node has a Lease in kube-node-lease" "^$node " kubectl -n kube-node-lease get lease --no-headers
skip "a node that stops renewing gets the unreachable taints, then its Pods are evicted" \
  "it needs a node to go down; stopping one would disrupt other tests on the shared cluster"

section "Node outage notes"
kubectl run probe --image="$image" >/dev/null
check_output "Pods tolerate unreachable:NoExecute for 300 s (DefaultTolerationSeconds)" '^300$' \
  kubectl get pod probe -o jsonpath='{.spec.tolerations[?(@.key=="node.kubernetes.io/unreachable")].tolerationSeconds}'
skip "StatefulSet Pods only recover once the Node object is deleted" "needs a node outage"

section "Memory/disk pressure play-by-play"
conf=$(kubectl get --raw "/api/v1/nodes/$node/proxy/configz")
check_output "no soft threshold by default" '^null$' jq -c '.kubeletconfig.evictionSoft' <<<"$conf"
skip "the default hard thresholds (memory.available<100Mi, ...)" \
  "kind replaces evictionHard (disk thresholds at 0%), and the kubelet does not print its defaults; they come from the kubelet documentation"
skip "the kubelet evicts Pods under memory or disk pressure" "would put a shared node under pressure"

section "Memory/disk pressure delays"
check_output "evictionPressureTransitionPeriod is 5 minutes" '^"5m0s"$' jq -c '.kubeletconfig.evictionPressureTransitionPeriod' <<<"$conf"
tols=$(kubectl -n kube-system get pods -l k8s-app=kube-proxy -o jsonpath='{.items[0].spec.tolerations}')
for t in memory-pressure disk-pressure pid-pressure; do
  assert_match "the pressure taint node.kubernetes.io/$t is NoSchedule (DaemonSet Pods tolerate it)" \
    "\"effect\":\"NoSchedule\",\"key\":\"node.kubernetes.io/$t\"" "$tols"
done

section "PDB - user side"
deploy my-app 3
note_block "$NOTE" 'PDB - user side' 1 >pdb.yaml
check "the note's PDB applies" kubectl apply -f pdb.yaml
check "maxUnavailable: 1 allows 1 disruption out of 3 Pods" allowed my-pdb 1
check_output "both minAvailable and maxUnavailable are refused" 'cannot be both set' \
  bash -c "sed -e 's/#minAvailable: 2/minAvailable: 2/' -e 's/name: my-pdb/name: both/' pdb.yaml | kubectl apply --dry-run=server -f - 2>&1; true"
sed -e 's/^  maxUnavailable: 1/  #maxUnavailable: 1/' -e 's/name: my-pdb/name: neither/' pdb.yaml | kubectl apply -f - >/dev/null
check "neither is accepted, but allows no disruption" allowed neither 0
kubectl delete pdb neither >/dev/null
sed -e 's/^  maxUnavailable: 1/  #maxUnavailable: 1/' -e 's/#minAvailable: 2/minAvailable: 2/' pdb.yaml | kubectl apply -f - >/dev/null
check "minAvailable: 2 allows 1 disruption" allowed my-pdb 1
sed -e 's/^  maxUnavailable: 1/  #maxUnavailable: 1/' -e 's/#minAvailable: 90%/minAvailable: 90%/' pdb.yaml | kubectl apply -f - >/dev/null
check "minAvailable: 90% of 3 rounds up to 3: no disruption" allowed my-pdb 0
sed -e 's/^  maxUnavailable: 1/  #maxUnavailable: 1/' -e 's/#maxUnavailable: 10%/maxUnavailable: 10%/' pdb.yaml | kubectl apply -f - >/dev/null
check "maxUnavailable: 10% of 3 rounds up to 1" allowed my-pdb 1

section "Rounding logic"
pdb my-app '{"maxUnavailable": "50%"}'
kubectl delete pdb my-pdb >/dev/null
check "maxUnavailable: 50% with 3 Pods allows 2" allowed my-app 2
pdb my-app '{"minAvailable": "50%"}'
check "minAvailable: 50% with 3 Pods requires 2, allows 1" allowed my-app 1

section "Unmanaged pods"
for i in 1 2 3; do
  kubectl run "bare-$i" --image="$image" --labels=app=bare --overrides="{\"spec\": {\"nodeSelector\": {\"kubernetes.io/hostname\": \"$node\"}}}" >/dev/null
done
kubectl wait --for=condition=Ready pod -l app=bare --timeout=120s >/dev/null
pdb bare '{"minAvailable": 2}'
check "minAvailable: 2 works with Pods that have no controller" allowed bare 1
pdb bare '{"maxUnavailable": 1}'
check "maxUnavailable does not: no disruption allowed" allowed bare 0
retry 60 bash -c "kubectl describe pdb bare | grep -q UnmanagedPods" || true
check_output "and a warning event, visible with kubectl describe pdb" 'Warning +UnmanagedPods .*set ".spec.minAvailable" field of the PDB to an integer' kubectl describe pdb bare
pdb bare '{"minAvailable": "50%"}'
check "minAvailable as a percentage does not either" allowed bare 0

section "Zero"
pdb my-app '{"maxUnavailable": 0}'
check "maxUnavailable: 0 allows no disruption" allowed my-app 0
check_output "the eviction API refuses to evict" "Cannot evict pod as it would violate the pod's disruption budget" \
  evict_out "$(first my-app)"
pdb my-app '{"minAvailable": 3}'
check "minAvailable equal to the number of Pods: the same" allowed my-app 0
pdb my-app '{"maxUnavailable": 1}'
allowed my-app 1
victim=$(first my-app)
check "when the PDB allows it, the eviction API evicts the Pod" evict "$victim"
check "and the ReplicaSet replaces it" kubectl wait --for=jsonpath='{.status.readyReplicas}'=3 deploy/my-app --timeout=120s

section "PDB - admin side"
check_output "our Pods run on $node" '[1-9]' bash -c "kubectl get pods -l app=my-app --field-selector=spec.nodeName=$node --no-headers | wc -l"
check "kubectl drain, only for our Pods on that node, one at a time (maxUnavailable: 1)" \
  kubectl drain "$node" --pod-selector=app=my-app --ignore-daemonsets --timeout=120s
check_output "it cordoned the node" '^true$' kubectl get node "$node" -o jsonpath='{.spec.unschedulable}'
check "which adds node.kubernetes.io/unschedulable:NoSchedule" retry 20 bash -c \
  "kubectl get node $node -o jsonpath='{.spec.taints[?(@.key==\"node.kubernetes.io/unschedulable\")].effect}' | grep -qx NoSchedule"
check_output "our Pods left the node" '^0$' \
  bash -c "kubectl get pods -l app=my-app --field-selector=spec.nodeName=$node --no-headers | wc -l"
check "and run elsewhere" kubectl wait --for=jsonpath='{.status.readyReplicas}'=3 deploy/my-app --timeout=120s
kubectl uncordon "$node" >/dev/null
# New Pods go back to their preferred node, for the next drain.
kubectl rollout restart deploy/my-app >/dev/null
kubectl rollout status deploy/my-app --timeout=120s >/dev/null
pdb my-app '{"maxUnavailable": 0}'
allowed my-app 0
check_output "with a PDB that forbids it, kubectl drain keeps retrying, then gives up" 'disruption budget' \
  bash -c "kubectl drain $node --pod-selector=app=my-app --ignore-daemonsets --timeout=15s 2>&1; true"
kubectl uncordon "$node" >/dev/null
kubectl delete pdb my-app >/dev/null

section "Theory vs practice"
kubectl create deployment scratch --image="$image" --dry-run=client -o json |
  jq --arg n "$node" '.spec.template.spec.nodeSelector = {"kubernetes.io/hostname": $n}
    | .spec.template.spec.volumes = [{"name": "tmp", "emptyDir": {}}]
    | .spec.template.spec.containers[0].volumeMounts = [{"name": "tmp", "mountPath": "/tmp"}]' |
  kubectl apply -f - >/dev/null
kubectl rollout status deploy/scratch --timeout=120s >/dev/null
# --dry-run=server: the checks run, nothing is cordoned or evicted.
check_output "kubectl drain refuses Pods with emptyDir volumes" 'cannot delete Pods with local storage' \
  bash -c "kubectl drain $node --pod-selector=app=scratch --ignore-daemonsets --dry-run=server 2>&1; true"
check_output "unless --delete-emptydir-data is given" "evicting pod $TEST_NS/scratch-" \
  kubectl drain "$node" --pod-selector=app=scratch --ignore-daemonsets --delete-emptydir-data --dry-run=server
check_output "and the dry run left the node schedulable" '^$' kubectl get node "$node" -o jsonpath='{.spec.unschedulable}'

section "Unhealthy pod eviction policy"
kubectl create deployment sick --image="$image" --dry-run=client -o json |
  jq '.spec.template.spec.containers[0].readinessProbe = {"exec": {"command": ["/false"]}, "periodSeconds": 2}' |
  kubectl apply -f - >/dev/null
retry 60 bash -c '[ "$(kubectl get pods -l app=sick --field-selector=status.phase=Running --no-headers | wc -l)" = 1 ]'
check_output "the Pod runs, but is not ready" '^False$' \
  kubectl get pod "$(first sick)" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
pdb sick '{"minAvailable": 1}'
allowed sick 0
check_output "by default, the PDB protects an unhealthy Pod" 'disruption budget' evict_out "$(first sick)"
note_block "$NOTE" 'Unhealthy pod eviction policy' 1 >policy.yaml
check "the note's unhealthyPodEvictionPolicy: AlwaysAllow" \
  kubectl patch pdb sick --type=merge --patch-file policy.yaml
check_output "it is set" '^AlwaysAllow$' kubectl get pdb sick -o jsonpath='{.spec.unhealthyPodEvictionPolicy}'
allowed sick 0
check "then the unhealthy Pod can be evicted" evict "$(first sick)"

section "Manual rescheduling"
check "the eviction API moves a Pod: a new one is created" \
  kubectl wait --for=jsonpath='{.status.replicas}'=1 deploy/sick --timeout=60s
