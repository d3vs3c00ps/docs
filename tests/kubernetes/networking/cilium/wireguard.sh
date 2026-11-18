#!/usr/bin/env bash
# note: kubernetes/networking/cilium/wireguard.md
# env: kind
# timeout: 1800
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
source "$NOTES_ROOT/tests/kubernetes/networking/cilium/cilium-lib.bash"

NOTE=kubernetes/networking/cilium/wireguard
C=cil-wg
cilium_cluster "$C" 1

section "Prerequisites"
if docker exec "$C-control-plane" sh -c '[ -e /proc/config.gz ] || [ -e /boot/config-$(uname -r) ]'; then
  check_output "the kernel has WireGuard (the note's check, on a node)" 'CONFIG_WIREGUARD' \
    docker exec "$C-control-plane" bash -ec "$(note_block "$NOTE" 'Prerequisites' 1)"
else
  skip "the kernel has WireGuard (the note's check)" "this kernel publishes no config file; the checks below show WireGuard works"
fi

section "Enabling it"
check "the note's helm upgrade turns on WireGuard encryption" \
  bash -ec "$(note_block "$NOTE" 'Enabling it' 1)"
check_output "restart the agents, then the status line reports Wireguard (from the note)" \
  'Wireguard.*Port: 51871' \
  bash -ec "$(note_block "$NOTE" 'Enabling it' 2 | grep -v '^#')"
# Two nodes: each agent peers with the one other node.
check_output "the peer count is nodes - 1" 'Peers: 1' \
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status
check_output "each node publishes its public key on its CiliumNode (from the note)" \
  '[A-Za-z0-9+/]{30,}=*' \
  bash -ec "$(note_block "$NOTE" 'Enabling it' 3)"

section "What is and is not encrypted"
check "pod traffic still flows with encryption on" \
  bash -c 'kubectl create deployment web --image=nginx:1.29 >/dev/null &&
           kubectl expose deployment web --port=80 >/dev/null &&
           kubectl rollout status deployment/web --timeout=180s >/dev/null &&
           kubectl run wg-probe --image=alpine --restart=Never --rm -i --quiet -- \
             wget -qO- -T 10 http://web >/dev/null'

section "Verifying it is actually on"
check_output "the agent agrees (cilium-dbg encrypt status)" 'Wireguard|WireGuard' \
  bash -ec "$(note_block "$NOTE" 'Verifying it is actually on' 1 | sed -n 2p)"
check_output "the cilium_wg0 interface exists with the wireguard type" 'wireguard' \
  bash -ec "$(note_block "$NOTE" 'Verifying it is actually on' 1 | sed -n 5p)"
skip "capture on the node to confirm no readable payload" \
  "kind node images ship no tcpdump; the interface and encrypt status checks above cover the datapath side"

section "Performance"
skip "cilium connectivity perf" \
  "a several-minute benchmark that needs cilium-cli; numbers on this laptop say nothing about real hardware"
