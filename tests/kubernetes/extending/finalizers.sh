#!/usr/bin/env bash
# note: kubernetes/extending/finalizers.md
# env: kind
# timeout: 600
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

GHOST=notes-ghost-$RANDOM
PV=notes-pv-$TEST_NS
cleanup() {
  kubectl -n "$GHOST" patch configmap precious --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  kubectl delete namespace "$GHOST" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete pv "$PV" --ignore-not-found --wait=false >/dev/null 2>&1
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
dts() { kubectl get "$@" -o jsonpath='{.metadata.deletionTimestamp}'; }

section "How do they work?"
kubectl create configmap precious --from-literal=data=1 >/dev/null
kubectl patch configmap precious --type=merge -p '{"metadata":{"finalizers":["example.com/hold"]}}' >/dev/null
check "delete a resource that has a finalizer: the call returns" kubectl delete configmap precious --wait=false
check_output "the resource is not deleted; its deletionTimestamp is set (from the note)" '^20[0-9]{2}-' dts configmap precious
check "until then, it can be used normally (from the note)" kubectl patch configmap precious --type=merge -p '{"data":{"data":"2"}}'
check_output "but no further finalizer can be added (from the note)" 'no new finalizers can be added if the object is being deleted' \
  bash -c "kubectl patch configmap precious --type=json -p '[{\"op\":\"add\",\"path\":\"/metadata/finalizers/-\",\"value\":\"example.com/more\"}]' 2>&1; true"
check "removing the finalizer..." kubectl patch configmap precious --type=merge -p '{"metadata":{"finalizers":null}}'
check_output "...deletes the resource (from the note)" 'NotFound' bash -c "kubectl get configmap precious 2>&1; true"

section "Volume finalizer"
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: my-pvc}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Mi}}
---
apiVersion: v1
kind: PersistentVolume
metadata: {name: $PV}
spec:
  capacity: {storage: 1Mi}
  accessModes: [ReadWriteOnce]
  storageClassName: manual
  hostPath: {path: /tmp/$PV}
EOF
check_output "PVCs get kubernetes.io/pvc-protection, even when not in use (from the note)" '^\["kubernetes.io/pvc-protection"\]$' \
  kubectl get pvc my-pvc -o jsonpath='{.metadata.finalizers}'
check_output "PVs get kubernetes.io/pv-protection, even when not bound (from the note)" '^\["kubernetes.io/pv-protection"\]$' \
  kubectl get pv "$PV" -o jsonpath='{.metadata.finalizers}'
kubectl run user --image=busybox:1.37 --overrides='{"spec":{"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"my-pvc"}}],"containers":[{"name":"user","image":"busybox:1.37","command":["sleep","3600"],"volumeMounts":[{"name":"v","mountPath":"/v"}]}]}}' >/dev/null
kubectl wait --for=condition=Ready pod/user --timeout=180s >/dev/null
kubectl delete pvc my-pvc --wait=false >/dev/null
sleep 5
check_output "a PVC used by a Pod is only marked for deletion (from the note)" '^20[0-9]{2}-' dts pvc my-pvc
check_output "(its status is Terminating)" 'Terminating' kubectl get pvc my-pvc
kubectl delete pod user --wait=true >/dev/null
check "once the Pod is gone, the controller removes the finalizer and the PVC goes" \
  kubectl wait --for=delete pvc/my-pvc --timeout=120s

section "Namespace finalizer"
kubectl create namespace "$GHOST" >/dev/null
check_output "namespaces have the kubernetes finalizer (from the note)" '^\["kubernetes"\]$' \
  kubectl get namespace "$GHOST" -o jsonpath='{.spec.finalizers}'
kubectl -n "$GHOST" create configmap precious --from-literal=data=1 >/dev/null
kubectl -n "$GHOST" patch configmap precious --type=merge -p '{"metadata":{"finalizers":["example.com/hold"]}}' >/dev/null
kubectl delete namespace "$GHOST" --wait=false >/dev/null
sleep 10
check_output "a namespace with an object that cannot go stays Terminating" '^Terminating$' \
  kubectl get namespace "$GHOST" -o jsonpath='{.status.phase}'
check "remove the finalizer: the finalize subresource" bash -c \
  "kubectl get namespace $GHOST -o json | jq '.spec.finalizers=[]' | kubectl replace --raw /api/v1/namespaces/$GHOST/finalize -f - >/dev/null"
check "it seems to work: the namespace is gone (from the note)" kubectl wait --for=delete namespace/"$GHOST" --timeout=60s
kubectl create namespace "$GHOST" >/dev/null
check_output "but the object still existed, and re-appears with the namespace (from the note)" '^precious$' \
  kubectl -n "$GHOST" get configmap precious -o jsonpath='{.metadata.name}'
check_output "(still marked for deletion)" '^20[0-9]{2}-' dts -n "$GHOST" configmap precious
