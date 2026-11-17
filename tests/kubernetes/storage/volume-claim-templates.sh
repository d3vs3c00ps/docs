#!/usr/bin/env bash
# note: kubernetes/storage/volume-claim-templates.md
# env: kind
# timeout: 2400
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/storage/volume-claim-templates
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
HOME=$(mktemp -d)
export HOME
cd "$HOME"
mkdir -p container.training/k8s
for f in consul-3 volumes-for-consul; do curl -fsSL "$UPSTREAM/k8s/$f.yaml" >"container.training/k8s/$f.yaml"; done
# Anti-affinity needs 3 nodes that take pods, and the "no dynamic provisioner" case
# changes the default StorageClass: own cluster, 3 workers.
C=notes-vct
kind_cluster "$C"
printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes: [{role: control-plane}, {role: worker}, {role: worker}, {role: worker}]\n' >kind.yaml
kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" --config kind.yaml >/dev/null 2>&1
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
run() { bash -ec "$1" 2>&1; }
retry_get() {
  local i
  for i in $(seq 1 90); do kubectl exec consul-0 -- consul kv get answer 2>/dev/null && return 0; sleep 2; done
  kubectl exec consul-0 -- consul kv get answer
}
# retry_owner: the owner kind of data-consul-0, once the controller has set it.
retry_owner() {
  local i o
  for i in $(seq 1 60); do
    o=$(kubectl get pvc data-consul-0 -o jsonpath='{.metadata.ownerReferences[*].kind}')
    [[ -n $o ]] && { echo "$o"; return 0; }
    sleep 1
  done
  return 1
}
workers=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}')
read -r W1 W2 W3 <<<"$workers"

section "No dynamic provisioner"
# Make kind's provisioner a non-default class, as if there were none.
kubectl annotate storageclass standard storageclass.kubernetes.io/is-default-class=false --overwrite >/dev/null
check "apply consul-3.yaml (from the note)" run "$(note_block "$NOTE" 2)"
sleep 10
check_output "an unbound PVC, data-consul-0 (from the note)" '^data-consul-0 +Pending' run "$(note_block "$NOTE" 3) --no-headers"
check_output "only one: consul-1 is not created before consul-0 runs" '^1$' bash -c 'kubectl get pvc --no-headers | wc -l'
check_output "no Persistent Volume (from the note)" 'No resources found' run "$(note_block "$NOTE" 4)"
check_output "consul-0 is not scheduled (from the note)" '^consul-0 +0/1 +Pending .* <none> ' \
  run "$(note_block "$NOTE" 5) --no-headers"

section "Creating Persistent Volumes"
# The note's nodes are node2..node4, reached with ssh; here they are kind containers.
mk=$(note_block "$NOTE" 6)
assert_match "the note's loop creates /mnt/consul on each node" 'mkdir -p /mnt/consul' "$mk"
for n in $W1 $W2 $W3; do docker exec "$n" mkdir -p /mnt/consul; done
sed "s/^          - node2$/          - $W1/; s/^          - node3$/          - $W2/; s/^          - node4$/          - $W3/" \
  container.training/k8s/volumes-for-consul.yaml >container.training/k8s/volumes-for-consul.kind.yaml
check "create the PV objects (from the note, with our node names)" \
  run "$(note_block "$NOTE" 7 | sed 's/volumes-for-consul.yaml/volumes-for-consul.kind.yaml/')"
check "the PVs are matched with the PVCs, and the pods start one by one" \
  kubectl rollout status statefulset/consul --timeout=900s
check_output "the 3 PVCs are bound to our 3 local PVs" '^consul-node2 consul-node3 consul-node4$' \
  bash -c "kubectl get pvc -o jsonpath='{.items[*].spec.volumeName}' | xargs -n1 | sort | xargs"
retry 300 bash -c '[ $(kubectl exec consul-0 -- consul members 2>/dev/null | grep -c " alive ") -eq 3 ]' || true
check_output "our Consul cluster has 3 members (from the note)" 'consul-2 .* alive +server' run "$(note_block "$NOTE" 8)"

section "Devil is in the details"
check_output "the PV size (10Gi) is only for matching: the PVCs asked for 1Gi" '^1Gi 10Gi$' \
  bash -c "echo \$(kubectl get pvc data-consul-0 -o jsonpath='{.spec.resources.requests.storage}') \$(kubectl get pvc data-consul-0 -o jsonpath='{.status.capacity.storage}')"
check_output "kind's own class uses the binding mode the note recommends" \
  "^$(note_block "$NOTE" 9 | sed 's/^ *//; s/: /=/')\$" \
  bash -c "echo volumeBindingMode=\$(kubectl get storageclass standard -o jsonpath='{.volumeBindingMode}')"

section "Validating persistence"
retry 120 bash -c 'kubectl exec consul-0 -- consul kv put answer 42 >/dev/null 2>&1'
check_output "put some data in Consul (from the note)" 'Success! Data written to: answer' run "$(note_block "$NOTE" 10)"
check "delete the Consul cluster (from the note)" run "$(note_block "$NOTE" 11)"
check "wait until the last Pod is deleted (from the note)" run "$(note_block "$NOTE" 12) --timeout=300s"
check_output "PV and PVC are still here (from the note)" 'persistentvolumeclaim/data-consul-2 +Bound' \
  run "$(note_block "$NOTE" 13)"
check "re-create the cluster (from the note)" run "$(note_block "$NOTE" 14)"
kubectl rollout status statefulset/consul --timeout=900s >/dev/null
check_output "the key is still there (from the note)" '^42$' retry_get
check_output "(with the same PVCs and PVs)" '^consul-node2 consul-node3 consul-node4$' \
  bash -c "kubectl get pvc -o jsonpath='{.items[*].spec.volumeName}' | xargs -n1 | sort | xargs"

section "If we have a dynamic provisioner"
kubectl delete -f container.training/k8s/consul-3.yaml --wait=true >/dev/null
kubectl wait --for=delete pod -l app=consul --timeout=300s >/dev/null 2>&1 || true
kubectl delete pvc --all >/dev/null
kubectl delete pv consul-node2 consul-node3 consul-node4 --wait=false >/dev/null 2>&1 || true
kubectl annotate storageclass standard storageclass.kubernetes.io/is-default-class=true --overwrite >/dev/null
check "with a default class, the cluster comes up right away" bash -ec \
  "kubectl apply -f container.training/k8s/consul-3.yaml >/dev/null && kubectl rollout status statefulset/consul --timeout=900s"
check_output "the PVCs get our StorageClass (in spec.storageClassName)" '^standard standard standard$' \
  kubectl get pvc -o jsonpath='{.items[*].spec.storageClassName}'
check_output "and dynamically provisioned PVs" '^3$' \
  bash -c "kubectl get pv -o jsonpath='{range .items[*]}{.spec.storageClassName}{\"\\n\"}{end}' | grep -c '^standard$'"

section "Cleaning up"
check_output "a StatefulSet can delete its PVCs itself: persistentVolumeClaimRetentionPolicy" '^Retain Retain$' \
  kubectl get statefulset consul -o jsonpath='{.spec.persistentVolumeClaimRetentionPolicy.whenDeleted} {.spec.persistentVolumeClaimRetentionPolicy.whenScaled}'
kubectl patch statefulset consul --type=merge -p '{"spec":{"persistentVolumeClaimRetentionPolicy":{"whenDeleted":"Delete"}}}' >/dev/null
check_output "with whenDeleted: Delete, the PVCs get the StatefulSet as owner" 'StatefulSet' \
  retry_owner
kubectl delete statefulset consul >/dev/null
check "deleting the StatefulSet then deletes its PVCs" bash -c \
  'for i in $(seq 1 120); do [ -z "$(kubectl get pvc -o name)" ] && exit 0; sleep 1; done; exit 1'
