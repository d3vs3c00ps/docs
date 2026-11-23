#!/usr/bin/env bash
# note: linux/logging/syslog.md
# env: leap
# A small Python listener plays the collector and keeps the raw messages, so the test
# sees exactly what logger puts on the wire.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/logging/syslog
F=$NOTES_ROOT/content/$NOTE.md
zypper -n -q install --no-recommends util-linux-systemd coreutils-systemd >/dev/null
cd "$(mktemp -d)"
cat >listen.py <<'PY'
import socket, socketserver, sys, threading
out = open(sys.argv[1], "ab", buffering=0)
class T(socketserver.StreamRequestHandler):
    def handle(self):
        for line in self.rfile: out.write(b"tcp " + line)
class U(socketserver.BaseRequestHandler):
    def handle(self): out.write(b"udp " + self.request[0] + b"\n")
socketserver.TCPServer.allow_reuse_address = True
threading.Thread(target=socketserver.TCPServer(("127.0.0.1", 5514), T).serve_forever, daemon=True).start()
socketserver.UDPServer(("127.0.0.1", 5514), U).serve_forever()
PY
python3 listen.py raw.log &
trap 'kill %1 2>/dev/null; _t_finish' EXIT
sleep 1
# The note's logger commands, sent to the listener.
to_local() { sed 's/rsyslog-relay\.internal\.example\.com/127.0.0.1/; s/-P 514/-P 5514/'; }

section "Facility and severity matrix"
# Each row of the PRI table: "name (F) | v0 | ... | v7".
bad=0 rows=0
while IFS='|' read -r _ fac vals; do
  f=$(grep -o '([0-9]*)' <<<"$fac" | tr -d '()')
  s=0
  for v in $(tr '|' ' ' <<<"$vals"); do
    v=${v//\*/}
    ((v == f * 8 + s)) || { bad=$((bad + 1)); echo "# wrong: facility $f severity $s: $v"; }
    s=$((s + 1))
  done
  rows=$((rows + 1))
done < <(grep -E '^\| [a-z0-9]+ \([0-9]+\) \|' "$F")
assert_eq "the PRI table has 24 facilities" 24 "$rows"
assert_eq "every PRI value is facility x 8 + severity" 0 "$bad"
assert_eq "<35> is auth (4) error (3)" 35 $((4 * 8 + 3))
check_output "the 'su' example of RFC3164 has PRI 35" '^<35>Oct 12' grep -o '^<35>Oct 12' "$F"

section "Testing with logger"
check_output "logger has the options of the table" '--rfc5424' bash -c 'logger --help'
for o in -n -T -d -P --rfc3164 --rfc5424 --sd-id --sd-param; do
  assert_match "logger --help lists $o" "(^| )${o}[] ,=[]" "$(logger --help)"
done
# Nobody is logged in to the container: who prints nothing, and logger skips an empty
# message. A prefix keeps it non-empty.
check "RFC3164 over TCP (from the note)" bash -ec "$(note_block "$NOTE" 'Testing with' 1 | to_local | sed 's/"$(who)"/"who: $(who)"/')"
check "RFC5424 with two SD blocks (from the note)" bash -ec "$(note_block "$NOTE" 'Testing with' 3 | to_local)"
sleep 1
raw=$(cat raw.log)
m3164=$(grep -m1 '^tcp <13>[A-Z][a-z][a-z] ' <<<"$raw" || true)
assert_match "RFC3164: PRI <13> (user.notice, logger's default), then a timestamp with no year" \
  '^tcp <13>[A-Z][a-z]{2} [ 0-9]{2} [0-9:]{8} ' "$m3164"
m5424=$(grep -m1 '^tcp <13>1 ' <<<"$raw" || true)
assert_match "RFC5424: version 1 and an ISO 8601 timestamp with the zone" \
  '^tcp <13>1 [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9:]+) ' "$m5424"
assert_match "logger adds its own timeQuality block, then the two given blocks" \
  '\[timeQuality [^]]*\]\[syslog@42 syslog="enabled"\]\[example@123 afk="false"\] Linux FTW' "$m5424"
check "-d sends over UDP" logger -n 127.0.0.1 -d -P 5514 --rfc5424 "over udp"
sleep 1
check_output "the UDP message arrived" '^udp <13>1 .*over udp' cat raw.log
long=$(head -c 3000 /dev/zero | tr '\0' x)
logger -n 127.0.0.1 -T -P 5514 --rfc5424 --size 4000 "$long"
sleep 1
check "RFC5424 carries a message longer than 1024 bytes" bash -c "grep -q 'x\{3000\}' raw.log"

section "Transport"
skip "RELP and RLTP behaviour" "RELP needs rsyslog's relp module and RLTP is syslog-ng Premium Edition; this section is a comparison only"
