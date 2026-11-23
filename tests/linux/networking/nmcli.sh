#!/usr/bin/env bash
# note: linux/networking/nmcli.md
# env: leap-systemd
# timeout: 900
# Two veth pairs stand in for the NICs: ens1 is the note's eth0, ens2 its eth1. Their
# peers, ens1p and ens2p, are the "switch" side; dnsmasq on ens1p is the DHCP server.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/networking/nmcli
zypper -n -q install --no-recommends NetworkManager udev dnsmasq openssl >/dev/null
# NetworkManager must leave the container's own eth0 alone.
mkdir -p /etc/NetworkManager/conf.d
# No automatic "Wired connection 1" either: it would take the test's interfaces.
printf '[main]\nno-auto-default=*\n[keyfile]\nunmanaged-devices=interface-name:eth0\n' \
  >/etc/NetworkManager/conf.d/99-test.conf
# The test image masks udev; NetworkManager only manages links that udev has seen.
systemctl unmask -q systemd-udevd.service systemd-udevd-control.socket systemd-udevd-kernel.socket
systemctl daemon-reload && systemctl start systemd-udevd
# Both ends up: a NIC with a cable in has carrier, which NetworkManager waits for.
for i in 1 2; do ip link add ens$i type veth peer name ens${i}p && ip link set ens${i}p up && ip link set ens$i up; done
ip addr add 192.168.1.1/24 dev ens1p
dnsmasq --interface=ens1p --bind-interfaces --except-interface=lo --port=0 \
  --dhcp-range=192.168.1.100,192.168.1.150,1h --dhcp-leasefile=/tmp/leases
udevadm trigger --subsystem-match=net --action=add && udevadm settle
systemctl restart NetworkManager
retry 10 nmcli general status
nmcli device set ens1 managed yes && nmcli device set ens2 managed yes

# A note block with the interface names of this test.
nb() { note_block "$NOTE" "$@" | sed -E 's/ eth0\b/ ens1/g; s/ eth1\b/ ens2/g'; }
run() { bash -ec "$1"; }
addr() { ip -4 -br addr show "$1" | awk '{ $1 = $2 = ""; print }'; }
# Addresses appear a moment after nmcli returns.
wait_addr() { retry 15 bash -c "ip -4 addr show $1 | grep -q '$2'"; }
down_all() { nmcli -t -f NAME connection show --active | while read -r c; do nmcli connection down "$c" >/dev/null 2>&1 || true; done; }

section "Leap 16: NetworkManager only"
check_output "NetworkManager is installed" '^NetworkManager-1\.' rpm -q NetworkManager
check_fails "wicked is not installed" rpm -q wicked
check_output "but wicked is still in the Leap 16.0 repository (the note said it was removed)" '^Repository *: repo-oss' \
  bash -c 'zypper -n info wicked'

section "Status"
check "the status commands (from the note)" run "$(nb Status 1 | grep -v '^nmcli  ')"
check_output "nmcli device status lists ens1" '^ens1 +ethernet' nmcli device status

section "Creating connections: DHCP"
check "add the DHCP profile (from the note)" run "$(nb DHCP 1 | sed -n 1p)"
check "up gets a lease from dnsmasq" run "$(nb DHCP 1 | sed -n 2p)"
assert_match "ens1 has a DHCP address" '192\.168\.1\.1[0-5][0-9]/24' "$(addr ens1)"
check "nmcli device show / connection show (from the note)" \
  run "$(nb Status 2 | sed 's/Wired connection 1/office/')"

section "Field selection"
out=$(run "$(nb 'Field selection' 1)")
assert_match "-t -f NAME,DEVICE,STATE: colon-separated, no header" '^office:ens1:activated$' "$out"
assert_match "-g IP4.ADDRESS: the value only" '^192\.168\.1\.1[0-5][0-9]/24$' "$out"
assert_match "-t -f DEVICE,STATE device status" '^ens1:connected$' "$out"
check_output "the loop over active connections (from the note)" '^office on ens1$' run "$(nb 'Field selection' 2)"
check_output "-f ALL lists every field" 'IP4\.ADDRESS' nmcli -f ALL device show ens1
check_output "-p is the pretty mode" '=====' nmcli -p device show ens1

section "Creating connections: static, and the ipv4.method warning"
check "add the static profile (from the note)" run "$(nb '### Static' 1)"
check_output "ipv4.method is manual" '^manual$' nmcli -g ipv4.method connection show static-eth0
nmcli connection add type ethernet con-name no-method ifname ens1 ipv4.addresses 192.168.1.30/24 >/dev/null
check_output "addresses without ipv4.method: the method stays auto" '^auto$' nmcli -g ipv4.method connection show no-method
nmcli connection up no-method >/dev/null
a=$(addr ens1)
assert_match "the correction: DHCP does not replace the static address, both are set" '192\.168\.1\.30/24' "$a"
assert_match "and DHCP adds its own lease next to it" '192\.168\.1\.1[0-5][0-9]/24' "$a"
nmcli connection delete no-method office >/dev/null

section "Modifying"
check "up the static profile" nmcli connection up static-eth0
check "modify, add, remove, clear DNS (from the note)" run "$(nb Modifying 1)"
check_output "the change is written" '^192\.168\.1\.20/24$' nmcli -g ipv4.addresses connection show static-eth0
assert_match "but not applied yet" '192\.168\.1\.10/24' "$(addr ens1)"
check "nmcli device reapply (from the note)" run "$(nb Modifying 2 | grep reapply)"
wait_addr ens1 192.168.1.20/24 || true
assert_match "reapply applied it" '^ *192\.168\.1\.20/24 *$' "$(addr ens1)"
check "the revert command is valid shell" bash -n <(nb Modifying 3)

section "Interactive editor"
nb 'Interactive editor' 2 | sed 's/^nmcli> //' >edit.cmds
check "the editor session, fed on stdin (from the note)" bash -c "nmcli connection edit static-eth0 <edit.cmds"
check_output "set ipv4.dns was saved" '^9\.9\.9\.9$' nmcli -g ipv4.dns connection show static-eth0

section "Wi-Fi"
check "nmcli radio wifi off / on (from the note)" run "$(nb Wi-Fi 1 | grep radio)"
skip "wifi list, rescan, connect" "no Wi-Fi hardware in a container"
mkdir -p /etc/pki/tls/certs
openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -subj /CN=corp-ca -days 1 \
  -out /etc/pki/tls/certs/corp-ca.pem 2>/dev/null
check "the WPA-Enterprise profile is accepted (from the note)" run "$(nb Wi-Fi 2)"
check_output "with PEAP and MSCHAPv2" '^peap mschapv2$' bash -c 'nmcli -g 802-1x.eap,802-1x.phase2-auth connection show corp | xargs'

section "Bridges"
nmcli connection up static-eth0 >/dev/null
check "bridge and port (from the note)" run "$(nb Bridges 1)"
check_output "ens1 is busy with static-eth0: up br0 leaves it there" '^ens1:static-eth0$' \
  nmcli -t -f DEVICE,CONNECTION device status
check "up the port profile (from the note)" run "$(nb Bridges 2)"
check_output "ens1 is now a port of br0" 'master br0' ip link show ens1
wait_addr br0 192.168.1.10/24 || true
check_output "br0 has the address" '192\.168\.1\.10/24' ip -4 addr show br0
assert_eq "bridge.stp no: STP is off in the kernel" 0 "$(cat /sys/class/net/br0/bridge/stp_state)"
nmcli connection delete br0-port1 >/dev/null
check "controller br0 is accepted as well" nmcli connection add type ethernet con-name br0-port1 ifname ens1 controller br0
check_output "and means the same as master" '^br0$' nmcli -g connection.master connection show br0-port1
nmcli connection delete br0-port1 br0 >/dev/null

section "Bonds"
down_all
check "bond and ports (from the note)" run "$(nb Bonds 1)"
retry 10 grep -q 'Slave Interface: ens2' /proc/net/bonding/bond0 || true
b=$(cat /proc/net/bonding/bond0)
grep -q 'Slave Interface: ens2' <<<"$b" || { nmcli device status; nmcli connection show; } | sed 's/^/# /'

assert_match "mode 802.3ad" 'IEEE 802\.3ad Dynamic link aggregation' "$b"
assert_match "xmit_hash_policy layer3+4" 'Transmit Hash Policy: layer3\+4' "$b"
assert_match "lacp_rate fast" 'LACP rate: fast' "$b"
assert_match "miimon 100" 'MII Polling Interval \(ms\): 100' "$b"
assert_match "eth0 (ens1) is in the bond" 'Slave Interface: ens1' "$b"
assert_match "eth1 (ens2) is in the bond" 'Slave Interface: ens2' "$b"
# NetworkManager sets the address a moment after the ports join.
check "bond0 has the address" retry 20 bash -c "ip -4 addr show bond0 | grep -q '192\.168\.1\.10/24'"
nmcli connection delete bond0-p1 bond0-p2 bond0 >/dev/null

section "VLANs"
nmcli connection up static-eth0 >/dev/null
check "VLAN 100 on ens1 (from the note)" run "$(nb VLANs 1)"
check_output "the kernel link is 802.1Q id 100 on ens1" 'vlan protocol 802\.1Q id 100' ip -d link show vlan100
wait_addr vlan100 10.100.0.10/24 || nmcli device status
check_output "with its address" '10\.100\.0\.10/24' ip -4 addr show vlan100

section "Routes and policy routing"
check "routes and never-default (from the note)" run "$(nb Routes 1)"
nmcli connection up static-eth0 >/dev/null
r=$(ip -4 route)
assert_match "10.0.0.0/8 via 192.168.1.254" '^10\.0\.0\.0/8 via 192\.168\.1\.254 dev ens1' "$r"
assert_match "172.16.0.0/12 with metric 100" '^172\.16\.0\.0/12 via 192\.168\.1\.254 dev ens1 .*metric 100' "$r"
assert_no_match "never-default: no default route on ens1" '^default .*dev ens1' "$r"

section "Where profiles live"
check_output "keyfiles in system-connections (from the note)" 'static-eth0\.nmconnection' run "$(nb 'Where profiles live' 1)"
check_output "mode 600" '^600$' stat -c %a /etc/NetworkManager/system-connections/static-eth0.nmconnection
sed -i 's/^dns=.*/dns=1.1.1.1;/' /etc/NetworkManager/system-connections/static-eth0.nmconnection
check "nmcli connection reload (from the note)" run "$(nb 'Where profiles live' 2)"
check_output "the hand edit is now in the profile" '^1\.1\.1\.1$' nmcli -g ipv4.dns connection show static-eth0

section "Troubleshooting"
t=$(nb Troubleshooting 1 | grep -v -- '-f$')
check_output "device show with the STATE, REASON and IP4 fields" 'GENERAL\.REASON: +[0-9]+ ' run "$(sed -n 1p <<<"$t")"
check_output "connection show filtered on ipv4 and autoconnect" 'connection\.autoconnect:' run "$(sed -n 2p <<<"$t")"
check "the logging level command (from the note)" run "$(nb Troubleshooting 1 | grep logging)"
check_output "the journal has NetworkManager's log" 'NetworkManager' journalctl -u NetworkManager -n 5 --no-pager
