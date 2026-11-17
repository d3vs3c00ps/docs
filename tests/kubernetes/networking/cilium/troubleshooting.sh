#!/usr/bin/env bash
# note: kubernetes/networking/cilium/troubleshooting.md
# env: kind
# timeout: 1800
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
source "$NOTES_ROOT/tests/kubernetes/networking/cilium/cilium-lib.bash"

NOTE=kubernetes/networking/cilium/troubleshooting
C=cil-trouble
cilium_cluster "$C" 2

node=$C-worker
CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium \
  --field-selector "spec.nodeName=$node" -o name | head -1)
K() { kubectl -n kube-system exec "$CILIUM_POD" -c cilium-agent -- "$@"; }

section "Inspecting the eBPF state"
check "endpoint list" K cilium-dbg endpoint list
check "identity list" K cilium-dbg identity list
check_output "service list shows the kubernetes Service" 'ClusterIP' \
  K cilium-dbg service list
check "bpf lb list" K cilium-dbg bpf lb list
check_output "bpf tunnel list has entries in tunnel mode" '.' \
  K cilium-dbg bpf tunnel list
check_output "bpf ipcache maps IPs to identities" 'identity' \
  K cilium-dbg bpf ipcache list
check "map list with entry counts" K cilium-dbg map list --verbose
check "monitor streams events (2s sample)" \
  bash -c "kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- \
    timeout 2 cilium-dbg monitor -t drop; rc=\$?; [ \$rc -eq 0 ] || [ \$rc -eq 124 ]"

section "The agent crash-loops"
# No crash here, so no --previous container; the log command itself is the claim.
check "the agent logs are where the cause is stated" \
  bash -c "kubectl -n kube-system logs ds/cilium -c cilium-agent | tail -50"

section "Pods stuck in ContainerCreating"
check_output "the CNI config on the node is Cilium's" '05-cilium.conflist' \
  docker exec "$node" ls /etc/cni/net.d/
check_output "and it declares the cilium-cni plugin" 'cilium-cni' \
  docker exec "$node" cat /etc/cni/net.d/05-cilium.conflist
check_output "the agent runs on this node" "$node" \
  bash -c "kubectl -n kube-system get pod -l k8s-app=cilium -o wide | grep $node"
check_output "the node's IPAM state is inspectable (from the note)" 'podCIDRs|pool' \
  bash -c "kubectl get ciliumnode $node -o json | jq '.spec.ipam'"

section "Connectivity works, but not always"
# Two pods on different nodes, then the note's MTU probe technique.
kubectl run probe --image=nicolaka/netshoot --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"'"$C-worker"'"}}}' \
  -- sleep 3600 >/dev/null
kubectl run peer --image=nginx:1.29 --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"'"$C-worker2"'"}}}' >/dev/null
kubectl wait --for=condition=Ready pod/probe pod/peer --timeout=300s >/dev/null
PEER_IP=$(kubectl get pod peer -o jsonpath='{.status.podIP}')
check "ping -M do finds the largest surviving packet (from the note)" \
  kubectl exec probe -- ping -M "do" -s 1372 -c 2 "$PEER_IP"

section "Services do not resolve or connect"
kubectl expose pod peer --name=web --port=80 >/dev/null
SVC_IP=$(kubectl get svc web -o jsonpath='{.spec.clusterIP}')
sleep 5
check_output "the Service is in the datapath" "$SVC_IP" \
  bash -c "kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg service list | grep $SVC_IP"
check_output "no backends means a Kubernetes problem: check the EndpointSlice" "$PEER_IP" \
  kubectl get endpointslices -l kubernetes.io/service-name=web -o wide

section "Identity churn"
check "counting identities (from the note)" \
  bash -c 'kubectl get ciliumidentities --no-headers | wc -l'
check "the label histogram that finds the churning label (from the note)" \
  bash -ec "$(note_block "$NOTE" 'Identity churn' 1 | sed -n 2,3p)"

section "After an upgrade"
check "rollout status of the agent DaemonSet" \
  kubectl -n kube-system rollout status ds/cilium --timeout=120s

section "Collecting everything"
skip "cilium sysdump" \
  "needs cilium-cli and downloads the whole cluster state (minutes, a large archive); the cli itself is installed and exercised in the install test"
