#!/usr/bin/env bash
# note: linux/cli/ip.md
# env: priv:leap
# The note's commands run in a network namespace with a dummy eth0, so they never
# touch the container's own routes. The container is removed after the test.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/cli/ip
ip netns add lab
in_ns() { ip netns exec lab bash -ec "$1"; }
in_ns 'ip link set lo up; ip link add eth0 type dummy; ip addr add 192.168.0.1/24 dev eth0; ip link set eth0 up'

section "Routing"
check "add the routes (from the note)" in_ns "$(note_block "$NOTE" Routing 2)"
routes=$(in_ns "$(note_block "$NOTE" Routing 1 | sed -n 1p)")
assert_match "the default route is via the gateway" '^default via 192\.168\.0\.254 dev eth0' "$routes"
assert_match "a route via the interface only" '^192\.168\.1\.0/24 dev eth0' "$routes"
assert_match "a route via a gateway" '^192\.168\.2\.0/24 via 192\.168\.0\.254 dev eth0' "$routes"
assert_eq "ip route show and ip route list print the same" "$routes" \
  "$(in_ns "$(note_block "$NOTE" Routing 1 | sed -n 2p)")"
check_output "a second default route fails with File exists" 'File exists' \
  bash -c "ip netns exec lab ip route add default via 192.168.0.253 dev eth0 2>&1; true"
check "ip route replace changes it" ip netns exec lab ip route replace default via 192.168.0.253 dev eth0
check_output "the new gateway is used" '^default via 192\.168\.0\.253' ip netns exec lab ip route show default
check "delete the routes (from the note)" in_ns "$(note_block "$NOTE" Routing 3)"
routes=$(ip netns exec lab ip route show)
assert_no_match "192.168.1.0/24 is gone" '192\.168\.1\.0/24' "$routes"
assert_no_match "192.168.2.0/24 is gone" '192\.168\.2\.0/24' "$routes"
skip "changes do not survive a reboot" "a container cannot reboot; the namespace is deleted at the end"

section "Interface statistics"
stats=$(in_ns "$(note_block "$NOTE" 'Interface statistics' 1)")
assert_match "-s prints the RX counters" 'RX: +bytes +packets +errors +dropped' "$stats"
assert_match "and the TX counters" 'TX: +bytes +packets +errors +dropped' "$stats"
check_output "-s -s prints the detailed error counters" 'RX errors:' ip netns exec lab ip -s -s link show eth0
