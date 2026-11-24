#!/usr/bin/env bash
# note: networking/traffic-visualisation.md
# env: priv:leap
# timeout: 1800
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=networking/traffic-visualisation
# The upstream commits tested here. Neither project has releases.
PCAPVIZ_SHA=a940c9f6b4c2de27645c236598ff094fc3685eec
IPTABLE_VIS_SHA=b89e0ca5e30679c8b350b44879637eff9562cdf6
cd "$(mktemp -d)"
zypper -n -q install --no-recommends tcpdump wireshark git gcc python3-devel \
  iptables python3 curl iproute2 iputils file >/dev/null
# The libraries the note lists for the pygraphviz wheel; and, where pip has to build
# it from source, Graphviz's development files.
zypper -n -q install --no-recommends libX11-6 libXrender1 libXext6 libgobject-2_0-0 graphviz-devel >/dev/null
# uv, for the Python 3.11 environment that blockdiag needs.
python3 -m venv /opt/uv && /opt/uv/bin/pip -q install uv
export PATH=$PATH:/opt/uv/bin

# The note runs as a normal user with sudo; this test runs as root, with no sudo.
block() { note_block "$NOTE" "$@" | sed 's/^sudo //; s/| sudo /| /'; }

# Two clients in network namespaces, so a capture shows more than one conversation.
link() {
  ip netns add "$1"
  ip link add "h-$1" type veth peer name eth0 netns "$1"
  ip addr add "$2.1/24" dev "h-$1" && ip link set "h-$1" up
  ip -n "$1" addr add "$2.2/24" dev eth0
  ip -n "$1" link set eth0 up && ip -n "$1" link set lo up
}
link outside 198.51.100
link lan 192.168.20
for p in 22 80 8080; do python3 -m http.server "$p" >/dev/null 2>&1 & done
sleep 1
# traffic: requests to ports 22 and 80 from both namespaces, and pings, until killed.
traffic() {
  while :; do
    for ns in outside lan; do
      local ip=198.51.100.1
      [[ $ns == lan ]] && ip=192.168.20.1
      ip netns exec "$ns" curl -s -o /dev/null --max-time 1 "http://$ip:22/"
      ip netns exec "$ns" curl -s -o /dev/null --max-time 1 "http://$ip:80/"
      ip netns exec "$ns" ping -c1 -W1 -q "$ip" >/dev/null
    done
    sleep 0.2
  done
}
traffic &
gen=$!

section "Capturing"
# The note captures on eth0. Here the traffic is on the veth interfaces.
line() { block Capturing 1 | sed -n "${1}p" | sed 's/-i eth0/-i h-outside/; s/ *#.*//'; }
timeout 4 bash -c "$(line 1)" >/dev/null 2>&1 || true
check_output "-c 100000 writes a pcap file (from the note)" 'pcap capture file' file capture.pcap
check_output "with packets in it" '^[1-9][0-9]*$' bash -c 'tcpdump -r capture.pcap 2>/dev/null | wc -l'
rm -f capture.pcap
check_output "-G 300 -W 1 is still running after 3 seconds (from the note)" '^124$' \
  bash -c "timeout 3 $(line 2) >/dev/null 2>&1; echo \$?"
check "with -G 2 -W 1, tcpdump stops by itself after one interval" \
  timeout 20 bash -c "$(line 2 | sed 's/-G 300/-G 2/') >/dev/null 2>&1"
mv capture.pcap eth.pcap
timeout 6 bash -c "$(line 3)" >/dev/null 2>&1 || true
check_output "-i any 'not port 22' captures port 80 (from the note)" '^[1-9][0-9]*$' \
  bash -c 'tcpdump -r capture.pcap "tcp port 80" 2>/dev/null | wc -l'
check_output "and leaves out port 22" '^0$' bash -c 'tcpdump -r capture.pcap "tcp port 22" 2>/dev/null | wc -l'
kill "$gen"

section "Generating a graph"
check "git clone (from the note)" bash -ec "$(block 'Generating a graph' 1 | sed -n 1p)"
git -C PcapViz checkout -q "$PCAPVIZ_SHA"
# A capture from one Ethernet interface: --layer2 needs MAC addresses.
cp eth.pcap PcapViz/capture.pcap
cp capture.pcap PcapViz/any.pcap
check "the virtual environment and the requirements install (from the note)" \
  bash -ec "$(block 'Generating a graph' 1 | sed -n '2,/^pip install/p')"
# shellcheck source=/dev/null
. PcapViz/.venv/bin/activate
cd PcapViz
for n in 1 2 3; do
  cmd=$(block 'Generating a graph' 1 | grep '^python main.py' | sed -n "${n}p")
  rm -f topology.png
  check "$cmd (from the note)" bash -ec "$cmd"
  check_output "  it draws a PNG" 'PNG image data' file topology.png
done
check_output "the original --layer 3 is not an option (the correction)" 'error: ambiguous option: --layer could match' \
  bash -c 'python main.py -i capture.pcap -o topology.png --layer 3 2>&1; true'
check_output "--layer2 fails on an -i any capture, which has no MAC header (the warning)" '^Traceback' \
  bash -c 'python main.py -i any.pcap -o any.png --layer2 2>&1; true'
check "--layer3 works on it" python main.py -i any.pcap -o any.png
cd ..
deactivate

section "Reading the result"
check_output "tshark -z conv,ip lists the conversations (from the note)" 'IPv4 Conversations' \
  bash -ec "$(block 'Reading the result' 1 | sed -n 1p)"
check_output "-z endpoints,ip (from the note)" 'IPv4 Endpoints' bash -ec "$(block 'Reading the result' 1 | sed -n 2p)"
check_output "-z io,phs (from the note)" 'Protocol Hierarchy Statistics' bash -ec "$(block 'Reading the result' 1 | sed -n 3p)"
check_output "both client addresses are in the conversations" '192\.168\.20\.2.*192\.168\.20\.1|192\.168\.20\.1.*192\.168\.20\.2' \
  tshark -r capture.pcap -q -z conv,ip

section "iptable_vis"
iptables -N SSHBRUTE
iptables -A SSHBRUTE -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j SSHBRUTE
iptables -A INPUT -p tcp --dport 80 -j DROP
vis=$(block 'iptable_vis' 1)
check "git clone (from the note)" bash -ec "$(sed -n 1p <<<"$vis")"
git -C iptable_vis checkout -q "$IPTABLE_VIS_SHA"
check "a Python 3.11 environment with blockdiag (from the note)" bash -ec "$(sed -n 2,3p <<<"$vis")"
check "iptables -v -L, awk, blockdiag (from the note)" bash -ec ". .venv/bin/activate; $(sed -n '4,$p' <<<"$vis")"
check_output "the SVG has the user chain" 'SSHBRUTE' cat iptables.svg
check_output "and the built-in chains" 'INPUT' cat iptables.svg
check_output "chain_selector keeps only the chains asked for (from the note)" '^0$' \
  bash -c "iptables -v -L | $(sed -n 's/.*`\(awk -f iptable_vis[^`]*\)`.*/\1/p' "$NOTES_ROOT/content/$NOTE.md") | grep -c FORWARD; true"
python3 -m venv plain && plain/bin/pip -q install blockdiag
check_fails "with the current Pillow and setuptools, blockdiag fails (as the note says)" \
  plain/bin/blockdiag iptables.dia -T svg -o plain.svg
check_output "iptables -L INPUT -n -v --line-numbers (from the note)" '^1 .*SSHBRUTE' bash -ec "$(block 'iptable_vis' 2)"

section "Tracing a packet instead"
check "add the TRACE rule (from the note)" bash -ec "$(block 'Tracing' 1 | sed -n 1p)"
mon_cmd=$(block 'Tracing' 1 | sed -n 2p)
$mon_cmd >trace.txt 2>&1 &
mon=$!
sleep 1
ip netns exec outside curl -s -o /dev/null --max-time 2 http://198.51.100.1:8080/
sleep 1
kill "$mon"
check_output "xtables-monitor --trace shows the packet (from the note)" '^PACKET: .*DPORT=8080' cat trace.txt
check_output "and the rules it traverses" 'TRACE: .*filter:INPUT' cat trace.txt
check "remove the TRACE rule (from the note)" bash -ec "$(block 'Tracing' 2)"
check_fails "it is gone" bash -c 'iptables -t raw -S PREROUTING | grep -q TRACE'
