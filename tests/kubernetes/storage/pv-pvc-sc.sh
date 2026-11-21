#!/usr/bin/env bash
# note: kubernetes/storage/pv-pvc-sc.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/storage/pv-pvc-sc
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
use_test_namespace
HOME=$(mktemp -d)
export HOME
cd "$HOME"
mkdir -p container.training/k8s
for f in pvc pv mounter; do curl -fsSL "$UPSTREAM/k8s/$f.yaml" >"container.training/k8s/$f.yaml"; done
# PVs are cluster-wide: ours carry a label naming this run.
cleanup() {
  kubectl delete pod --all --wait=false >/dev/null 2>&1 || true
  kubectl delete pvc --all --wait=false >/dev/null 2>&1 || true
  kubectl delete pv -l "notes-test=$TEST_NS" --wait=false >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
run() { bash -ec "$1" 2>&1; }
pvc_name() { kubectl get pvc -l container.training/pvc -o jsonpath='{.items[0].metadata.name}'; }
phase() { kubectl get "$1" -o jsonpath='{.status.phase}'; }
# mounter CLAIM: the note's mounter Pod, with claimName updated as the note says; prints the Pod name.
mounter() { sed "s/my-pvc-XYZ45/$1/" container.training/k8s/mounter.yaml | kubectl create -f - -o name; }
# label_pv: label the PVs the note's commands just made, so cleanup finds them.
label_pv() { kubectl label pv -l 'container.training/pv,!notes-test' "notes-test=$TEST_NS" >/dev/null; }

section "Creating a PVC"
check_output "kind has a default StorageClass that waits for first consumer" \
  'standard \(default\) +rancher.io/local-path +Delete +WaitForFirstConsumer' run "$(note_block "$NOTE" 2)"
check_output "it is marked by the annotation the note gives" '^true$' \
  kubectl get storageclass standard -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}'
check "create the PVC (from the note)" run "$(note_block "$NOTE" 3)"
check_output "possibility 2: Pending, but with a STORAGECLASS (from the note)" '^my-pvc-\S+ +Pending +standard' \
  run "$(note_block "$NOTE" 4) --no-headers -o custom-columns=N:.metadata.name,S:.status.phase,C:.spec.storageClassName"
check_output "the default class was written into the PVC" '^standard$' \
  kubectl get pvc "$(pvc_name)" -o jsonpath='{.spec.storageClassName}'

section "Using the PVC (scenario 2)"
assert_eq "the inline mounter is the upstream file" "$(cat container.training/k8s/mounter.yaml)" "$(note_block "$NOTE" 5)"
CLAIM=$(pvc_name)
POD=$(mounter "$CLAIM")
check "the Pod runs" kubectl wait --for=condition=Ready "$POD" --timeout=180s
check_output "a new PV was created, and the PVC is Bound" '^Bound$' phase "pvc/$CLAIM"
PV=$(kubectl get pvc "$CLAIM" -o jsonpath='{.spec.volumeName}')
check_output "(the PV too)" '^Bound$' phase "pv/$PV"
check "nothing prevents the Pod from using more than the 1G request" \
  kubectl exec "${POD#pod/}" -- sh -c 'dd if=/dev/zero of=big bs=1M count=1100 2>/dev/null && rm big'

section "PV and PVC lifecycle"
kubectl delete pvc "$CLAIM" --wait=false >/dev/null
check_output "a PVC in use goes to Terminating instead of being deleted" 'Terminating' \
  bash -c "kubectl get pvc $CLAIM --no-headers | awk '{print \$2}'"
check_output "a finalizer prevents the deletion" 'kubernetes.io/pvc-protection' \
  kubectl get pvc "$CLAIM" -o jsonpath='{.metadata.finalizers}'
kubectl delete "$POD" --wait=true >/dev/null
check "when the Pod is deleted, the PVC goes" kubectl wait --for=delete "pvc/$CLAIM" --timeout=120s
check "and its PV (reclaim policy Delete)" kubectl wait --for=delete "pv/$PV" --timeout=120s

section "Scenario 3: no StorageClass, a PV made by hand"
# No default class here: a PVC with storageClassName "" behaves the same way.
sed 's/^  #storageClassName: my-sc$/  storageClassName: ""/' container.training/k8s/pvc.yaml | kubectl create -f - >/dev/null
CLAIM=$(pvc_name)
check_output "possibility 3: Pending, without a STORAGECLASS" '^Pending $' \
  bash -c "echo \"\$(kubectl get pvc $CLAIM -o jsonpath='{.status.phase} {.spec.storageClassName}')\""
check "create the PV (from the note)" run "$(note_block "$NOTE" 6)"
label_pv
retry 60 bash -c "[ \"\$(kubectl get pvc $CLAIM -o jsonpath={.status.phase})\" = Bound ]"
check_output "after a few seconds, PV and PVC are Bound (from the note)" "persistentvolumeclaim/$CLAIM +Bound" \
  run "$(note_block "$NOTE" 7)"
PV=$(kubectl get pvc "$CLAIM" -o jsonpath='{.spec.volumeName}')
kubectl delete pv "$PV" --wait=false >/dev/null
check_output "a Bound PV can't be deleted: it is Terminating, held by a finalizer" 'kubernetes.io/pv-protection' \
  kubectl get pv "$PV" -o jsonpath='{.metadata.finalizers}'
kubectl delete pvc "$CLAIM" >/dev/null
check "once its PVC is deleted, the PV goes" kubectl wait --for=delete "pv/$PV" --timeout=120s

section "Scenario 4: a StorageClass that doesn't work"
sed 's/^  #storageClassName: my-sc$/  storageClassName: notes-broken/' container.training/k8s/pvc.yaml | kubectl create -f - >/dev/null
CLAIM=$(pvc_name)
sleep 5
check_output "possibility 4: Pending, with a STORAGECLASS" '^Pending notes-broken$' \
  kubectl get pvc "$CLAIM" -o jsonpath='{.status.phase} {.spec.storageClassName}'
check "the note's patch creates a PV with that class" run "$(note_block "$NOTE" 8)"
label_pv
retry 60 bash -c "[ \"\$(kubectl get pvc $CLAIM -o jsonpath={.status.phase})\" = Bound ]"
check_output "PV and PVC are Bound (from the note)" "persistentvolumeclaim/$CLAIM +Bound .*notes-broken" \
  run "$(note_block "$NOTE" 9)"
kubectl delete pvc "$CLAIM" >/dev/null

section "Access modes"
sed 's/^  - ReadWriteOnce$//; s/^  #storageClassName: my-sc$/  storageClassName: notes-rwx/' container.training/k8s/pv.yaml \
  | kubectl create -f - >/dev/null
label_pv
sed 's/^  #storageClassName: my-sc$/  storageClassName: notes-rwx/' container.training/k8s/pvc.yaml | kubectl create -f - >/dev/null
CLAIM=$(pvc_name)
sleep 15
check_output "a PV with only ReadWriteMany does not satisfy a ReadWriteOnce PVC" '^Pending$' phase "pvc/$CLAIM"
