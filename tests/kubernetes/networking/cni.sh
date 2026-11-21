#!/usr/bin/env bash
# note: kubernetes/networking/cni.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/networking/cni
use_test_namespace
W=$CLUSTER-worker

section "How the plugins are found"
check_output "the CNI configuration is a single file in /etc/cni/net.d" '\.conflist$' \
  docker exec "$W" ls /etc/cni/net.d
conf=$(docker exec "$W" sh -c 'cat /etc/cni/net.d/*.conflist')
assert_match "a .conflist has a top-level plugins list (conf vs conflist)" '"plugins"' "$conf"
assert_match "each chained plugin has its own type field" '"type"' "$conf"
check_output "the plugins are executables on the node" 'ptp' \
  docker exec "$W" ls /opt/cni/bin

section "How plugins are invoked"
check_output "the note's manual VERSION invocation works" 'cniVersion' \
  docker exec "$W" bash -ec "$(note_block "$NOTE" 'How plugins are invoked' 1)"

section "Other ways to distribute routing tables"
# The API has every node's podCIDR; the snippet prints one route per other node.
# The snippet is the 4th block under "Testing it" (inside the last callout there).
# Pipe it into bash: quoting it would expand $NODES/$DESTNODE here instead.
routes=$(note_block "$NOTE" 'Testing it' 4 | HOSTNAME=$CLUSTER-worker bash)
assert_match "the block read from the note is the route generator" 'route add' \
  "$(note_block "$NOTE" 'Testing it' 4)"
assert_match "the snippet prints route commands with podCIDR and gateway" \
  'route add -net 10\..* gw ' "$routes"
assert_eq "one route per other node" 2 "$(grep -c 'route add' <<<"$routes")"
assert_no_match "and none for the local node" "$CLUSTER-worker " "$routes"

section "In practice: kube-router (historical)"
skip "the kube-router multi-VM walkthrough" \
  "needs the training's kuberouter1..3 VMs and pre-1.24 kubelet flags, as the note's warning says"
