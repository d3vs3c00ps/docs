#!/usr/bin/env bash
# note: networking/iptables.md
# env: leap-systemd
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=networking/iptables
cd "$(mktemp -d)"
zypper -n -q install --no-recommends iptables conntrack-tools iputils python3 curl scapy procps >/dev/null

# The container is the host. Clients live in network namespaces, joined to it by veth
# pairs: outside 198.51.100.2 <-> host 198.51.100.1, lan 192.168.20.1 <-> host 192.168.20.2.
link() {
  ip netns add "$1"
  ip link add "h-$1" type veth peer name eth0 netns "$1"
  ip addr add "$2/24" dev "h-$1" && ip link set "h-$1" up
  ip -n "$1" addr add "$3/24" dev eth0
  ip -n "$1" link set eth0 up && ip -n "$1" link set lo up
}
link outside 198.51.100.1 198.51.100.2
link lan 192.168.20.2 192.168.20.1
for p in 22 80 443; do python3 -m http.server "$p" >/dev/null 2>&1 & done
# Port 8080 says who it is, to tell a redirected request from a direct one.
python3 -c 'import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b"port 8080")
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()' &
ip netns exec outside python3 -m http.server 9000 >/dev/null 2>&1 &
sleep 2
# Conntrack starts in a network namespace only when a rule uses it. A host with a
# stateful firewall has it running, so connections are tracked from their first packet.
iptables -t security -A INPUT -m conntrack --ctstate INVALID

block() { note_block "$NOTE" "$@"; }
# reach NS URL: an HTTP request from namespace NS (or "host") succeeds within 2 seconds.
reach() {
  local ns=(ip netns exec "$1")
  [[ $1 == host ]] && ns=()
  "${ns[@]}" curl -s -o /dev/null --max-time 2 "$2"
}
# count CHAIN PATTERN: packet counter of the first rule in CHAIN whose listing matches PATTERN.
count() { iptables -L "$1" -n -v -x | grep -E -- "$2" | head -1 | awk '{ print $1 }'; }
# scapy SPEC: send one packet from the outside namespace, built by scapy.
scapy() { ip netns exec outside python3 -c "from scapy.all import *; conf.verb = 0; send($1)"; }
# reset: the note's clean slate, so each section starts from an empty firewall.
reset() {
  bash -e <<<"$(block 'clean slate' 1; block 'clean slate' 2; block 'clean slate' 3)"
  iptables -t raw -F
}

section "Prerequisites"
check_output "iptables is iptables-nft, as the note says" '\(nf_tables\)' iptables -V
check "enable forwarding for the running system (from the note)" bash -ec "$(block Prerequisites 1 | sed -n 2p)"
check_output "net.ipv4.ip_forward is 1" '^1$' sysctl -n net.ipv4.ip_forward
sysctl -qw net.ipv4.ip_forward=0
# The block ends with `sysctl --system`, which would also apply the distribution's
# kernel-wide settings to the shared Docker host. Load only the note's file.
check "the persistent file (from the note)" bash -ec "$(block Prerequisites 1 | sed -n '/^cat /,/^EOF/p')"
check "sysctl -p on it applies both settings" sysctl -p /etc/sysctl.d/net-forward.conf
check_output "net.ipv4.ip_forward is 1" '^1$' sysctl -n net.ipv4.ip_forward
check_output "net.ipv6.conf.all.forwarding is 1" '^1$' sysctl -n net.ipv6.conf.all.forwarding
printf 'net.ipv4.ip_forward = 1\n' >old.conf && printf 'net.ipv6.conf.all.forwarding = 1\n' >old.conf
check_fails "two '>' to one file keep only the second line (the correction)" grep -q ip_forward old.conf
sysctl -qw net.ipv4.ip_forward=0

section "Starting from a clean slate"
iptables -P INPUT DROP
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -t nat -N JUNK && iptables -t mangle -A PREROUTING -j ACCEPT
check "flushing with policy DROP first (the warning)" iptables -F INPUT
check_fails "then every packet is dropped" reach outside http://198.51.100.1:80/
check "the filter block (from the note)" bash -ec "$(block 'clean slate' 1)"
check "the nat block (from the note)" bash -ec "$(block 'clean slate' 2)"
check "the mangle block (from the note)" bash -ec "$(block 'clean slate' 3)"
check "traffic passes again" reach outside http://198.51.100.1:80/
check_output "filter is empty, all policies ACCEPT" '^-P INPUT ACCEPT -P FORWARD ACCEPT -P OUTPUT ACCEPT $' \
  bash -c 'iptables -S | tr "\n" " "'
check_fails "the nat table has no user chain left" bash -c 'iptables -t nat -S | grep -q JUNK'
check_fails "the mangle table has no rule left" bash -c 'iptables -t mangle -S | grep -q -- -A'

section "A default-deny baseline"
# A connection opened before the policy change: the client sends again 3 seconds later.
client() {
  ip netns exec outside python3 -c '
import socket, time
s = socket.create_connection(("198.51.100.1", 7000), timeout=3)
s.sendall(b"one\n"); s.recv(10); time.sleep(3); s.sendall(b"two\n"); print(s.recv(10).decode())'
}
python3 -c '
import socketserver
class H(socketserver.StreamRequestHandler):
    def handle(self):
        for line in self.rfile: self.wfile.write(line)
socketserver.ThreadingTCPServer.allow_reuse_address = True
socketserver.ThreadingTCPServer(("0.0.0.0", 7000), H).serve_forever()' &
sleep 1
client >without.txt 2>&1 &
c=$!
sleep 1
bash -e <<<"$(block 'default-deny' 1)"
wait "$c" || true
check_fails "policies alone cut an open connection" grep -qx two without.txt
reset
client >with.txt 2>&1 &
c=$!
sleep 1
check "the DROP policies (from the note)" bash -ec "$(block 'default-deny' 1)"
check "the ESTABLISHED,RELATED rules (from the note)" bash -ec "$(block 'default-deny' 2)"
wait "$c" || true
check_output "with them, the open connection keeps working" '^two$' cat with.txt
check_fails "a new connection from outside is dropped" reach outside http://198.51.100.1:80/
check_fails "and the host cannot open a new connection out (OUTPUT is DROP)" reach host http://198.51.100.2:9000/
check_fails "before the loopback rules, 127.0.0.1 is dropped too" reach host http://127.0.0.1:80/
check "the loopback rules (from the note)" bash -ec "$(block 'default-deny' 3)"
check "after them, 127.0.0.1 works" reach host http://127.0.0.1:80/
check_output "-m state is still accepted, as an alias" 'ESTABLISHED' \
  bash -c 'iptables -A INPUT -m state --state ESTABLISHED -j ACCEPT && iptables -S INPUT'
reset

section "Dropping by MAC address"
check "the rule loads (from the note)" bash -ec "$(block 'MAC address' 1)"
check "another MAC address passes" reach outside http://198.51.100.1:80/
ip -n outside link set eth0 address 00:60:56:45:00:08
check_fails "the listed MAC address is dropped" reach outside http://198.51.100.1:80/
ip -n outside link set eth0 address 02:00:00:00:00:02
reset

section "ICMPv4"
iptables -P INPUT DROP
bash -e <<<"$(block 'default-deny' 2 | grep '^iptables ')"
check "the ICMP rules (from the note)" bash -ec "$(block 'ICMPv4' 1)"
check "with policy DROP, ping works" ip netns exec outside ping -c1 -W2 198.51.100.1
check_output "after the ESTABLISHED rule, a fast flood is still limited to 6/s" \
  '50 packets transmitted, [0-9]+ received, [1-9][0-9.]*% packet loss' \
  ip netns exec outside ping -c 50 -i 0.01 -q 198.51.100.1
check_output "echo-request is type 8 (the correction)" 'icmptype 8' iptables -L INPUT -n
reset
iptables -P INPUT DROP
bash -e <<<"$(block 'default-deny' 2 | grep '^iptables ')"
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 6/s -j ACCEPT
check_output "the original -A after the ESTABLISHED rule lets the whole flood through (the correction)" \
  '50 packets transmitted, 50 received' ip netns exec outside ping -c 50 -i 0.01 -q 198.51.100.1
reset

section "ICMPv6"
check "the ICMPv6 rules (from the note)" bash -ec "$(block 'ICMPv6' 1)"
check_output "20 rules" '^20$' bash -c 'ip6tables -S INPUT | grep -c -- "-A INPUT"'
check_output "MLD rules only from link-local addresses" '^-A INPUT -s fe80::/10 -p ipv6-icmp -m icmp6 --icmpv6-type 130 -j ACCEPT$' ip6tables -S INPUT
reset

section "Rate limiting to absorb floods"
check "the DDOS chain (from the note)" bash -ec "$(for i in 1 2 3 4 5; do block 'Rate limiting' "$i"; done)"
# requests N: how many of N requests to port 80 succeed.
requests() {
  local ok=0
  for _ in $(seq "$1"); do reach outside http://198.51.100.1:80/ && ok=$((ok + 1)); done
  echo "$ok"
}
ok=$(requests 30)
assert_match "alone, 30 requests (under the burst of 60) are not all accepted: it counts packets ($ok passed)" \
  '^([0-9]|[12][0-9])$' "$ok"
check_output "the DROP rule of the chain counted packets" '^[1-9]' count DDOS 'DROP'
reset
bash -e <<<"$(block 'default-deny' 2 | grep '^iptables ' | grep INPUT)"
bash -e <<<"$(for i in 1 2 3 4 5; do block 'Rate limiting' "$i"; done)"
assert_eq "after the ESTABLISHED rule, all 30 pass: only new connections are counted" 30 "$(requests 30)"
reset

section "A chain dedicated to logging"
check "the logging chains (from the note)" bash -ec "$(block 'logging' 1)"
check_output "INPUT ends with the jump to DROP_INPUT" '^-A INPUT -j DROP_INPUT$' bash -c 'iptables -S INPUT | tail -1'
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
check_fails "a rule appended after the jump is never reached (the warning)" reach outside http://198.51.100.1:80/
assert_eq "its counter stays at 0" 0 "$(count INPUT 'dpt:80')"
iptables -D INPUT -p tcp --dport 80 -j ACCEPT
check "the limited LOG rule replaces rule 1 (from the note)" bash -ec "$(block 'logging' 2)"
check_output "rule 1 is now the limited LOG rule" '^-A DROP_INPUT -m limit --limit 5/min --limit-burst 10 -j LOG' \
  bash -c 'iptables -S DROP_INPUT | sed -n 2p'
check_output "the chain still has two rules, LOG then DROP" '^2$' bash -c 'iptables -S DROP_INPUT | grep -c -- "-A DROP_INPUT"'
iptables -A DROP_INPUT -m limit --limit 5/m -j LOG
check_output "the original -A put the limited rule after DROP, where it never runs" '^-A DROP_INPUT -m limit .* -j LOG$' \
  bash -c 'iptables -S DROP_INPUT | tail -1'
reset

section "Common attacks"
attacks=$(for h in 'NULL packets' 'XMAS scan' 'FIN scan' 'not starting with a SYN' 'Empty UDP' 'DNS amplification' \
  'Broadcast packets' 'Malformed' 'broadcast, multicast' 'SSH brute' 'ICMP flooding'; do
  n=1
  # The probe that ends the loop misses on purpose: keep it out of the missing-block report.
  while _T_NB_MISSING='' block "$h" "$n" >/dev/null 2>&1; do block "$h" "$n"; n=$((n + 1)); done
done)
check "every block of the section loads" bash -ec "$attacks"
reset

for n in 1 2; do block 'NULL packets' "$n"; done | bash -e
check "the blacklist check rule (from the note)" bash -ec "$(block 'NULL packets' 3)"
check "a normal request passes" reach outside http://198.51.100.1:80/
scapy 'IP(dst="198.51.100.1")/TCP(dport=80, flags="")'
check_output "a NULL packet is logged" '^[1-9]' count INPUT 'Null scan'
check_output "its source is in blacklist_60" 'src=198\.51\.100\.2' cat /proc/net/xt_recent/blacklist_60
check_fails "and is now blocked, also for normal requests" reach outside http://198.51.100.1:80/
echo / >/proc/net/xt_recent/blacklist_60
check "after the list is cleared, it passes again" reach outside http://198.51.100.1:80/
reset

for n in 1 2; do block 'XMAS scan' "$n"; done | bash -e
block 'FIN scan' 1 | bash -e
scapy 'IP(dst="198.51.100.1")/TCP(dport=80, flags="FPU")'
check_output "an nmap -sX packet (FIN,PSH,URG) hits the Xmas scan rule" '^[1-9]' count INPUT 'prefix "\[DROP_INPUT - Xmas scan\] "'
scapy 'IP(dst="198.51.100.1")/TCP(dport=80, flags="F")'
check_output "a lone FIN hits the FIN scan rule" '^[1-9]' count INPUT 'prefix "\[DROP_INPUT - FIN scan\] "'
reset

block 'not starting with a SYN' 1 | bash -e
scapy 'IP(dst="198.51.100.1")/TCP(dport=80, flags="A")'
check_output "an ACK with no connection is NEW, not SYN: dropped" '^[1-9]' count INPUT 'not starting with SYN'
check "a real connection passes" reach outside http://198.51.100.1:80/
reset

block 'Empty UDP' 1 | bash -e
scapy 'IP(dst="198.51.100.1")/UDP(dport=5000)'
check_output "an empty UDP packet (28 bytes) is dropped" '^[1-9]' count INPUT 'empty UDP'
scapy 'IP(dst="198.51.100.1")/UDP(dport=5000)/Raw(b"x")'
assert_eq "a UDP packet with one byte of data is not" 1 "$(count INPUT 'empty UDP')"
reset

block 'DNS amplification' 1 | bash -e
any() { scapy "IP(dst=\"198.51.100.1\")/UDP(dport=53)/DNS(rd=1, qd=DNSQR(qname=\"$1\", qtype=\"ALL\"))"; }
any isc.org
check_output "an ANY query for a short name is recorded (--from 40)" '^1$' count INPUT 'recent: SET name: dnsanyquery'
assert_eq "the first query is not dropped (--hitcount 2, the correction)" 0 "$(count INPUT 'DNS amplification')"
any www.example.com
assert_eq "a second one within 10 seconds is dropped" 1 "$(count INPUT 'DNS amplification')"
scapy 'IP(dst="198.51.100.1")/UDP(dport=53)/DNS(rd=1, qd=DNSQR(qname="isc.org", qtype="A"))'
assert_eq "an A query is not counted" 2 "$(count INPUT 'recent: SET name: dnsanyquery')"
iptables -F INPUT
bash -e <<<"$(block 'DNS amplification' 1 | sed 's/--hitcount 2/--hitcount 1/')"
any isc.org
assert_eq "with the original --hitcount 1, even the first query is dropped" 1 "$(count INPUT 'DNS amplification')"
iptables -F INPUT
iptables -A INPUT -p udp --dport 53 -m string --from 50 --algo bm --hex-string '|0000FF0001|'
any isc.org
assert_eq "with the original --from 50, isc.org ANY does not match (the correction)" 0 "$(count INPUT 'FROM 50')"
reset

block 'Broadcast packets' 1 | bash -e
ip netns exec outside python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.sendto(b"x", ("198.51.100.255", 5000))'
check_output "a broadcast packet is dropped" '^[1-9]' count INPUT 'PKTTYPE = broadcast'
reset

block 'Malformed' 1 | bash -e
check_output "INVALID is matched by conntrack" 'ctstate INVALID' iptables -S INPUT
reset

block 'broadcast, multicast' 1 | bash -e
check_output "addrtype accepts ANYCAST" 'dst-type ANYCAST' iptables -S INPUT
reset

block 'SSH brute' 1 | bash -e
res=""
for i in 1 2 3 4 5 6; do
  if reach outside http://198.51.100.1:22/; then res+="$i:ok "; else res+="$i:drop "; fi
done
assert_eq "four connections pass, the fifth and later are dropped (the correction)" \
  "1:ok 2:ok 3:ok 4:ok 5:drop 6:drop " "$res"
reset

block 'SSH brute' 2 | bash -e
# Hold N connections open from the outside namespace, then try one more.
hold() {
  ip netns exec outside python3 -c '
import socket, sys
port, n = int(sys.argv[1]), int(sys.argv[2])
held = [socket.create_connection(("198.51.100.1", port), timeout=2) for _ in range(n)]
try:
    socket.create_connection(("198.51.100.1", port), timeout=2); print("accepted")
except ConnectionRefusedError: print("refused")
except OSError: print("dropped")' "$@"
}
check_output "connlimit: with 5 connections open, a 6th is rejected" '^refused$' hold 22 5
check_output "with 4 open, a 5th is accepted" '^accepted$' hold 22 4
reset

bash -e <<<"$(block 'default-deny' 2 | grep INPUT)"
block 'ICMP flooding' 1 | bash -e
check "6 pings at a normal pace pass" ip netns exec outside ping -c 6 -i 0.3 -q 198.51.100.1
sleep 2
check_output "with the ESTABLISHED rule in place, a flood of pings is cut" '30 packets transmitted, [0-9]+ received, [1-9][0-9.]*% packet loss' \
  ip netns exec outside ping -c 30 -i 0.01 -q 198.51.100.1
check_output "the IPv6 jump is the first rule, on echo requests (type 128)" '^ICMPFLOODIPV6 .*ipv6-icmptype 128' \
  bash -c 'ip6tables -L INPUT -n | sed -n 3p'
iptables -D INPUT 1
iptables -A INPUT -p icmp --icmp-type 8 -m conntrack --ctstate NEW -j ICMPFLOOD
sleep 2
check_output "the original --ctstate NEW jump, after the ESTABLISHED rule, lets the flood through (the correction)" \
  '30 packets transmitted, 30 received' ip netns exec outside ping -c 30 -i 0.01 -q 198.51.100.1
reset

section "Matching several ports at once"
check "multiport (from the note)" bash -ec "$(block 'several ports' 1)"
check "a range is accepted too" iptables -A INPUT -p tcp -m multiport --dports 6000:6010 -j ACCEPT
check_fails "more than 15 ports are refused" iptables -A INPUT -p tcp -m multiport --dports 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16 -j ACCEPT
reset

section "Port redirection"
check_fails "before the rule, port 80 answers itself" bash -c 'ip netns exec lan curl -s --max-time 2 http://192.168.20.2:80/ | grep -q "port 8080"'
check "the REDIRECT rule (from the note)" bash -ec "$(block 'Port redirection' 1)"
check_output "port 80 on 192.168.20.2 is answered by port 8080" '^port 8080$' \
  ip netns exec lan curl -s --max-time 2 http://192.168.20.2:80/
reset

section "Persistence"
bash -e <<<"$(block 'logging' 1)"
ip6tables -A INPUT -p tcp --dport 443 -j ACCEPT
check_fails "/etc/iptables does not exist on Leap by default" test -d /etc/iptables
check "save the rules (from the note)" bash -ec "$(block Persistence 1)"
check_output "rules.v4 has the chains" ':DROP_INPUT' cat /etc/iptables/rules.v4
check_output "rules.v6 has the IPv6 rule" 'dport 443' cat /etc/iptables/rules.v6
block Persistence 2 | sed -n '2,$p' >/etc/systemd/system/iptables-restore.service
check_output "the unit's first line names its path" '^# /etc/systemd/system/iptables-restore.service$' block Persistence 2
check "systemd-analyze verify accepts the unit" systemd-analyze verify /etc/systemd/system/iptables-restore.service
check "the restore commands are at the paths the unit uses" test -x /usr/sbin/iptables-restore -a -x /usr/sbin/ip6tables-restore
reset
ip6tables -F
systemctl daemon-reload
check "systemctl enable --now runs it" systemctl enable --now iptables-restore.service
check_output "the IPv4 rules are back" '^-A INPUT -j DROP_INPUT$' iptables -S INPUT
check_output "the IPv6 rules are back" 'dport 443' ip6tables -S INPUT
check_output "it is wanted by multi-user.target" 'iptables-restore.service' \
  bash -c 'ls /etc/systemd/system/multi-user.target.wants/'
reset
check "restore by hand (from the note)" bash -ec "$(block Persistence 4)"
check_output "the rules are back" 'DROP_INPUT' iptables -S INPUT
reset

section "Commands that save time"
check_output "list all rules (from the note)" 'Chain INPUT' bash -ec "$(block 'save time' 1)"
for i in $(seq 45); do iptables -A INPUT -p tcp --dport "$((10000 + i))" -j ACCEPT; done
check_output "--line-numbers numbers each rule" '^42 ' iptables -L INPUT -n -v --line-numbers
check "delete rule 42 (from the note)" bash -ec "$(block 'save time' 2)"
check_fails "port 10042 is gone" bash -c 'iptables -S INPUT | grep -q "dport 10042 "'
check_output "and port 10043 is now line 42" '^42 .*dpt:10043' iptables -L INPUT -n --line-numbers
check "insert at line 2 (from the note)" bash -ec "$(block 'save time' 3)"
check_output "the new rule is line 2" '^2 +DROP +all +-- +192\.168\.1\.1 ' iptables -L INPUT -n --line-numbers
check_output "the old line 2 is now line 3" '^3 .*dpt:10002' iptables -L INPUT -n --line-numbers
# watch needs a terminal: script gives it one.
check "watch runs until stopped (from the note)" \
  bash -c "TERM=xterm script -qec \"timeout 2 $(block 'save time' 4)\" /dev/null >/dev/null; [ \$? = 124 ]"
reach outside http://198.51.100.1:10001/ || true
check_output "counters are not zero before -Z" ' [1-9][0-9]* +[0-9]+ +ACCEPT' iptables -L INPUT -n -v
check "zero the counters (from the note)" bash -ec "$(block 'save time' 5)"
check_fails "all counters are 0 after -Z" bash -c "iptables -L INPUT -n -v -x | awk 'NR > 2 && \$1 != 0' | grep -q ."
reset
