#!/usr/bin/env bash
# note: linux/networking/virtual-interfaces.md
# env: leap-systemd
# timeout: 900
# The labs, in the container's own network namespace. The note's eth0, eth1 and eth2
# become veth pairs ens1..ens3 (their peers ens1p..ens3p are the "switch" side). The
# host address 10.240.1.20 is added to the container's eth0.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/networking/virtual-interfaces
zypper -n -q install --no-recommends NetworkManager udev iputils >/dev/null
mkdir -p /etc/NetworkManager/conf.d
printf '[main]\nno-auto-default=*\n[keyfile]\nunmanaged-devices=interface-name:eth0\n' \
  >/etc/NetworkManager/conf.d/99-test.conf
systemctl unmask -q systemd-udevd.service systemd-udevd-control.socket systemd-udevd-kernel.socket
systemctl daemon-reload && systemctl start systemd-udevd
for i in 1 2 3 4; do ip link add ens$i type veth peer name ens${i}p && ip link set ens${i}p up && ip link set ens$i up; done
udevadm trigger --subsystem-match=net --action=add && udevadm settle
systemctl restart NetworkManager
retry 10 nmcli general status
for i in 1 2 3; do nmcli device set ens$i managed yes; done
ip addr add 10.240.1.20/24 dev eth0

# The commands of a console block: `$ ` lines, with their `\` continuation lines.
cmds() {
  note_block "$NOTE" "$@" | awk '
    /^\$ / { sub(/^\$ /, ""); print; cont = /\\$/; next }
    cont { print; cont = /\\$/ }' | sed -E 's/ eth0\b/ ens1/g; s/ eth1\b/ ens2/g; s/ eth2\b/ ens3/g; s/eth0\.([23])/ens1.\1/g'
}
# Line N of a console block's commands (continuations joined).
cmd() { cmds "$1" "$2" | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' | sed -n "${3}p"; }
run() { bash -ec "$1"; }
ns() { ip netns exec "$@"; }

section "Namespaces"
for t in pid net mnt uts ipc user cgroup time; do
  check "the $t namespace exists" test -e /proc/self/ns/$t
done

section "Bridge (hands-on)"
check_output "two namespaces (from the note)" '^lab1' run "$(cmds '### Bridge' 2)"
check "two veth pairs (from the note)" run "$(cmds '### Bridge' 3 | grep 'ip link add')"
check_output "they are down" 'veth-demo1@bridge-veth1: <BROADCAST,MULTICAST,M-DOWN>.*state DOWN' ip link list
check "move one end of each into its namespace (from the note)" run "$(cmds '### Bridge' 4 | grep netns)"
check_fails "veth-demo1 is gone from the host" ip link show veth-demo1
check_output "but it is in lab1" 'veth-demo1@if[0-9]+:' ns lab1 ip link
check_output "address and up in lab1 (from the note)" 'state LOWERLAYERDOWN' run "$(cmds '### Bridge' 6 | sed -n 1,3p)"
check "same in lab2 (from the note)" run "$(cmds '### Bridge' 6 | sed -n 4,5p)"
check "create the bridge (from the note)" run "$(cmds '### Bridge' 7)"
check_output "attach the ports (from the note)" 'bridge-veth2@if[0-9]+:.*master br1dge state forwarding' run "$(cmds '### Bridge' 8)"
check_output "lab1 reaches lab2 through the bridge" '2 received' run "$(cmd '### Bridge' 9 1)"
check_output "but not the host address: no route" 'Network is unreachable' bash -c "$(cmd '### Bridge' 9 2) 2>&1; true"
check_fails "and the host cannot reach lab1" run "$(cmd '### Bridge' 9 3)"
check_output "with an address on the bridge, the host reaches lab1 (from the note)" '2 received' run "$(cmds '### Bridge' 10)"
check_output "default routes in the namespaces (from the note)" '^default dev veth-demo1 scope link' \
  run "$(cmds '### Bridge' 11 | sed -n 1,4p)"
check_output "now lab1 reaches the host's eth0 address" '2 received' run "$(cmds '### Bridge' 11 | sed -n 5p)"
# ip_forward is per network namespace: this changes the container only.
sysctl -q -w net.ipv4.ip_forward=0
check_output "no routing involved: with forwarding off, lab1 still reaches the host" '1 received' \
  ns lab1 ping -c1 -W2 10.240.1.20
sysctl -q -w net.ipv4.ip_forward=1
tip=$(grep -o 'ip netns del lab1; ip netns del lab2; ip link del br1dge' "$NOTES_ROOT/content/$NOTE.md")
check "the cleanup tip" run "$tip"
# The kernel cleans up a deleted namespace in the background: give it a moment.
check "deleting the namespaces removed the host ends of the veth pairs" retry 10 bash -c '! ip link show bridge-veth1'


section "veth"
ip netns add lab1 && ip netns add lab2
check "a veth pair straight between two namespaces (from the note)" run "$(note_block "$NOTE" '### veth' 1)"
ns lab1 ip addr add 192.168.43.1/24 dev veth-demo1 && ns lab1 ip link set veth-demo1 up
ns lab2 ip addr add 192.168.43.2/24 dev veth-demo2 && ns lab2 ip link set veth-demo2 up
check_output "they reach each other" '1 received' ns lab1 ping -c1 -W2 192.168.43.2
ip netns del lab1 && ip netns del lab2

section "Team"
team=$(cmds '### Team' 2)
check "the team packages install (from the note)" run "$(grep '^zypper' <<<"$team" | sed 's/zypper install -y/zypper -n -q install/')"
check "the team0 profile (from the note)" run "$(cmd '### Team' 2 2)"
check "the two port profiles (from the note)" run "$(cmds '### Team' 2 | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' | grep team-slave)"
check_fails "the kernel of the test VM has no team driver either" ip link add team9 type team
skip "teamdctl state, ping over team0" "no team support in Leap 16's NetworkManager or in the test kernel"

section "VLAN"
nmcli connection add type ethernet con-name eth0 ifname ens1 ipv4.method manual ipv4.addresses 10.240.2.20/24 >/dev/null
nmcli connection up eth0 >/dev/null
check_output "VLAN 2 (from the note)" 'successfully added' run "$(cmd '### VLAN' 2 1)"
check_output "VLAN 3 (from the note)" 'successfully added' run "$(cmd '### VLAN' 2 2)"
check_output "the ip4 shortcut sets ipv4.method manual" '^manual$' nmcli -g ipv4.method connection show ens1.2
retry 15 bash -c "ip -4 addr show ens1.3 | grep -q 192.168.3.1/24" || true
check_output "ens1.2 has its address" 'inet 192\.168\.2\.1/24' ip addr show ens1.2
check_output "ens1.3 has its address" 'inet 192\.168\.3\.1/24' ip addr show ens1.3
check_output "they are 802.1Q on ens1" 'vlan protocol 802\.1Q id 2' ip -d link show ens1.2
mac=$(cat /sys/class/net/ens1/address)
assert_eq "the VLAN interfaces share the parent's MAC" "$mac $mac" "$(cat /sys/class/net/ens1.2/address) $(cat /sys/class/net/ens1.3/address)"
check_fails "the VLAN ID cannot exceed 4094" ip link add link ens1 name ens1.4095 type vlan id 4095

section "MACVLAN: private"
ip netns add lab1 && ip netns add lab2
mv=$(cmds 'Private' 2 | sed -e ':a' -e '/\\$/N; s/\\\n//; ta')
check "create and up two private macvlans (from the note)" run "$(sed -n 1,4p <<<"$mv")"
check "move them to the namespaces and address them (from the note)" run "$(sed -n '5,11p' <<<"$mv")"
check_output "macvlan1 has its own MAC" 'link/ether' ns lab1 ip link show macvlan1
assert_no_match "different from the parent's" "$(cat /sys/class/net/ens2/address)" "$(ns lab1 ip link show macvlan1)"
lo=$(cmds 'Private' 3)
check_fails "with lo down, the namespace cannot ping its own address" run "$(sed -n 1p <<<"$lo")"
check_output "with lo up it can (from the note)" '2 received' run "$(sed -n 2,3p <<<"$lo")"
check_fails "private: lab2 cannot reach lab1 on the same subnet (from the note)" run "$(cmds 'Private' 4)"
ip netns del lab1 && ip netns del lab2
nmcli connection delete macvlan1 macvlan2 >/dev/null

# Two macvlans of MODE on ens2, in lab1 and lab2, with addresses .1 and .2.
two_macvlans() {
  ip netns add lab1 && ip netns add lab2
  for i in 1 2; do
    ip link add link ens2 name mv$i type macvlan mode "$1"
    ip link set mv$i netns lab$i
    ns lab$i ip addr add 192.168.42.$i/24 dev mv$i
    ns lab$i ip link set mv$i up && ns lab$i ip link set lo up
  done
}
section "MACVLAN: VEPA"
ip link add sw type bridge && ip link set sw up && ip link set ens2p master sw
two_macvlans vepa
check_fails "vepa: without hairpin on the switch port, lab1 cannot reach lab2" ns lab1 ping -c1 -W2 192.168.42.2
bridge link set dev ens2p hairpin on
check_output "with hairpin mode on the switch port, it can" '1 received' ns lab1 ping -c1 -W2 192.168.42.2
ip netns del lab1 && ip netns del lab2
ip link del sw

section "MACVLAN: bridge"
check "bridge mode (from the note)" run "$(note_block "$NOTE" '#### Bridge' 1 | sed 's/ eth1 / ens2 /')"
check_output "it is a bridge-mode macvlan" 'macvlan mode bridge' ip -d link show macvlan1
nmcli connection delete macvlan1 >/dev/null
two_macvlans bridge
check_output "bridge: lab1 reaches lab2 without leaving the host" '1 received' ns lab1 ping -c1 -W2 192.168.42.2
ip addr add 192.168.42.254/24 dev ens2
check_fails "but not the parent interface's own address" ns lab1 ping -c1 -W2 192.168.42.254
ip addr del 192.168.42.254/24 dev ens2
ip netns del lab1 && ip netns del lab2

section "MACVLAN: passthru"
check "one passthru macvlan on the parent" ip link add link ens3 name pt1 type macvlan mode passthru
check_fails "a second one is refused" ip link add link ens3 name pt2 type macvlan mode passthru
ip link del pt1

section "MACVLAN: source"
check "source mode, with MAC lists (from the note)" run "$(note_block "$NOTE" '#### Source' 1 | sed 's/ eth0 / ens3 /')"
m0=$(ip -d link show macvlan0) m1=$(ip -d link show macvlan1)
assert_match "macvlan0 has two source MACs" 'remotes \(2\)' "$m0"
assert_match "00:11:11:11:11:11 and 00:22:22:22:22:22" '00:11:11:11:11:11.*00:22|00:22:22:22:22:22.*00:11' "$m0"
assert_match "macvlan1 has 00:33:33:33:33:33 and 00:44:44:44:44:44" 'remotes \(2\) .*00:33:33:33:33:33|remotes \(2\) 00:44:44:44:44:44 00:33' "$m1"

section "IPVLAN"
check "an L2 ipvlan (from the note)" run "$(note_block "$NOTE" '### IPVLAN' 1 | sed 's/ eth0 / ens4 /')"
assert_eq "it has the parent's MAC" "$(cat /sys/class/net/ens4/address)" "$(cat /sys/class/net/ipvlan1/address)"
for m in l3 l3s; do
  check "mode $m exists" ip link add link ens4 name ipv-$m type ipvlan mode $m
done
check_fails "ipvlan and macvlan cannot share a parent" ip link add link ens4 name mvx type macvlan
