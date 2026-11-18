#!/usr/bin/env bash
# note: kubernetes/cluster-setup/cluster-upgrade.md
# env: kind
# timeout: 2400
# The note upgrades an openSUSE kubeadm cluster from 1.31 to 1.32 with zypper. Here:
# a kind cluster (kubeadm too) from the previous minor version to the pinned one, with
# the release binaries. The zypper repository steps are in cluster-upgrade.leap.sh.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/cluster-setup/cluster-upgrade
cd "$(mktemp -d)"
C=notes-upgrade
CP=$C-control-plane
W=$C-worker
# A second worker: the control plane is tainted, so drained pods need somewhere to go.
W2=$C-worker2
kind_cluster "$C"
printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes: [{role: control-plane}, {role: worker}, {role: worker}]\n' >kind.yaml
out=$(kind create cluster --name "$C" --image "$KIND_NODE_IMAGE_PREV" --config kind.yaml 2>&1) || { echo "$out"; kind_diag; exit 1; }
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
OLD=$(kubectl get node "$CP" -o jsonpath='{.status.nodeInfo.kubeletVersion}')
NEW=$KUBECTL_VERSION
arch=$(kubectl get node "$CP" -o jsonpath='{.status.nodeInfo.architecture}')
run() { bash -ec "$1" 2>&1; }
# set_apiserver_image TAG: the note's manual edit of the static pod manifest.
set_apiserver_image() {
  docker exec "$CP" sed -i "s|image: registry.k8s.io/kube-apiserver:.*|image: registry.k8s.io/kube-apiserver:$1|" \
    /etc/kubernetes/manifests/kube-apiserver.yaml
  retry 180 bash -c "kubectl version -o json 2>/dev/null | jq -er '.serverVersion.gitVersion' | grep -qx '$1'"
}
# install_bin NODE NAME: the release binary NAME at version NEW, on NODE.
install_bin() {
  docker exec "$1" curl -fsSLo "/usr/bin/$2" "https://dl.k8s.io/release/$NEW/bin/linux/$arch/$2"
  docker exec "$1" chmod +x "/usr/bin/$2"
}

section "Checking what we're running"
check_output "kubectl version shows the API server version (from the note)" "^Server Version: $OLD\$" \
  run "$(note_block "$NOTE" 1)"
check_output "kubectl get nodes -o wide: kubelet, kernel, container engine (from the note)" \
  "^$W +Ready .* $OLD .*containerd://" run "$(note_block "$NOTE" 2)"
check_output "the control plane images, one per line (from the note)" "kube-apiserver-$CP +registry.k8s.io/kube-apiserver +$OLD" \
  run "$(note_block "$NOTE" 3)"

section "Changing the API server version"
check "edit the image: line of the static pod manifest (the note uses vim)" set_apiserver_image "$NEW"
check_output "kubelet restarted it: the API server is newer now (from the note)" "^Server Version: $NEW\$" \
  run "$(note_block "$NOTE" 6)"
# Its health-check Job can time out while the restarted API server settles.
retry 5 bash -c "docker exec $CP kubeadm upgrade plan 2>&1 | grep -q 'Cluster version'" || true
check_output "kubeadm upgrade plan is confused: it reports our manual version" "Cluster version: ${NEW#v}$" \
  bash -c "docker exec $CP kubeadm upgrade plan 2>&1 || true"
check_output "and kubeadm itself is still the old version" "$OLD" docker exec "$CP" kubeadm version -o short

section "Reverting our manual API server upgrade"
check "restore the original image" set_apiserver_image "$OLD"

section "Upgrading kubeadm (release binary instead of zypper)"
check "kubeadm $NEW on the control plane" install_bin "$CP" kubeadm
check_output "kubeadm upgrade plan (from the note)" "kubeadm upgrade apply v1\.[0-9]+\.[0-9]+" \
  docker exec "$CP" kubeadm upgrade plan
check "kubeadm upgrade apply (from the note, with --yes: it asks for confirmation)" docker exec "$CP" \
  bash -c "$(note_block "$NOTE" 11 | sed "s/^ *sudo //; s/v1\.32\.0/$NEW/") --yes"
check_output "the API server runs $NEW" "^Server Version: $NEW\$" kubectl version
check_output "kubeadm upgraded the whole control plane" "^$NEW $NEW $NEW\$" bash -c \
  "for c in kube-apiserver kube-controller-manager kube-scheduler; do kubectl -n kube-system get pod \$c-$CP -o jsonpath='{.spec.containers[0].image}' | sed 's/.*://'; echo; done | xargs"

section "Upgrading kubelet the right way"
loop=$(note_block "$NOTE" 13)
assert_match "the note runs kubeadm upgrade node before it upgrades kubelet" \
  'kubeadm upgrade node &&.*install kubelet' "$(tr '\n' ' ' <<<"$loop")"
for n in "$CP" "$W" "$W2"; do
  [[ $n != "$CP" ]] && install_bin "$n" kubeadm
  check "kubeadm upgrade node on $n" docker exec "$n" kubeadm upgrade node
  docker exec "$n" systemctl stop kubelet
  install_bin "$n" kubelet
  docker exec "$n" systemctl start kubelet
done
retry 180 bash -c "[ \"\$(kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion}')\" = '$NEW $NEW $NEW' ]" || true
check_output "all our nodes run $NEW (from the note)" "^$W +Ready .* $NEW " run "$(note_block "$NOTE" 14)"
check_output "(all three)" "^$NEW $NEW $NEW\$" kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion}'
kubectl create deployment web --image=nginx:1.29 --replicas=2 >/dev/null
check "a deployment still runs on the upgraded nodes" kubectl rollout status deployment/web --timeout=180s

section "Draining a node"
check "kubectl drain cordons and evicts" kubectl drain "$W" --ignore-daemonsets --delete-emptydir-data --timeout=180s
check_output "the node is unschedulable" '^true$' kubectl get node "$W" -o jsonpath='{.spec.unschedulable}'
check "the evicted pods were recreated on the other node" kubectl rollout status deployment/web --timeout=180s
check_output "(none left on $W, except DaemonSets)" '^0$' bash -c \
  "kubectl get pods -l app=web --field-selector spec.nodeName=$W --no-headers 2>/dev/null | wc -l | tr -d ' '"
check "kubectl uncordon puts it back" kubectl uncordon "$W"
check_output "(schedulable again)" '^$' kubectl get node "$W" -o jsonpath='{.spec.unschedulable}'
