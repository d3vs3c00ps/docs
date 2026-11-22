#!/usr/bin/env bash
# note: kubernetes/observability/resource-limits.md
# env: kind
# timeout: 900
# Mostly a concept note: its manifests run, and its claims about defaults, QoS,
# LimitRange, ResourceQuota and in-place resize are checked against the API.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/observability/resource-limits
cd "$(mktemp -d)"
cleanup() {
  kubectl delete priorityclass notes-high --ignore-not-found >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
run() { bash -ec "$1" 2>&1; }
# pod NAME RESOURCES_JSON: a dry-run Pod with these container resources, as the API stores it.
pod() {
  kubectl run "$1" --image=busybox:1.37 --dry-run=server -o json \
    --overrides="{\"spec\":{\"containers\":[{\"name\":\"$1\",\"image\":\"busybox:1.37\",\"resources\":$2}]}}"
}
qos() { pod "$@" | jq -r .status.qosClass; }
# applyblk HEADING: apply the first block under HEADING.
applyblk() { note_block "$NOTE" "$1" 1 | kubectl apply -f - 2>&1; }
# dedent TEXT: remove the smallest leading indentation of the non-empty lines.
dedent() { printf '%s\n' "$1" | awk '{l[NR]=$0} NF{match($0,/^ */); if(m==""||RLENGTH<m)m=RLENGTH} END{for(i=1;i<=NR;i++)print substr(l[i],m+1)}'; }

section "Pod quality of service"
check_output "limits = requests for CPU and memory: Guaranteed" '^Guaranteed$' \
  qos g '{"limits":{"cpu":"100m","memory":"64Mi"},"requests":{"cpu":"100m","memory":"64Mi"}}'
check_output "requests < limits: Burstable" '^Burstable$' \
  qos b '{"limits":{"cpu":"100m","memory":"64Mi"},"requests":{"cpu":"10m","memory":"64Mi"}}'
check_output "no request nor limit: BestEffort" '^BestEffort$' qos e '{}'
check_output "(Guaranteed needs both CPU and memory: CPU alone is Burstable)" '^Burstable$' \
  qos c '{"limits":{"cpu":"100m"},"requests":{"cpu":"100m"}}'

section "Specifying resources in practice"
spec=$(dedent "$(note_block "$NOTE" 'Specifying resources in practice' 1)")
printf 'apiVersion: v1\nkind: Pod\nmetadata: {name: blue}\nspec:\n%s\n' "$(printf '%s\n' "$spec" | sed 's/^/  /')" >blue.yaml
check "the note's container spec runs" kubectl apply -f blue.yaml
kubectl wait --for=condition=Ready pod/blue --timeout=120s >/dev/null
check_output "it is Burstable (CPU request < limit)" '^Burstable$' kubectl get pod blue -o jsonpath='{.status.qosClass}'
check_output "100m = 0.1: the quantity is kept as written" '^100m$' kubectl get pod blue -o jsonpath='{.spec.containers[0].resources.limits.cpu}'

section "Default values"
check_output "a limit without a request: the request is set to the limit" '^100m 64Mi$' bash -c \
  "kubectl run l --image=busybox:1.37 --dry-run=server -o json --overrides='{\"spec\":{\"containers\":[{\"name\":\"l\",\"image\":\"busybox:1.37\",\"resources\":{\"limits\":{\"cpu\":\"100m\",\"memory\":\"64Mi\"}}}]}}' | jq -r '.spec.containers[0].resources.requests | \"\\(.cpu) \\(.memory)\"'"
check_output "a request without a limit: no limit" '^null$' bash -c \
  "kubectl run r --image=busybox:1.37 --dry-run=server -o json --overrides='{\"spec\":{\"containers\":[{\"name\":\"r\",\"image\":\"busybox:1.37\",\"resources\":{\"requests\":{\"cpu\":\"100m\"}}}]}}' | jq -c '.spec.containers[0].resources.limits'"

section "LimitRange example"
check "the note's LimitRange" applyblk 'LimitRange example'
check_output "a Pod with no resources gets the defaults" '"limits":\{"cpu":"500m","memory":"250Mi"\},"requests":\{"cpu":"500m","memory":"250Mi"\}' \
  bash -c "kubectl run d --image=busybox:1.37 --dry-run=server -o jsonpath='{.spec.containers[0].resources}'"
check_output "(the memory request comes from the default limit)" '"memory":"250Mi"' \
  bash -c "kubectl run d --image=busybox:1.37 --dry-run=server -o jsonpath='{.spec.containers[0].resources.requests}'"
check_output "below min: refused" 'minimum cpu usage per Container is 100m' bash -c \
  "kubectl run m --image=busybox:1.37 --dry-run=server --overrides='{\"spec\":{\"containers\":[{\"name\":\"m\",\"image\":\"busybox:1.37\",\"resources\":{\"requests\":{\"cpu\":\"50m\"}}}]}}' 2>&1; true"

section "LimitRange details"
check "applies only on creation: an existing Pod is not affected" kubectl get pod blue
check "an invalid Deployment is still created" kubectl create deployment toosmall --image=busybox:1.37 -- sleep 3600
kubectl set resources deployment toosmall --requests=cpu=10m >/dev/null
retry 60 bash -c "kubectl get events --field-selector reason=FailedCreate -o jsonpath='{.items[*].message}' | grep -q 'minimum cpu'"
check_output "but its Pods are refused (from the note)" 'minimum cpu usage per Container is 100m' bash -c \
  "kubectl get events --field-selector reason=FailedCreate -o jsonpath='{.items[*].message}'"
kubectl delete deployment toosmall >/dev/null
kubectl delete limitrange my-very-detailed-limitrange >/dev/null
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: LimitRange
metadata: {name: maxonly}
spec:
  limits:
  - type: Container
    max: {memory: 300Mi}
EOF
check_output "a max without a default becomes the default limit (from the note)" '^300Mi$' \
  bash -c "kubectl run x --image=busybox:1.37 --dry-run=server -o jsonpath='{.spec.containers[0].resources.limits.memory}'"
kubectl delete limitrange maxonly >/dev/null
check "type: Pod exists now (the note said 'not documented yet')" bash -c \
  "printf 'apiVersion: v1\nkind: LimitRange\nmetadata: {name: perpod}\nspec:\n  limits:\n  - {type: Pod, max: {cpu: 200m}}\n' | kubectl apply -f -"
check_output "and caps the sum of the Pod's containers" 'maximum cpu usage per Pod is 200m' bash -c \
  "printf 'apiVersion: v1\nkind: Pod\nmetadata: {name: two}\nspec:\n  containers:\n  - {name: a, image: busybox:1.37, resources: {limits: {cpu: 150m}}}\n  - {name: b, image: busybox:1.37, resources: {limits: {cpu: 150m}}}\n' | kubectl create --dry-run=server -f - 2>&1; true"
kubectl delete limitrange perpod >/dev/null

section "Namespace quotas"
check "the compute quota (from the note)" applyblk 'Limiting total CPU/memory usage'
check "the objects quota (from the note)" applyblk 'Limiting number of objects'
check_output "services.nodeports: 0 refuses a NodePort Service" 'exceeded quota: quota-for-objects' bash -c \
  "kubectl create service nodeport np --tcp=80 2>&1; true"
check_output "with a limits quota, a Pod without limits is refused" 'must specify limits.cpu' bash -c \
  "kubectl run nolimits --image=busybox:1.37 2>&1; true"
kubectl delete resourcequota a-little-bit-of-compute quota-for-objects >/dev/null
check "kubectl create quota (from the note)" run "$(note_block "$NOTE" 'YAML vs CLI' 1)"
check_output "the values are under hard" '^\{"limits.memory":"300Gi","pods":"300"\}$' \
  kubectl get resourcequota my-resource-quota -o jsonpath='{.spec.hard}'
retry 30 bash -c "kubectl describe resourcequota my-resource-quota | grep -q '^pods'"
check_output "describe shows Used and Hard (from the note)" '^Resource +Used +Hard' bash -c \
  "kubectl describe resourcequota my-resource-quota | grep '^Resource'"
check_output "(pods: the Pods in the namespace are counted)" '^pods +[0-9]+ +300' bash -c "kubectl describe resourcequota my-resource-quota | grep '^pods'"
kubectl delete resourcequota my-resource-quota >/dev/null

section "PriorityClass"
check "a PriorityClass of 1000000000 is the highest user value" kubectl create priorityclass notes-high --value=1000000000
check_output "above that is reserved for system classes" 'maximum allowed value of a user defined priority is 1000000000' bash -c \
  "kubectl create priorityclass notes-too-high --value=1000000001 --dry-run=server 2>&1; true"
check_output "(system-node-critical is higher)" '^2000001000$' kubectl get priorityclass system-node-critical -o jsonpath='{.value}'
check "negative values are allowed too" kubectl create priorityclass notes-low --value=-10 --dry-run=server
check_output "no priorityClassName and no globalDefault: priority 0" '^0$' kubectl get pod blue -o jsonpath='{.spec.priority}'

section "In-place Pod resize"
check "resize the CPU of a running Pod (the resize subresource)" kubectl patch pod blue --subresource resize \
  --patch '{"spec":{"containers":[{"name":"blue","resources":{"limits":{"cpu":"200m"}}}]}}'
check_output "(applied without a restart)" '^200m 0$' bash -c \
  "sleep 5; kubectl get pod blue -o jsonpath='{.spec.containers[0].resources.limits.cpu} {.status.containerStatuses[0].restartCount}'"
check_output "cannot change the QoS class: removing the requests is refused" 'Pod QOS Class may not change as a result of resizing' bash -c \
  "kubectl patch pod blue --subresource resize --patch '{\"spec\":{\"containers\":[{\"name\":\"blue\",\"resources\":{\"requests\":{\"cpu\":\"200m\",\"memory\":\"100Mi\"},\"limits\":{\"cpu\":\"200m\",\"memory\":\"100Mi\"}}}]}}' 2>&1; true"

section "Viewing a namespace limits and quotas"
check_output "kubectl describe namespace (from the note)" '^Name: +default' run "$(note_block "$NOTE" 'Viewing a namespace' 1)"
check_output "it lists every namespace without a name (from the note)" "^Name: +$TEST_NS" bash -c \
  "$(note_block "$NOTE" 'Viewing a namespace' 2) | grep '^Name:'"
