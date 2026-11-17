#!/usr/bin/env bash
# note: kubernetes/networking/cilium/basics.md
# env: kind
# timeout: 1800
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
source "$NOTES_ROOT/tests/kubernetes/networking/cilium/cilium-lib.bash"

NOTE=kubernetes/networking/cilium/basics
C=cil-basics
# kube-proxy replacement on, so the note's verification grep has something to show.
cilium_cluster "$C" 1 \
  --set kubeProxyReplacement=true \
  --set "k8sServiceHost=$C-control-plane" \
  --set k8sServicePort=6443

section "Identity, not IP addresses"
kubectl create deployment frontend --image=nginx:1.29 --replicas=3 >/dev/null
kubectl rollout status deployment/frontend --timeout=180s >/dev/null
check "identities and endpoints are visible as cluster resources (from the note)" \
  bash -ec "$(note_block "$NOTE" 'Identity, not IP addresses' 2)"
ids=$(kubectl get ciliumendpoints -l app=frontend \
  -o jsonpath='{range .items[*]}{.status.identity.id}{"\n"}{end}' | sort -u | wc -l)
assert_eq "all 3 replicas share one identity (labels, not pods)" "1" "${ids// /}"
check_output "reserved identities exist (world)" 'reserved:world' \
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg identity list

section "The datapath: routing modes"
check_output "the default routing mode is tunnel (from the note's command)" '[Tt]unnel' \
  bash -ec "$(note_block "$NOTE" 'The datapath: routing modes' 1)"

section "Replacing kube-proxy"
check_output "KubeProxyReplacement is reported enabled (from the note's command)" \
  'KubeProxyReplacement:.*[Tt]rue' \
  bash -ec "$(note_block "$NOTE" 'Replacing kube-proxy' 3)"

section "The components"
check "cilium-agent runs as a DaemonSet" kubectl -n kube-system get ds cilium
check "cilium-operator runs as a Deployment" kubectl -n kube-system get deploy cilium-operator
check "cilium-envoy runs as a DaemonSet" kubectl -n kube-system get ds cilium-envoy

section "Two different CLIs"
check_output "cilium-dbg is the agent's debug CLI" 'KubeProxyReplacement' \
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status
check "the pre-1.16 name still works via a shim (from the note)" \
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium status --brief
