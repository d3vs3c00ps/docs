#!/usr/bin/env bash
# note: linux/logging/syslog-ng.md
# env: leap-systemd
# timeout: 900
# A Python listener on 127.0.0.1 plays the collector (192.168.1.1 in the note) and
# keeps the raw bytes it receives. syslog-ng.rocky.sh covers the RHEL part.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/logging/syslog-ng
CONF=/etc/syslog-ng/syslog-ng.conf
zypper -n -q install --no-recommends util-linux-systemd openssl python3 >/dev/null
W=$(mktemp -d)
cat >"$W/listen.py" <<'PY'
import socketserver, ssl, sys
port, out = int(sys.argv[1]), open(sys.argv[2], "ab", buffering=0)
class H(socketserver.StreamRequestHandler):
    def handle(self):
        while chunk := self.request.recv(65536): out.write(chunk)
class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    def get_request(self):
        sock, addr = super().get_request()
        if len(sys.argv) > 3:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(sys.argv[3], sys.argv[4])
            sock = ctx.wrap_socket(sock, server_side=True)
        return sock, addr
S(("127.0.0.1", port), H).serve_forever()
PY
listen() { python3 "$W/listen.py" "$@" & }
trap 'kill $(jobs -p) 2>/dev/null; _t_finish' EXIT
# 192.168.1.1 is the collector; SUSE's default source is src (see the note's table).
local_conf() { sed 's/"192\.168\.1\.1"/"127.0.0.1"/; s/source(s_src)/source(src)/'; }
arrived() { retry 20 grep -q "$1" "$2"; }

section "Installation"
check "zypper install (from the note)" bash -ec "$(note_block "$NOTE" Installation 1 | sed 's/install -y/-n -q install/')"
check_output "syslog-ng 4 is installed" '^syslog-ng-4\.' rpm -q syslog-ng

section "Enabling the service"
check "enable --now (from the note)" bash -ec "$(note_block "$NOTE" 'Enabling the service' 1)"
check "the service runs" retry 10 systemctl is-active syslog-ng

section "Configuration"
check_output "journald does not forward to syslog by default" '^ForwardToSyslog=no' \
  bash -c "systemd-analyze cat-config systemd/journald.conf | sed 's/^#//' | grep ForwardToSyslog"
src=$(sed -n '/^source src {/,/^};/p' $CONF)
assert_match "SUSE's default source is src" '^source src \{' "$src"
assert_match "with system()" 'system\(\);' "$src"
assert_match "and internal()" 'internal\(\);' "$src"
skip "Debian's default source name s_src" "no Debian environment in the tests; RHEL's s_sys is in syslog-ng.rocky.sh"
check_output "system() reads the journal on a systemd host" 'systemd-journal' \
  bash -c "syslog-ng --preprocess-into=- 2>/dev/null; syslog-ng --preprocess-into=/tmp/pre.conf >/dev/null 2>&1; cat /tmp/pre.conf"
tag=journal-$RANDOM
logger -t notetest "$tag"
check "a journal message reaches syslog-ng's files" retry 20 grep -rq "$tag" /var/log/messages

section "Forwarding logs unencrypted"
listen 514 "$W/tcp.raw"
cp $CONF $CONF.orig
{ note_block "$NOTE" 'Forwarding logs unencrypted' 1; note_block "$NOTE" 'Forwarding logs unencrypted' 2; } | local_conf >>$CONF
check "the configuration is valid" syslog-ng -s -f $CONF
check "restart (from the note)" bash -ec "$(note_block "$NOTE" 'Forwarding logs unencrypted' 3)"
tag=tcp-$RANDOM
logger -t notetest "$tag"
check "the message reaches the collector over TCP 514" arrived "$tag" "$W/tcp.raw"
check_output "tcp() sends RFC3164: <PRI>, then a timestamp with no year" "^<[0-9]+>[A-Z][a-z]{2} [ 0-9]{2} [0-9:]{8} .*$tag" \
  grep -a "$tag" "$W/tcp.raw"
cp $CONF.orig $CONF
listen 601 "$W/5424.raw"
tip=$(grep -o 'syslog("192.168.1.1" transport(tcp) port(601));' "$NOTES_ROOT/content/$NOTE.md")
printf 'destination d_5424 { %s };\nlog { source(src); destination(d_5424); };\n' "$tip" | local_conf >>$CONF
systemctl restart syslog-ng
tag=rfc5424-$RANDOM
logger -t notetest "$tag"
check "the syslog() driver from the tip delivers to port 601" arrived "$tag" "$W/5424.raw"
check_output "in RFC5424, with octet counting" "^[0-9]+ <[0-9]+>1 [0-9]{4}-[0-9]{2}-[0-9]{2}T" grep -a "$tag" "$W/5424.raw"

section "Forwarding logs over TLS"
cp $CONF.orig $CONF
P=$W/pki && mkdir -p "$P"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$P/ca.key" -out "$P/ca.crt" -subj /CN=test-ca -days 2 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$P/srv.key" -out "$P/srv.csr" -subj /CN=127.0.0.1 2>/dev/null
openssl x509 -req -in "$P/srv.csr" -CA "$P/ca.crt" -CAkey "$P/ca.key" -CAcreateserial -days 2 \
  -extfile <(echo 'subjectAltName=IP:127.0.0.1') -out "$P/srv.crt" 2>/dev/null
listen 6514 "$W/tls.raw" "$P/srv.crt" "$P/srv.key"
steps=$(note_block "$NOTE" 'Forwarding logs over TLS' 1)
mkdir -p /etc/syslog-ng/ca.d && cp "$P/ca.crt" /etc/syslog-ng/ca.d/ca.crt
hash=$(bash -ec "$(grep '^openssl' <<<"$steps")")
check_output "openssl x509 -hash prints the subject hash (from the note)" '^[0-9a-f]{8}$' echo "$hash"
check "the hash link (from the note)" bash -ec "$(grep '^ln -s' <<<"$steps" | sed "s/aa19aea1/$hash/")"
note_block "$NOTE" 'Forwarding logs over TLS' 2 | local_conf >>$CONF
check "the TLS configuration is valid" syslog-ng -s -f $CONF
check "restart (from the note)" bash -ec "$(note_block "$NOTE" 'Forwarding logs over TLS' 4)"
tag=tls-$RANDOM
logger -t notetest "$tag"
check "the message reaches the collector over TLS, the server verified with ca_dir()" arrived "$tag" "$W/tls.raw"
# The correction: the CA given as cert_file() instead of ca_dir() does not make the server trusted.
cp $CONF.orig $CONF
note_block "$NOTE" 'Forwarding logs over TLS' 2 | local_conf | \
  sed 's|ca_dir("/etc/syslog-ng/ca.d")|cert_file("/etc/syslog-ng/ca.d/ca.crt")|' >>$CONF
: >"$W/tls.raw"
systemctl reset-failed syslog-ng
check "syslog-ng still starts with that configuration" systemctl restart syslog-ng
tag=tls-bad-$RANDOM
logger -t notetest "$tag"
sleep 5
check_fails "with the CA as cert_file(), nothing is delivered" grep -q "$tag" "$W/tls.raw"
check_output "and syslog-ng logs a certificate error" 'certificate verify failed|Certificate validation failed|SSL error' \
  bash -c 'journalctl -u syslog-ng --no-pager -n 50; grep -h syslog-ng /var/log/messages | tail -20'
cp $CONF.orig $CONF && systemctl reset-failed syslog-ng && systemctl restart syslog-ng

section "Troubleshooting"
check "syslog-ng -svf (from the note)" bash -ec "$(note_block "$NOTE" 'Checking the configuration syntax' 1)"
echo 'destination broken { tcp("x" port(oops)); };' >"$W/bad.conf"
check_fails "it fails on a broken file" syslog-ng -svf "$W/bad.conf"
check_output "the container error, when capabilities cannot be set" "Error setting capabilities, capability management disabled" \
  bash -c "timeout 3 setpriv --bounding-set=-all --inh-caps=-all syslog-ng -F -f $CONF.orig -R $W/p -c $W/ctl 2>&1; true"
check_output "--no-caps exists" 'no-caps' syslog-ng --help-all
check "on SUSE, the unit reads SYSLOG_NG_PARAMS from /etc/sysconfig/syslog" \
  bash -c "systemctl cat syslog-ng | grep -q 'EnvironmentFile=-/etc/sysconfig/syslog' && systemctl cat syslog-ng | grep -q 'SYSLOG_NG_PARAMS'"
check "the note's SUSE line sets SYSLOG_NG_PARAMS" bash -ec "$(note_block "$NOTE" 'Running in a container' 3) && [[ \$SYSLOG_NG_PARAMS == --no-caps ]]"
