#!/usr/bin/env bash
# note: kubernetes/storage/openebs.md
# env: kind
# timeout: 1500
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/storage/openebs
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
HOME=$(mktemp -d)
export HOME
cd "$HOME"
mkdir -p container.training/k8s
curl -fsSL "$UPSTREAM/k8s/openebs-pod.yaml" >container.training/k8s/openebs-pod.yaml
# The lab changes the cluster's default StorageClass: own cluster.
C=notes-openebs
kind_cluster "$C"
printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes: [{role: control-plane}, {role: worker}, {role: worker}]\n' >kind.yaml
out=$(kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" --config kind.yaml 2>&1) || { echo "$out"; kind_diag; exit 1; }
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
run() { bash -ec "$1" 2>&1; }

section "Installing OpenEBS with Helm"
assert_match "the note pins the chart version the tests use" "--version $OPENEBS_CHART" "$(note_block "$NOTE" 2)"
check "the note's helm command" run "$(note_block "$NOTE" 2)"
check "the Local PV provisioner runs" kubectl -n openebs rollout status deploy/openebs-localpv-provisioner --timeout=300s

section "Checking what was installed"
check_output "only the Local PV Hostpath provisioner (from the note)" '^openebs-localpv-provisioner-\S+ +1/1 +Running' \
  run "$(note_block "$NOTE" 3) --no-headers"
check_output "and the openebs-hostpath class, WaitForFirstConsumer (from the note)" \
  '^openebs-hostpath +openebs.io/local +Delete +WaitForFirstConsumer' run "$(note_block "$NOTE" 4)"
check_output "no Jiva class in OpenEBS 4 (the note)" '^$' bash -c 'kubectl get sc -o name | grep jiva || true'

section "The default hostpath StorageClass"
check_output "volumes go to /var/openebs/local (from the note)" 'value: "/var/openebs/local"' \
  run "$(note_block "$NOTE" 6)"
check_output "the cas-type annotation chooses the engine" 'openebs.io/cas-type: local' run "$(note_block "$NOTE" 6)"

section "Defining a custom StorageClass"
# The correction: without volumeBindingMode, the class is Immediate, and provisioning fails.
note_block "$NOTE" 5 | sed '/^volumeBindingMode:/d; s/name: localpv-hostpath-mntvol001/name: notes-immediate/' | kubectl apply -f - >/dev/null
printf 'apiVersion: v1\nkind: PersistentVolumeClaim\nmetadata: {name: immediate-pvc}\nspec: {storageClassName: notes-immediate, accessModes: [ReadWriteOnce], resources: {requests: {storage: 1G}}}\n' | kubectl apply -f - >/dev/null
retry 60 bash -c "kubectl describe pvc immediate-pvc | grep -q 'no node was specified'" || true
check_output "without volumeBindingMode: no node was specified (the correction)" 'no node was specified' \
  kubectl describe pvc immediate-pvc
kubectl delete pvc immediate-pvc --wait=false >/dev/null
check "the note's custom class (BasePath /mnt/vol001)" bash -c "$(printf 'kubectl apply -f - <<EOF\n%s\nEOF' "$(note_block "$NOTE" 5)")"
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: custom-pvc}
spec:
  storageClassName: localpv-hostpath-mntvol001
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1G}}
---
apiVersion: v1
kind: Pod
metadata: {name: custom-pod}
spec:
  volumes: [{name: v, persistentVolumeClaim: {claimName: custom-pvc}}]
  containers:
  - {name: c, image: alpine, command: [sh, -c, 'echo custom >/v/f; sleep 3600'], volumeMounts: [{name: v, mountPath: /v}]}
EOF
if ! kubectl wait --for=condition=Ready pod/custom-pod --timeout=180s >/dev/null; then
  kubectl describe pvc custom-pvc | sed -n '/^Events:/,$p' | sed 's/^/# /'
  kubectl -n openebs logs deploy/openebs-localpv-provisioner --tail=20 | sed 's/^/# /'
fi
N=$(kubectl get pod custom-pod -o jsonpath='{.spec.nodeName}')
check_output "the volume is under /mnt/vol001 on the node" 'custom' bash -c "docker exec $N sh -c 'cat /mnt/vol001/pvc-*/f'"
kubectl delete pod custom-pod --wait=false >/dev/null

section "Create a host path PVC"
check "the note's PVC" run "$(note_block "$NOTE" 7)"
sleep 5
check_output "no PV yet (from the note): the PVC is Pending" 'persistentvolumeclaim/local-hostpath-pvc +Pending' \
  run "$(note_block "$NOTE" 8)"

section "Create a Pod to consume the PV"
check "create the Pod (from the note)" run "$(note_block "$NOTE" 9)"
while read -r l; do
  [[ -z $l || $l == ... ]] && continue
  assert_match "the excerpt matches openebs-pod.yaml: $l" "$(printf '%s' "$l" | sed 's/[][\.*^$/]/\\&/g')" \
    "$(cat container.training/k8s/openebs-pod.yaml)"
done <<<"$(note_block "$NOTE" 10)"
kubectl wait --for=condition=Ready pod/openebs-local-hostpath-pod --timeout=300s >/dev/null
check_output "now a PV exists, Bound (from the note)" 'persistentvolumeclaim/local-hostpath-pvc +Bound' \
  run "$(note_block "$NOTE" 11)"

section "Verify that data is written on the node"
N=$(run "$(note_block "$NOTE" 12)")
check_output "the worker node (from the note)" "^$C-worker2?\$" echo "$N"
retry 30 bash -c "docker exec $N sh -c 'cat /var/openebs/local/pvc-*/greet.txt' | grep -q better"
check_output "the file is on the node (the note's tail, without sudo)" 'Kubernetes is better with PVs' \
  docker exec "$N" sh -c "$(note_block "$NOTE" 13 | sed 's/^ *sudo //')"

section "Setting a default StorageClass"
check_output "kind's own default class (from the note)" 'standard \(default\)' run "$(note_block "$NOTE" 14)"
check "remove the default annotation everywhere (from the note)" run "$(note_block "$NOTE" 15)"
check "annotate openebs-hostpath (from the note)" run "$(note_block "$NOTE" 16)"
check_output "it is the default now (from the note)" '^openebs-hostpath \(default\)' run "$(note_block "$NOTE" 17)"
check_output "(and only it)" '^1$' bash -c "kubectl get sc --no-headers | grep -c '(default)'"
