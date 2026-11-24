#!/usr/bin/env bash
# note: servers/chrony.md
# env: leap-systemd
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=servers/chrony
cd "$(mktemp -d)"
zypper -n -q install --no-recommends chrony iproute2 nftables >/dev/null

# The container shares the Docker host's clock: both daemons run with -x, which
# measures but never changes the system clock.
# The server is the container itself (10.88.0.1). The client is a second chronyd in
# a network namespace (10.88.0.2), with its own socket.
ip netns add cl
ip link add h-cl type veth peer name eth0 netns cl
ip addr add 10.88.0.1/24 dev h-cl && ip link set h-cl up
ip -n cl addr add 10.88.0.2/24 dev eth0 && ip -n cl link set eth0 up && ip -n cl link set lo up

section "Configuration files"
check_fails "Leap 16 has no /etc/chrony.conf (the correction)" test -e /etc/chrony.conf
check "the package's file is /usr/etc/chrony.conf" test -f /usr/etc/chrony.conf
check_output "and it reads drop-ins from /etc/chrony.d" '^confdir /etc/chrony.d' cat /usr/etc/chrony.conf

echo 'OPTIONS="-x"' >/etc/sysconfig/chronyd
: >/etc/chrony.d/pool.conf   # same name as the package's pool drop-in: no internet servers
printf 'local stratum 10\nallow 10.88.0.0/24\n' >/etc/chrony.d/lab.conf
systemctl restart chronyd
mkdir -p /run/chrony-cl && chmod 750 /run/chrony-cl && chown chrony: /run/chrony-cl
cat >/etc/chrony-client.conf <<'EOF'
server 10.88.0.1 iburst minpoll 1 maxpoll 1
driftfile /run/chrony-cl/drift
pidfile /run/chrony-cl/chronyd.pid
bindcmdaddress /run/chrony-cl/chronyd.sock
cmdport 0
EOF
ip netns exec cl chronyd -x -f /etc/chrony-client.conf
client() { chronyc -h /run/chrony-cl/chronyd.sock "$@"; }
# words STRING: split a command line from the note into an array, for "${w[@]}".
words() { read -ra w <<<"$1"; }

# cmd HEADING: the command of the console block under HEADING, without "$ " and "chronyc".
cmd() { note_block "$NOTE" "$1" "${2:-1}" | sed -n 's/^\$ chronyc //p' | head -1; }
# out HEADING: the output lines of that console block.
out() { note_block "$NOTE" "$1" "${2:-1}" | sed '1d'; }
# labels HEADING: the "Label :" names in the note's output.
labels() { out "$@" | sed -n 's/^\([A-Za-z][^:]*[^ ]\) *: .*/\1/p'; }
# esc TEXT: TEXT as an extended regular expression that matches it literally.
esc() { printf '%s' "$1" | sed 's/[][\/.^$*+?(){}|]/\\&/g'; }

check "the client reaches the server (Reach 377 after eight polls)" \
  retry 60 bash -c "chronyc -h /run/chrony-cl/chronyd.sock sources | grep -q '10.88.0.1 .* 377 '"

section "Overall service state"
words "$(cmd 'Overall service state')"
act=$(client "${w[@]}")
check_output "chronyc activity (from the note) answers 200 OK" '^200 OK$' printf '%s\n' "$act"
while read -r line; do
  assert_match "activity prints: ${line#* }" "^[0-9]+ $(esc "${line#* }")\$" "$act"
done < <(out 'Overall service state' | sed 1d)
words "$(cmd 'Overall service state' 2)"
stats=$(chronyc "${w[@]}")
while read -r l; do
  assert_match "serverstats prints: $l" "^$(esc "$l") *:" "$stats"
done < <(labels 'Overall service state' 2)
check_output "the server counted the client's NTP packets" '^NTP packets received *: [1-9]' printf '%s\n' "$stats"

section "Source state"
words "$(cmd 'Source state')"
src=$(client "${w[@]}")
for l in "Source mode  '^' = server, '=' = peer, '#' = local clock." \
  "MS Name/IP address         Stratum Poll Reach LastRx Last sample"; do
  assert_match "sources -v prints: $l" "$(esc "$l")" "$src"
done
assert_match "'^*': the server is the current best source" '^\^\* 10\.88\.0\.1 ' "$src"
words "$(cmd 'Source state' 2 | sed 's/node1.cluster.local/10.88.0.1/')"
nd=$(client "${w[@]}")
while read -r l; do
  assert_match "ntpdata prints: $l" "^$(esc "$l") *:" "$nd"
done < <(labels 'Source state' 2)
assert_match "NTP tests is three groups of bits" '^NTP tests +: [01]{3} [01]{3} [01]{4}$' "$nd"
assert_match "all tests passed: no 0" '^NTP tests +: 111 111 1111$' "$nd"
# A filter that drops the server's replies: Reach stops climbing.
ip netns exec cl nft add table ip f
ip netns exec cl nft add chain ip f in '{ type filter hook input priority 0; }'
ip netns exec cl nft add rule ip f in udp sport 123 drop
check "with replies lost, Reach falls below 377" \
  retry 20 bash -c "chronyc -h /run/chrony-cl/chronyd.sock sources | grep '10.88.0.1' | grep -vq ' 377 '"
ip netns exec cl nft delete table ip f

section "Source statistics"
words "$(cmd 'Source statistics')"
ss=$(client "${w[@]}")
assert_match "sourcestats header (from the note)" "^$(esc "$(out 'Source statistics' | sed -n 1p)")\$" "$ss"
assert_match "a row for the server" '^10\.88\.0\.1 +[0-9]+ +[0-9]+ ' "$ss"

section "Client state"
words "$(cmd 'Client state')"
cl=$(chronyc "${w[@]}")
assert_match "clients header (from the note)" "^$(esc "$(out 'Client state' | sed -n 1p)")\$" "$cl"
assert_match "the client's NTP packets are counted" '^10\.88\.0\.2 +[1-9][0-9]* ' "$cl"
sed -i '/^allow/d' /etc/chrony.d/lab.conf
systemctl restart chronyd
sleep 5
check_output "with no allow, the server answers no client (as the note says)" '^NTP packets received *: 0$' chronyc serverstats
check_fails "and the client list stays empty" bash -c "chronyc clients | grep -q 10.88.0.2"
printf 'allow 10.88.0.0/24\n' >>/etc/chrony.d/lab.conf

section "Logs"
check_output "logdir is /var/log/chrony" '^logdir /var/log/chrony$' cat /usr/etc/chrony.conf
check_fails "no log directive by default, so the directory starts empty" bash -c 'ls /var/log/chrony/*.log 2>/dev/null | grep -q .'
check "the drop-in and restart (from the note)" bash -ec "$(note_block "$NOTE" Logs 1)"
check "tracking.log appears" retry 30 test -s /var/log/chrony/tracking.log
# statistics.log has one line per source update. The lab server has no source, so
# check it on the client, with the same log line.
kill "$(cat /run/chrony-cl/chronyd.pid)"
sleep 1
printf 'logdir /run/chrony-cl\n%s\n' "$(cat /etc/chrony.d/log.conf)" >>/etc/chrony-client.conf
ip netns exec cl chronyd -x -f /etc/chrony-client.conf
check "statistics.log appears where there is a source" retry 30 test -s /run/chrony-cl/statistics.log
echo 'log rtc statistics tracking' >/etc/chrony.d/log.conf
systemctl restart chronyd
sleep 3
check_fails "log rtc with rtcsync writes no rtc.log" test -e /var/log/chrony/rtc.log

kill "$(cat /run/chrony-cl/chronyd.pid)"
