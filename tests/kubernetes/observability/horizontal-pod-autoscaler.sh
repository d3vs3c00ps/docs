#!/usr/bin/env bash
# note: kubernetes/observability/horizontal-pod-autoscaler.md
# env: kind
# timeout: 1500
# watch/httping are interactive: skipped. ab runs in a pod (ClusterIPs answer only in the cluster).
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/observability/horizontal-pod-autoscaler
cd "$(mktemp -d)"
# Own cluster with metrics-server, installed as in kubernetes/observability/metrics-server.
C=notes-hpa
kind_cluster "$C"
kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" >/dev/null 2>&1
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
run() { bash -ec "$1" 2>&1; }
check "metrics-server, installed as in its note" run "$(note_block kubernetes/observability/metrics-server 2) --wait --timeout 5m"
retry 120 bash -c "kubectl top nodes >/dev/null 2>&1"

section "A CPU-intensive web service"
check "kubectl create deployment busyhttp (from the note)" run "$(note_block "$NOTE" 1)"
check "kubectl expose (from the note)" run "$(note_block "$NOTE" 2)"
check_output "kubectl get svc busyhttp (from the note)" '^busyhttp +ClusterIP' run "$(note_block "$NOTE" 3)"
CLUSTERIP=$(bash -c "$(note_block "$NOTE" 4); echo \$CLUSTERIP")
check_output "the CLUSTERIP line (from the note)" '^10\.' echo "$CLUSTERIP"
kubectl rollout status deploy/busyhttp --timeout=180s >/dev/null

section "Send traffic to the service"
ab=$(note_block "$NOTE" 8 | sed "s/\$CLUSTERIP/$CLUSTERIP/")
# ab stops when the patch below replaces the pod; the note says to restart it.
kubectl run ab --restart=Never --image=httpd:2.4-alpine -- sh -c "while :; do $ab; sleep 1; done" >/dev/null
if ! retry 300 bash -c "kubectl top pods -l app=busyhttp --no-headers 2>/dev/null | awk '{sub(\"m\",\"\",\$2); if (\$2 >= 800) ok=1} END{exit !ok}'"; then
  { kubectl top pods -A; kubectl get pods -o wide; kubectl logs ab --tail=5; } 2>&1 | sed 's/^/# /'
fi
check_output "the CPU use goes to about one core, single-threaded (from the note)" '^busyhttp-\S+ +(8|9)[0-9]{2}m|^busyhttp-\S+ +1[0-9]{3}m' \
  kubectl top pods -l app=busyhttp --no-headers

section "Create an HPA policy"
check "kubectl autoscale --max=10 (from the note)" run "$(note_block "$NOTE" 9)"
check_output "a CPU target of 80% by default (from the note)" '"averageUtilization":80' \
  kubectl get hpa.v2.autoscaling busyhttp -o jsonpath='{.spec.metrics}'
retry 120 bash -c "kubectl get events --field-selector involvedObject.kind=HorizontalPodAutoscaler -o jsonpath='{.items[*].message}' | grep -q 'missing request for cpu'"
check_output "the HPA does not work: 'missing request for cpu' (from the note)" 'missing request for cpu' \
  kubectl get events --field-selector involvedObject.kind=HorizontalPodAutoscaler -o jsonpath='{.items[*].message}'
check_output "(no scaling)" '^1$' kubectl get deploy busyhttp -o jsonpath='{.spec.replicas}'

section "Adding a CPU request"
# The note's block, added to the container with a strategic merge patch instead of kubectl edit.
# The block is indented for its place under "- name:"; remove its own indent, then re-indent.
blk=$(note_block "$NOTE" 11)
ind=$(grep -o '^ *' <<<"$blk" | head -1)
patch=$(printf 'spec:\n  template:\n    spec:\n      containers:\n      - name: busyhttp\n%s\n' "$(sed "s/^$ind//; s/^/        /" <<<"$blk")")
check "add the note's resources block" kubectl patch deployment busyhttp --patch "$patch"
check_output "(a CPU request of 1)" '^1$' kubectl get deploy busyhttp -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}'
check "the HPA scales the deployment up (it 'kicks in' within a few minutes)" retry 300 bash -c \
  "[ \"\$(kubectl get hpa busyhttp -o jsonpath='{.status.desiredReplicas}')\" -ge 2 ]"
check_output "(and says why)" 'New size: [0-9]+; reason: cpu resource utilization \(percentage of request\) above target' \
  kubectl get events --field-selector reason=SuccessfulRescale -o jsonpath='{.items[*].message}'

section "Timing: the defaults behind the correction"
# The API fills in behavior defaults only when the field is present: ask with an empty one.
b=$(printf 'apiVersion: autoscaling/v2\nkind: HorizontalPodAutoscaler\nmetadata: {name: t}\nspec:\n  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: busyhttp}\n  maxReplicas: 5\n  behavior: {scaleUp: {}, scaleDown: {}}\n' |
  kubectl create --dry-run=server -f - -o jsonpath='{.spec.behavior}')
assert_match "scale up: no stabilization window" '"scaleUp":\{.*"stabilizationWindowSeconds":0' "$b"
assert_no_match "scale down: no window in the object..." '"scaleDown":\{[^}]*"stabilizationWindowSeconds"' "$b"
check_output "...so the controller's default applies: 5 minutes" 'horizontal-pod-autoscaler-downscale-stabilization duration +.*\(default 5m0s\)' bash -c \
  "kubectl -n kube-system exec kube-controller-manager-$C-control-plane -- kube-controller-manager --help 2>&1 | grep -A1 -- '--horizontal-pod-autoscaler-downscale-stabilization' | tr -s ' \n' ' '"
check_output "(kind does not change it)" '^$' bash -c \
  "kubectl -n kube-system get pod kube-controller-manager-$C-control-plane -o jsonpath='{.spec.containers[0].command}' | grep -o 'downscale-stabilization' || true"
check_output "and the HPA sync period is 15 s by default (the correction)" 'horizontal-pod-autoscaler-sync-period duration +.*\(default 15s\)' bash -c \
  "kubectl -n kube-system exec kube-controller-manager-$C-control-plane -- kube-controller-manager --help 2>&1 | grep -A1 -- '--horizontal-pod-autoscaler-sync-period' | tr -s ' \n' ' '"
check "autoscaling/v2beta2 is gone (the correction)" bash -c "! kubectl api-versions | grep -qx autoscaling/v2beta2"
check_output "autoscaling/v2 is served" '^autoscaling/v2$' bash -c "kubectl api-versions | grep -x autoscaling/v2"

section "Cleanup"
kubectl delete pod ab --wait=false >/dev/null
check "delete the deployment, service and HPA (from the note)" run "$(note_block "$NOTE" 12)"
check_output "nothing left" '^$' bash -c "kubectl get deploy,svc,hpa -o name | grep busyhttp || true"
