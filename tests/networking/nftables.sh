#!/usr/bin/env bash
# note: networking/nftables.md
# env: leap-systemd
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"
declare -A after

NOTE=networking/nftables
cd "$(mktemp -d)"
zypper -n -q install --no-recommends nftables conntrack-tools iptables curl iputils at >/dev/null

# The container is the host (and, for NAT, the router). Clients live in network
# namespaces, joined to it by veth pairs:
#   trusted  10.99.0.2      <-> host 10.99.0.1      (inside the note's @trusted set)
#   outside  198.51.100.2   <-> host 198.51.100.1   (not trusted)
#   lan      192.168.1.10   <-> host 192.168.1.1    (behind NAT)
link() {
  ip netns add "$1"
  ip link add "h-$1" type veth peer name eth0 netns "$1"
  ip addr add "$2.1/24" dev "h-$1" && ip link set "h-$1" up
  ip -n "$1" addr add "$2.$3/24" dev eth0
  ip -n "$1" link set eth0 up && ip -n "$1" link set lo up
  ip -n "$1" route add default via "$2.1"
}
link trusted 10.99.0 2
link outside 198.51.100 2
link lan 192.168.1 10
for p in 22 443 8080; do python3 -m http.server "$p" >/dev/null 2>&1 & done
ip netns exec lan python3 -m http.server 80 >/dev/null 2>&1 &
ip netns exec outside python3 -m http.server 9000 >/dev/null 2>&1 &
sleep 2

# reach NS HOST:PORT: an HTTP request from namespace NS (or "host") succeeds.
reach() {
  local ns=(ip netns exec "$1")
  [[ $1 == host ]] && ns=()
  "${ns[@]}" curl -s -o /dev/null --max-time 2 "http://$2/"
}
# curl_code NS HOST:PORT: curl's exit code. 7 = refused at once (reject), 28 = timeout (drop).
curl_code() { reach "$@"; echo $?; }

section "Tables, chains and rules"
nft flush ruleset
check "an empty ruleset lets everything through" reach outside 198.51.100.1:8080
check "the egress hook exists on this kernel" \
  nft add table netdev t \; add chain netdev t e '{ type filter hook egress device h-outside priority 0; }'
nft delete table netdev t

section "TL;DR"
check "the TL;DR commands run in order (from the note)" bash -ec "$(note_block "$NOTE" 'TL;DR' 1)"

section "A host firewall"
mkdir -p /etc/nftables/rules
note_block "$NOTE" 'A host firewall' 1 >/etc/nftables/rules/main.nft
check "nft -c -f checks it (from the note)" bash -ec "$(note_block "$NOTE" 'A host firewall' 2 | sed -n 1p)"
check_output "and -c changes nothing" '^$' nft list ruleset
check "nft -f loads it (from the note)" bash -ec "$(note_block "$NOTE" 'A host firewall' 2 | sed -n 2p)"
check "trusted network: SSH is allowed" reach trusted 10.99.0.1:22
check "trusted network: HTTPS is allowed" reach trusted 10.99.0.1:443
check_fails "trusted network: other ports are dropped" reach trusted 10.99.0.1:8080
check_fails "outside: SSH is dropped" reach outside 198.51.100.1:22
check "outside: HTTPS is allowed" reach outside 198.51.100.1:443
check "ping is allowed" ip netns exec outside ping -c1 -W2 198.51.100.1
check "replies to connections the host opened come back (ct state established)" reach host 198.51.100.2:9000
check_output "the drop rule counts what it logs" 'counter packets [1-9]' \
  bash -c "nft list chain inet filter input | grep 'nft-drop'"
check_output "a flood of pings is cut at 10/second" '60 packets transmitted, [0-9]+ received, [1-9][0-9.]*% packet loss' \
  ip netns exec outside ping -c 60 -i 0.01 -q 198.51.100.1
sleep 2   # let the limit's bucket refill after the flood
check_output "while a normal ping gets every reply" '3 packets transmitted, 3 received' \
  ip netns exec outside ping -c 3 -i 0.3 -q 198.51.100.1
# The reason the limit comes first: with it after the ct rule, a flood passes.
sed '/limit rate over/d; s/meta l4proto { icmp, ipv6-icmp } accept/meta l4proto { icmp, ipv6-icmp } limit rate 10\/second accept/' \
  /etc/nftables/rules/main.nft >after-ct.nft
nft -f after-ct.nft
check_output "a limit after the ct rule lets the whole flood through" '60 packets transmitted, 60 received' \
  ip netns exec outside ping -c 60 -i 0.01 -q 198.51.100.1
nft -f /etc/nftables/rules/main.nft
check_output "conntrack -L lists the tracked connections" 'dport=9000' conntrack -L
# Loading is atomic: a file with an error at the end changes nothing.
before=$(nft list ruleset)
printf 'flush ruleset\ntable inet broken {\n  chain c { tcp dport 1 accept }\n  this is not nft\n}\n' >broken.nft
check_fails "a file with an error does not load" nft -f broken.nft
assert_eq "and the running ruleset is untouched" "$before" "$(nft list ruleset)"
# Without flush ruleset, loading twice adds every rule twice.
grep -v '^flush ruleset' /etc/nftables/rules/main.nft | sed 's/table inet filter/table inet twice/' >noflush.nft
nft -f noflush.nft && nft -f noflush.nft
check_output "without flush ruleset, a second load duplicates the rules" '^2$' \
  bash -c "nft list chain inet twice input | grep -c 'tcp dport 443 accept'"
nft delete table inet twice
systemctl start atd
check "the rollback safety net: at schedules a flush (from the note)" \
  bash -ec "$(sed -n 's/.*`\(echo .nft flush ruleset. | at now + 5 minutes\)`.*/\1/p' "$NOTES_ROOT/content/$NOTE.md")"
check_output "atq lists it" '[0-9]' atq
atq | awk '{ print $1 }' | xargs -r atrm

section "Prerequisites"
check "enable forwarding for the running system (from the note)" bash -ec "$(note_block "$NOTE" Prerequisites 1 | sed -n 2p)"
check_output "net.ipv4.ip_forward is 1" '^1$' sysctl -n net.ipv4.ip_forward
sysctl -qw net.ipv4.ip_forward=0
# The note ends with `sysctl --system`, which would also apply the distribution's
# kernel-wide settings to the shared Docker host. Load only the note's file.
check "the persistent file (from the note)" bash -ec "$(note_block "$NOTE" Prerequisites 1 | sed -n '/^cat /,/^EOF/p')"
check "sysctl -p on it applies both settings" sysctl -p /etc/sysctl.d/net-forward.conf
check_output "net.ipv4.ip_forward is 1" '^1$' sysctl -n net.ipv4.ip_forward
check_output "net.ipv6.conf.all.forwarding is 1" '^1$' sysctl -n net.ipv6.conf.all.forwarding

section "iptables and firewalld"
check_output "iptables is iptables-nft" '\(nf_tables\)' iptables -V
iptables -A INPUT -p tcp --dport 7777 -j ACCEPT
check_output "an iptables rule shows up in nft list ruleset" 'table ip filter' nft list ruleset
nft flush ruleset
check_fails "and flush ruleset removes it" bash -c 'iptables -S INPUT | grep -q 7777'
check_fails "there is no iptables.service on Leap 16 (the correction)" systemctl cat iptables.service
check "firewalld is a package here" zypper -n -q info firewalld

section "Actions"
nft -f /etc/nftables/rules/main.nft
nft add rule inet filter input tcp dport 8080 reject
start=$SECONDS
check_output "reject fails at once" '^7$' curl_code outside 198.51.100.1:8080
assert_match "within a second, not after the timeout" '^[01]$' "$((SECONDS - start))"
nft flush chain inet filter input
nft add rule inet filter input tcp dport 8080 reject with tcp reset
check_output "reject with tcp reset: connection refused" '^7$' curl_code outside 198.51.100.1:8080
nft flush chain inet filter input
nft add rule inet filter input tcp dport 8080 drop
check_output "drop: the client waits until its timeout" '^28$' curl_code outside 198.51.100.1:8080
# jump comes back, goto does not: count what reaches the rule after each.
for verb in jump goto; do
  nft flush ruleset
  nft -f - <<NFT
table inet t {
  chain sub { tcp dport 8080 counter; }
  chain in {
    type filter hook input priority 0; policy accept;
    tcp dport 8080 $verb sub
    tcp dport 8080 counter comment "after"
  }
}
NFT
  reach outside 198.51.100.1:8080
  after[$verb]=$(nft list chain inet t in | sed -n 's/.*counter packets \([0-9]*\).*comment "after".*/\1/p')
done
assert_match "after a jump, evaluation continues with the next rule" '^[1-9]' "${after[jump]}"
assert_eq "after a goto, it never comes back" 0 "${after[goto]}"
# accept in one base chain does not stop another base chain on the same hook.
nft flush ruleset
nft -f - <<'NFT'
table inet a { chain c { type filter hook input priority 0; policy accept; tcp dport 8080 accept; }; }
table inet b { chain c { type filter hook input priority 10; policy accept; tcp dport 8080 drop; }; }
NFT
check_fails "accepted in one base chain, dropped by the next one on the hook" reach outside 198.51.100.1:8080
nft flush ruleset

section "Sets and maps"
nft -f /etc/nftables/rules/main.nft
check "anonymous set and named-set changes (from the note)" bash -ec "$(note_block "$NOTE" 'Sets and maps' 1)"
check_fails "the element added then deleted is gone" bash -c "nft list set inet filter trusted | grep -q 172.16.5.0/24"
check "a ban list with a timeout (from the note)" bash -ec "$(note_block "$NOTE" 'Sets and maps' 2)"
check_output "elements expire" '203\.0\.113\.7 (timeout 1h )?expires' nft list set inet filter banned
nft add element inet filter banned '{ 198.51.100.2 }'
check_fails "a banned address is dropped" reach outside 198.51.100.1:443
nft delete element inet filter banned '{ 198.51.100.2 }'
check "a verdict map (from the note)" bash -ec "$(note_block "$NOTE" 'Sets and maps' 3)"
check_output "one rule, three ports" 'tcp dport vmap \{ 22 : jump ssh, 80 : jump web, 443 : jump web \}' nft list chain inet filter input

section "NAT"
nft flush ruleset
sysctl -qw net.ipv4.ip_forward=1
# The note's outside interface is eth0; here it is h-outside.
note_block "$NOTE" NAT 1 | sed 's/eth0/h-outside/g' >nat.nft
check "the NAT table loads (from the note)" nft -f nat.nft
ip netns exec lan ip route replace default via 192.168.1.1
check "masquerade: the LAN host reaches the outside" reach lan 198.51.100.2:9000
check_output "and the outside sees the router's address" 'src=198\.51\.100\.2 dst=198\.51\.100\.1 .*dport=' \
  bash -c 'conntrack -L -p tcp --dport 9000 2>/dev/null'
check "dnat: port 8080 on the router reaches the LAN host's port 80" reach outside 198.51.100.1:8080
nft -f /etc/nftables/rules/main.nft
nft -f nat.nft
check_fails "with the host firewall's forward chain (policy drop), forwarding stops" reach lan 198.51.100.2:9000
nft flush ruleset
sysctl -qw net.ipv4.ip_forward=0

section "Changing rules in place"
nft -f /etc/nftables/rules/main.nft
check_output "nft -a shows the handles" '# handle [0-9]+' nft -a list chain inet filter input
h=$(nft -a list chain inet filter input | sed -n 's/.*tcp dport 443 accept # handle \([0-9]*\)/\1/p')
p=$(nft -a list chain inet filter input | sed -n 's/.*iif "lo" accept # handle \([0-9]*\)/\1/p')
check "delete by handle" nft delete rule inet filter input handle "$h"
check_fails "the rule is gone" bash -c 'nft list chain inet filter input | grep -q "dport 443"'
check "insert before a handle" nft insert rule inet filter input position "$p" tcp dport 8443 accept
check "8443 is now just before the lo rule" \
  bash -c "nft list chain inet filter input | grep -A1 'dport 8443' | tail -1 | grep -q 'iif \"lo\"'"
nft add rule inet filter input tcp dport 9443 accept
check_output "add appends to the end" 'tcp dport 9443 accept' bash -c "nft list chain inet filter input | grep -v '^\s*}' | tail -1"
nft flush ruleset

section "Persistence"
check_output "Leap's nftables.service loads /etc/nftables/rules/main.nft" 'main\.nft' systemctl cat nftables.service
mv /etc/nftables/rules/main.nft /tmp/main.nft
check_output "and does nothing while that file is missing" 'ConditionPathExists=/etc/nftables/rules/main.nft' \
  bash -c 'systemctl start nftables.service; systemctl status nftables.service --no-pager 2>&1; true'
mv /tmp/main.nft /etc/nftables/rules/main.nft
nft -f /etc/nftables/rules/main.nft
check "save and enable on Leap (from the note)" bash -ec "$(note_block "$NOTE" 'Persistence' 1)"
check_output "the saved file starts with flush ruleset" '^flush ruleset$' head -1 /etc/nftables/rules/main.nft
nft flush ruleset
check "systemctl restart restores the ruleset" systemctl restart nftables.service
check_output "the firewall is back" 'tcp dport 443 accept' nft list ruleset
check "reloading twice does not duplicate rules" bash -c 'systemctl reload nftables.service && systemctl reload nftables.service'
check_output "one 443 rule" '^1$' bash -c "nft list ruleset | grep -c 'tcp dport 443 accept'"
check_fails "/etc/nftables.conf is not read on Leap (the correction)" bash -c 'systemctl cat nftables.service | grep -q "/etc/nftables.conf"'

section "Monitoring"
nft flush ruleset
nft monitor >mon.txt 2>&1 &
mon=$!
sleep 1
nft add table inet m
nft add chain inet m c
sleep 1
kill "$mon"
check_output "nft monitor shows the changes" 'add table inet m' cat mon.txt
nft -j monitor chains >monj.txt 2>&1 &
mon=$!
sleep 1
nft add chain inet m d
sleep 1
kill "$mon"
check_output "nft -j monitor chains prints JSON" '"add": \{"chain": \{"family": "inet", "table": "m", "name": "d"' cat monj.txt
check "nft monitor ruleset runs until stopped" bash -c 'timeout 1 nft monitor ruleset; [ $? = 124 ]'
nft -f /etc/nftables/rules/main.nft
check "the counter and trace rules (from the note)" bash -ec "$(note_block "$NOTE" 'Monitoring' 4 | grep -v 'monitor trace')"
nft monitor trace >trace.txt 2>&1 &
mon=$!
sleep 1
reach outside 198.51.100.1:443
sleep 1
kill "$mon"
check_output "nft monitor trace follows the packet" 'trace id .* inet filter input rule tcp dport 443 counter' cat trace.txt
check_output "and the counter counts it" 'tcp dport 443 counter packets [1-9]' nft list chain inet filter input
