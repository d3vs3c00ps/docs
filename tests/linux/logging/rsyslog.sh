#!/usr/bin/env bash
# note: linux/logging/rsyslog.md
# env: leap-systemd
# timeout: 1500
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/logging/rsyslog
W=$(mktemp -d)
cd "$W"
zypper -n -q install --no-recommends rsyslog rsyslog-module-relp iptables util-linux-systemd >/dev/null
# An Ubuntu CI host's AppArmor profile for /usr/sbin/rsyslogd also applies in this privileged
# container and denies the test's files. A copy at another path is the same binary, unconfined.
install -m 755 /usr/sbin/rsyslogd /usr/local/sbin/rsyslogd
export PATH=/usr/local/sbin:$PATH

# The note's hosts, each on its own loopback address, so that several rsyslog
# instances ("machines") can listen on the same port in one container.
cat >>/etc/hosts <<'EOF'
127.0.0.2 rsyslog-relay-01.internal.example.com
127.0.0.3 rsyslog-relay-02.internal.example.com
127.0.0.4 rsyslog-collector-01.internal.example.com
127.0.0.5 siem.internal.example.com
EOF

# block NAME HEADING [N]: write a note block to NAME.conf and print the path.
block() {
  note_block "$NOTE" "$2" "${3:-1}" >"$W/$1.conf"
  echo "$W/$1.conf"
}
# valid FILE: rsyslog accepts the configuration (-N1 checks it and exits).
valid() { rsyslogd -N1 -f "$1" >"$1.check" 2>&1 && ! grep -qi 'error' "$1.check"; }

# start NAME FILE [ADDR]: run FILE as a separate rsyslog "machine" called NAME.
# Its spool directory and state are its own. ADDR binds its RELP and TCP listeners to
# one loopback address, as if it were its own host.
start() {
  local name=$1 f=$2 addr=${3:-}
  mkdir -p "$W/$name/spool"
  {
    printf 'global(workDirectory="%s")\n' "$W/$name"
    sed "s|/var/spool/rsyslog|$W/$name/spool|g" "$f"
  } >"$W/$name.run"
  [[ -n $addr ]] && sed -i -E "s/(input\\(type=\"im(relp|tcp|ptcp)\")/\\1 address=\"$addr\"/" "$W/$name.run"
  if ! rsyslogd -N1 -f "$W/$name.run" >"$W/$name.err" 2>&1; then
    echo "# instance $name: rsyslog rejects its configuration:"
    sed 's/^/#   /' "$W/$name.err"
    return 1
  fi
  rsyslogd -f "$W/$name.run" -i "$W/$name.pid" 2>>"$W/$name.err"
  retry 10 test -s "$W/$name.pid"
}
stop() {
  [[ -s $W/$1.pid ]] || return 0
  kill "$(cat "$W/$1.pid")" 2>/dev/null || true
  retry 15 bash -c "! kill -0 $(cat "$W/$1.pid") 2>/dev/null" || true
  rm -f "$W/$1.pid"
}
# with_input FILE PORT: add a local TCP input, to inject test messages into FILE's
# default ruleset. Not part of the note: the note's sources are machines with logs.
with_input() {
  grep -q 'load="imtcp"' "$1" || printf 'module(load="imtcp")\n' >>"$1"
  printf 'input(type="imtcp" address="127.0.0.1" port="%s")\n' "$2" >>"$1"
}
# say PORT TEXT [ADDR]: send a message over TCP. Retried: an instance just started may
# not listen yet.
say() { retry 10 logger --tcp --server "${3:-127.0.0.1}" --port "$1" -t test "$2"; }
# raw PROTO PORT FRAME: send a hand-made syslog frame.
raw() { retry 10 bash -c 'printf "%b" "$3" >"/dev/$1/127.0.0.1/$2"' _ "$@"; }
has() { retry "${3:-20}" grep -q -- "$2" "$1"; }

section "Configuration formats"
check "basic: mail.err @@server" valid "$(block f1 'Configuration formats' 1)"
check "advanced: omfwd to a target over TCP" valid "$(block f2 'Configuration formats' 2)"
check "advanced with a queue" valid "$(block f3 'Configuration formats' 3)"
printf 'mail.err action(type="omfwd" protocol="tcp")\n' >nf.conf
check_output "an omfwd action with no target is refused (the old block)" "either target or targetSrv must be specified|parameter 'target' required" \
  bash -c 'rsyslogd -N1 -f nf.conf 2>&1; true'
check "basic: mail.info to a file" valid "$(block f4 'Configuration formats' 4)"
check "advanced: the same with prifilt" valid "$(block f5 'Configuration formats' 5)"
f=$(block f6 'Configuration formats' 6) && printf '$InputTCPServerRun 5999\nmail.* /dev/null\n' >>"$f"
check "legacy \$ModLoad and \$InputTCPMaxSessions" valid "$f"
printf '$ModLoad imtcp\n$InputTCPMaxSession 500\n' >typo.conf
check_output "the old spelling \$InputTCPMaxSession is unknown" "unknown config file command 'InputTCPMaxSession'" \
  bash -c 'rsyslogd -N1 -f typo.conf 2>&1; true'
# rsyslog -N1 fails when a module has no listener, so give each an input.
f=$(block f7 'Configuration formats' 7) && printf 'input(type="imtcp" port="5999")\nmail.* /dev/null\n' >>"$f"
check "module(load=\"imtcp\" maxSessions=\"500\")" valid "$f"

cat >at.conf <<'EOF'
module(load="imtcp")
input(type="imtcp" address="127.0.0.1" port="5000")
*.* @127.0.0.5:5514
*.* @@127.0.0.5:5515
EOF
cat >at-rx.conf <<'EOF'
module(load="imudp")
module(load="imtcp")
input(type="imudp" port="5514" ruleset="udp")
input(type="imtcp" port="5515" ruleset="tcp")
ruleset(name="udp") { action(type="omfile" file="/var/log/at-udp") }
ruleset(name="tcp") { action(type="omfile" file="/var/log/at-tcp") }
EOF
start at-rx at-rx.conf 127.0.0.5 && start at at.conf
say 5000 "which transport"
check "@ sends over UDP" has /var/log/at-udp "which transport"
check "@@ sends over TCP" has /var/log/at-tcp "which transport"
stop at; stop at-rx

section "Queues"
check "the collector forwarding block (Sizing)" valid "$(block q1 'Sizing' 1)"
# Nothing listens on relay-01: the disk queue keeps the messages.
f=$(block q2 'Forwarding to a relay' 2)
with_input "$f" 5001
start disk "$f"
for i in 1 2 3; do say 5001 "queued $i"; done
check "queue.type=\"Disk\" writes to disk while the target is down" retry 20 bash -c "ls $W/disk/spool/forwarding.* >/dev/null 2>&1"
check_output "chunk files: queue.filename plus an 8-digit number" '^forwarding\.00000001$' \
  bash -c "ls $W/disk/spool | grep '^forwarding\.[0-9]'"
stop disk
f=$(block q3 'Sizing' 1)
with_input "$f" 5002
start da "$f"
for i in 1 2 3; do say 5002 "in memory $i"; done
sleep 3
check_fails "a LinkedList queue with a filename keeps them in memory, not on disk" \
  bash -c "ls $W/da/forwarding.0* $W/da/spool/forwarding.0* 2>/dev/null | grep -q ."
stop da

section "Parsers"
cat >parse.conf <<'CONF'
module(load="imtcp")
input(type="imtcp" address="127.0.0.1" port="5012")
template(name="p" type="string" string="%app-name%|%msg%\n")
*.* action(type="omfile" file="/var/log/parsed" template="p")
CONF
start parse parse.conf
raw tcp 5012 '<13>1 2026-09-26T10:00:00Z host myapp 1 - - version one\n'
raw tcp 5012 '<13>2 2026-09-26T10:00:00Z host myapp 1 - - version two\n'
check_output "VERSION 1: parsed as RFC5424, APP-NAME myapp" '^myapp\|version one$' bash -c 'sleep 2; cat /var/log/parsed'
check_fails "VERSION 2: not parsed as RFC5424 (the flog warning)" grep -q '^myapp|version two$' /var/log/parsed
stop parse

section "Tags"
cat >tag.conf <<'EOF'
module(load="imtcp")
input(type="imtcp" address="127.0.0.1" port="5003")
template(name="t" type="list") { property(name="syslogtag") constant(value="|") property(name="programname") constant(value="|") property(name="msg") constant(value="\n") }
*.* action(type="omfile" file="/var/log/tags" template="t")
EOF
start tag tag.conf
raw tcp 5003 '<13>Sep 26 10:00:00 host named[12345]: zone loaded\n'
raw tcp 5003 '<13>Sep 26 10:00:00 host systemd-journald[99]: dashed\n'
raw tcp 5003 '<13>Sep 26 10:00:00 host my.app/v2: dotted\n'
raw tcp 5003 '<13>Sep 26 10:00:00 host abcdefghijklmnopqrstuvwxyz0123456789ABCD: long\n'
check_output "named[12345]: TAG named[12345]:, programname named" '^named\[12345\]:\|named\| zone loaded' \
  bash -c 'sleep 2; cat /var/log/tags'
check_output "a dash does not end TAG (the note said any non-alphanumeric does)" '^systemd-journald\[99\]:\|systemd-journald\|' cat /var/log/tags
check_output "nor do . and /; programname stops at /" '^my\.app/v2:\|my\.app\|' cat /var/log/tags
check_output "a 40-character tag is kept whole" '^abcdefghijklmnopqrstuvwxyz0123456789ABCD:\|' cat /var/log/tags
stop tag

section "Rulesets"
check "a ruleset bound to an input (from the note)" valid "$(block r1 'Rulesets' 2)"
f=$(block r2 'Rulesets' 3)
check "one ruleset per listener (from the note)" valid "$f"
start rs "$f"
say 10514 "to 10514"
retry 10 logger --tcp --server 127.0.0.1 --port 10516 -p mail.info -t test "mail to 10516"
retry 10 logger --tcp --server 127.0.0.1 --port 10516 -p user.info -t test "user to 10516"
check "port 10514 goes to its file" has /var/log/remote10514 "to 10514"
check "mail on 10516 goes to its own file" has /var/log/mail10516 "mail to 10516"
check "other messages on 10516 go to the port's file" has /var/log/remote10516 "user to 10516"
check_fails "stop keeps the mail message out of the port's file" grep -q "mail to 10516" /var/log/remote10516
stop rs
f=$(block r3 'Rulesets' 4) && sed -i 's|# \.\.\.|action(type="omfile" file="/dev/null")|' "$f" && echo '*.* call whatever' >>"$f"
check "a ruleset with its own queue" valid "$f"
check "stop after an action (from the note)" valid "$(block r4 'Rulesets' 5)"

section "Properties"
cat >prop.conf <<'EOF'
module(load="imtcp")
input(type="imtcp" address="127.0.0.1" port="5004")
template(name="p" type="string" string="%hostname%|%fromhost%|%fromhost-ip%|%$now%\n")
*.* action(type="omfile" file="/var/log/props" template="p")
EOF
start prop prop.conf
raw tcp 5004 '<13>Sep 26 10:00:00 claimed-host app: hi\n'
check_output "hostname is what the sender claims, fromhost who connected" \
  '^claimed-host\|(localhost|127\.0\.0\.1)\|127\.0\.0\.1\|[0-9]{4}-[0-9]{2}-[0-9]{2}$' bash -c 'sleep 2; cat /var/log/props'
stop prop

section "Templates"
# The note shows the definitions of the built-in templates. Render one message with
# the built-in and with the note's copy (renamed), and compare.
# Block 6 is the JSON one, not a built-in: it is checked on its own below.
names=(RSYSLOG_TraditionalFileFormat RSYSLOG_TraditionalForwardFormat RSYSLOG_FileFormat
  RSYSLOG_ForwardFormat RSYSLOG_SyslogProtocol23Format json RSYSLOG_DebugFormat)
{
  echo 'module(load="imtcp")'
  echo 'input(type="imtcp" address="127.0.0.1" port="5005")'
  for i in "${!names[@]}"; do
    note_block "$NOTE" Templates "$((i + 1))" | sed "s/name=\"${names[$i]}\"/name=\"note_$i\"/"
    [[ ${names[$i]} == json ]] || echo "*.* action(type=\"omfile\" file=\"$W/tpl-builtin-$i\" template=\"${names[$i]}\")"
    echo "*.* action(type=\"omfile\" file=\"$W/tpl-note-$i\" template=\"note_$i\")"
  done
  echo "*.* action(type=\"omfile\" file=\"$W/tpl-5424\" template=\"RSYSLOG_SyslogRFC5424Format\")"
} >tpl.conf
start tpl tpl.conf
raw tcp 5005 '<165>1 2026-09-26T10:00:00.123456+02:00 host.example.com app 42 ID47 [ex@32473 k="v"] a message\n'
sleep 3
for i in "${!names[@]}"; do
  [[ ${names[$i]} == json ]] && continue
  check "the note's ${names[$i]} matches the built-in" cmp -s "$W/tpl-builtin-$i" "$W/tpl-note-$i"
done
check_output "the note's JSON template writes valid JSON" '^a message$' \
  python3 -c "import json,sys; print(json.load(open('$W/tpl-note-5'))['message'])"
for n in RSYSLOG_StdJSONFmt StdJSONFmt; do
  printf '*.* action(type="omfile" file="/dev/null" template="%s")\n' "$n" >json-$n.conf
  check_output "template=\"$n\" is not found" 'Could not find template' bash -c "rsyslogd -N1 -f json-$n.conf 2>&1; true"
done
check_output "RSYSLOG_SyslogRFC5424Format is a built-in too" '^<165>1 2026-09-26T10:00:00\.123456\+02:00 host\.example\.com app 42 ID47 ' cat "$W/tpl-5424"
check_output "SyslogProtocol23Format writes RFC5424" '^<165>1 2026-09-26T10:00:00\.123456\+02:00 host\.example\.com app 42 ID47 \[ex@32473 k="v"\] a message$' cat "$W/tpl-builtin-4"
stop tpl
printf 'template(name="RSYSLOG_Mine" type="string" string="x")\n*.* action(type="omfile" file="/dev/null" template="RSYSLOG_Mine")\n' >res.conf
check "the RSYSLOG_ prefix is reserved only by convention: RSYSLOG_Mine is accepted" valid res.conf

section "call"
f=$(block c1 'call' 2)
check "the chaining example (from the note)" valid "$f"
start call "$f"
say 514 "through rs2 and rs1"
check "a message on 514 lands in rs2's file" has /var/log/test2.log "through rs2 and rs1"
check "and, through call, in rs1's file" has /var/log/test1.log "through rs2 and rs1"
stop call

section "Conditions"
f=$(block cond Conditions 1)
check "the conditions block (from the note)" valid "$f"

section "Handling multi-line messages"
cat >ml.conf <<'CONF'
module(load="imtcp")
input(type="imtcp" address="127.0.0.1" port="5006")
template(name="m" type="string" string="%msg%\n")
*.* action(type="omfile" file="/var/log/multiline" template="m")
CONF
# One message with a newline inside: octet-counted framing, "<length> <message>".
multiline() { local m=$'<13>Sep 26 10:00:00 host app: first line\nsecond line'; raw tcp 5006 "${#m} $m"; }
start ml ml.conf
multiline
check "by default a newline in a message is escaped to #012" has /var/log/multiline 'first line#012second line'
stop ml
: >/var/log/multiline
cat "$(block ml1 'multi-line' 1)" ml.conf >ml-off.conf
start mloff ml-off.conf
multiline
check "with parser.escapeControlCharactersOnReceive=off it is kept" \
  retry 20 bash -c "grep -q '^second line' /var/log/multiline"
stop mloff
cat >ml-udp.conf <<'CONF'
module(load="imudp")
input(type="imudp" address="127.0.0.1" port="5011")
template(name="m" type="string" string="[%msg%]\n")
*.* action(type="omfile" file="/var/log/multiline-udp" template="m")
CONF
start mludp ml-udp.conf
raw udp 5011 '<13>Sep 26 10:00:00 host app: first line\nsecond line'
check_output "over UDP the newline splits the datagram into two messages" '^\[ first line\]$' \
  bash -c 'sleep 2; cat /var/log/multiline-udp'
stop mludp
f=$(block ml2 'multi-line' 2) && echo '*.* /dev/null' >>"$f"
check "the legacy spelling is still accepted" valid "$f"

section "Configuring a simple collector"
f=$(block col 'simple collector' 1)
start col "$f"
say 514 "to the collector"
check_output "the collector writes RFC5424 to /var/log/remotefile" '^<[0-9]+>1 .* test .*to the collector$' \
  bash -c 'sleep 2; cat /var/log/remotefile'
stop col

section "Forwarding to a relay or collector"
check "the simplest omfwd action" valid "$(block fw1 'Forwarding to a relay' 1)"
check "with retries and a disk queue" valid "$(block fw2 'Forwarding to a relay' 2)"

section "Using RELP"
check "Leap: zypper install rsyslog-module-relp (from the note)" rpm -q rsyslog-module-relp
: >/var/log/remotefile
srv=$(block relp-srv 'Using RELP' 2)
cli=$(block relp-cli 'Using RELP' 3)
with_input "$cli" 5007
start relp-srv "$srv" 127.0.0.2 && start relp-cli "$cli"
say 5007 "over RELP"
check "the RELP client delivers to the RELP server" has /var/log/remotefile "over RELP"
stop relp-cli; stop relp-srv
printf 'module(load="omrelp")\n*.* action(type="omrelp" target="x" port="2514" protocol="tcp")\n' >relp-proto.conf
check_output "omrelp has no protocol parameter" "parameter 'protocol' not known" bash -c 'rsyslogd -N1 -f relp-proto.conf 2>&1; true'

section "Failover"
f=$(block fo1 Failover 1)
check "failover with successive actions (from the note)" valid "$f"
# Two relays, a RELP receiver on each address, writing to its own file.
relay_rx() {
  printf 'module(load="imrelp")\ninput(type="imrelp" port="2514" ruleset="r")\nruleset(name="r") { action(type="omfile" file="/var/log/at-%s") }\n' "$1" >"rx-$1.conf"
  start "rx-$1" "rx-$1.conf" "$2"
}
f=$(block fo2 Failover 2)
with_input "$f" 5008
relay_rx relay01 127.0.0.2 && relay_rx relay02 127.0.0.3 && start fo "$f"
say 5008 "both relays up"
check "relay-01 gets the message while it is up" has /var/log/at-relay01 "both relays up"
check_fails "relay-02 does not" grep -q "both relays up" /var/log/at-relay02
stop rx-relay01
say 5008 "in flight"
sleep 1
say 5008 "relay-01 down"
check "relay-01 down: relay-02 gets the next messages" has /var/log/at-relay02 "relay-01 down" 30
sleep 3
check_fails "the message in flight when relay-01 stopped is lost (the note's warning)" \
  grep -rq "in flight" /var/log/at-relay01 /var/log/at-relay02 "$W/fo/spool"
stop rx-relay02
say 5008 "in flight 2"   # lost too, like the first one
sleep 1
say 5008 "both down"
check "both down: the local buffer file gets it" has "$W/fo/spool/localbuffer" "both down" 60
stop fo
# The callout: a queue on the first action hides its failure from the next one.
cat >aq.conf <<'EOF'
module(load="omrelp")
*.* action(type="omrelp" target="rsyslog-relay-01.internal.example.com" port="2514" queue.type="LinkedList")
*.* action(type="omfile" file="/var/log/aq-buffer" action.execOnlyWhenPreviousIsSuspended="on")
EOF
with_input aq.conf 5009
start aq aq.conf
say 5009 "queued first action"
sleep 10
check_fails "with a queue on the first action, the failover action never runs" grep -q "queued first action" /var/log/aq-buffer
stop aq

section "Relays"
: >/var/log/at-siem
printf 'module(load="imtcp")\ninput(type="imtcp" port="514" ruleset="r")\nruleset(name="r") { action(type="omfile" file="/var/log/at-siem") }\n' >siem.conf
f=$(block relay Relays 1)
check "the relay block" valid "$f"
g=$(block collector Relays 2)
check "the collector block" valid "$g"
printf 'module(load="omfwd")\n*.* action(type="omfwd" target="x" port="514")\n' >omfwd.conf
check_output "module(load=\"omfwd\") fails: omfwd is built in (the correction)" "could not load module 'omfwd'" \
  bash -c 'rsyslogd -N1 -f omfwd.conf 2>&1; true'
src=$(block src Failover 2)
with_input "$src" 5010
start siem siem.conf 127.0.0.5 && start collector "$g" 127.0.0.4 && start relay "$f" 127.0.0.2 && start src "$src"
say 5010 "end to end"
check "source -> relay -> collector -> SIEM" has /var/log/at-siem "end to end" 60
stop src; stop relay; stop collector; stop siem

section "A reliability-oriented worked example"
check "syslog.socket exists, for the note's stop command" systemctl cat syslog.socket
check "the iptables outage rule (from the note)" bash -ec "$(note_block "$NOTE" 'Generating test logs' 3 | sed -n 1p)"
check_output "drops RELP" 'DROP.*dpt:2514' iptables -L INPUT -n
check "and the restore command removes it" bash -ec "$(note_block "$NOTE" 'Generating test logs' 3 | sed -n 2p)"
check_fails "the rule is gone" bash -c 'iptables -L INPUT -n | grep -q "dpt:2514"'
# The single-relay chain, with an outage in the middle. Retries every second instead of
# every 30, or the test would wait minutes.
: >/var/log/at-siem
n=1   # block 1 of the section is the Mermaid diagram
for m in source relay collector; do
  n=$((n + 1))
  f=$(block "we-$m" 'Single relay' "$n")
  sed -i 's/action.resumeInterval="30"/action.resumeInterval="1"/; /module(load="omfwd")/d' "$f"
done
check "the source block" valid "$W/we-source.conf"
check "the relay block" valid "$W/we-relay.conf"
check "the collector block (without module(load=\"omfwd\"))" valid "$W/we-collector.conf"
seq -f 'generated line %g' 1 50 >/var/log/generated.log
start siem siem.conf 127.0.0.5 && start collector "$W/we-collector.conf" 127.0.0.4 && start relay "$W/we-relay.conf" 127.0.0.2
iptables --append INPUT --protocol tcp --dport 2514 --destination 127.0.0.2 --jump DROP
start source "$W/we-source.conf"
seq -f 'during outage %g' 1 20 >>/var/log/generated.log
sleep 5
check_fails "while relay-01 is cut off, nothing reaches the SIEM" grep -q 'during outage' /var/log/at-siem
iptables --delete INPUT --protocol tcp --dport 2514 --destination 127.0.0.2 --jump DROP
check "after the outage, every line arrives" retry 90 bash -c '[ "$(grep -c -E "generated line|during outage" /var/log/at-siem)" -ge 70 ]'
stop source; stop relay; stop collector; stop siem
f=$(block we-multi 'Multiple relays' 2)
check "the multiple-relays source block" valid "$f"

section "Checking the configuration"
check "rsyslogd -N 1 -f /etc/rsyslog.conf (from the note) on Leap's own config" \
  bash -ec "$(note_block "$NOTE" 'Checking the configuration' 1)"
