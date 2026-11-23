#!/usr/bin/env bash
# note: security/cryptography/openssl/troubleshooting.md
# env: rocky
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/cryptography/openssl/troubleshooting
block() { note_block "$NOTE" "$@"; }
# The note's commands use sudo; the test runs as root, with no sudo installed.
sudo() { "$@"; }
export -f sudo
# A local server stands in for example.com: tests never connect to the internet.
local_() { sed 's/example\.com:443/localhost:4433/g'; }
run() { bash -ec "$(block "$@" | local_)"; }
cd "$(mktemp -d)"
dnf -y -q install nmap dos2unix python3 >/dev/null 2>&1

key() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1"; }
key ca.key && key int.key && key server.key
openssl req -x509 -key ca.key -out ca.crt -days 30 -subj "/CN=Test Root" -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
openssl req -new -key int.key -subj "/CN=Test Int" 2>/dev/null |
  openssl x509 -req -CA ca.crt -CAkey ca.key -out intermediate.crt -days 30 \
    -extfile <(printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n') 2>/dev/null
openssl req -new -key server.key -subj "/CN=example.com" 2>/dev/null |
  openssl x509 -req -CA intermediate.crt -CAkey int.key -out server.crt -days 30 \
    -extfile <(printf 'subjectAltName=DNS:example.com,DNS:localhost\n') 2>/dev/null
cp server.crt cert.pem && cp server.key key.pem
# serve CERTFILE [CHAIN] [EXTRA...]: start s_server on 4433 in the background.
serve() {
  local c=$1 chain=${2:-}
  shift 2 || shift $#
  pkill -f 's_server -accept 4433' 2>/dev/null || true
  sleep 0.3
  openssl s_server -accept 4433 -cert "$c" -key server.key ${chain:+-cert_chain "$chain"} -www -quiet "$@" >server.log 2>&1 &
  retry 10 bash -c 'echo | openssl s_client -connect localhost:4433 >/dev/null 2>&1'
}

section "Start by looking at the file"
check_output "head -1 shows the PEM type (from the note)" '^-----BEGIN CERTIFICATE-----$' \
  bash -ec "$(block 'Start by looking' 1 | sed 's/mystery.crt/cert.pem/')"
openssl req -new -key key.pem -subj /CN=x -out req.csr
assert_eq "a CSR starts with BEGIN CERTIFICATE REQUEST (the table)" '-----BEGIN CERTIFICATE REQUEST-----' "$(head -1 req.csr)"
assert_eq "an unencrypted PKCS#8 key: BEGIN PRIVATE KEY" '-----BEGIN PRIVATE KEY-----' "$(head -1 key.pem)"
openssl pkey -in key.pem -aes-256-cbc -passout pass:x -out enc.pem
assert_eq "an encrypted key: BEGIN ENCRYPTED PRIVATE KEY" '-----BEGIN ENCRYPTED PRIVATE KEY-----' "$(head -1 enc.pem)"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out rsa8.pem
openssl pkey -in rsa8.pem -traditional -out rsa1.pem
assert_eq "a legacy PKCS#1 key: BEGIN RSA PRIVATE KEY" '-----BEGIN RSA PRIVATE KEY-----' "$(head -1 rsa1.pem)"

section "unable to get local issuer certificate"
check_output "a missing intermediate gives this error" 'unable to get local issuer certificate' \
  bash -c 'openssl verify -CAfile ca.crt server.crt 2>&1; true'
check_output "-untrusted with the intermediate fixes it (from the note)" 'server.crt: OK' \
  bash -ec "$(block 'unable to get local issuer' 3)"
serve server.crt
check_output "a server sending only its leaf: s_client shows the error" 'unable to get local issuer certificate' \
  bash -c 'openssl s_client -connect localhost:4433 -servername example.com -CAfile ca.crt </dev/null 2>&1'
check_output "-showcerts lists one certificate (from the note)" '^ 0 s:' run 'unable to get local issuer' 1
check "fullchain.pem: leaf, then intermediate (from the note)" bash -ec "$(block 'unable to get local issuer' 2)"
assert_eq "it holds two certificates" 2 "$(grep -c 'BEGIN CERTIFICATE' fullchain.pem)"
serve server.crt intermediate.crt
check_output "with the chain, Verify return code 0" 'Verify return code: 0 \(ok\)' \
  bash -c 'openssl s_client -connect localhost:4433 -servername example.com -CAfile ca.crt </dev/null 2>&1'
check_output "and -showcerts lists both" '^ 1 s:' run 'unable to get local issuer' 1

section "self-signed certificate in certificate chain"
cat intermediate.crt ca.crt >chain-with-root.pem
serve server.crt chain-with-root.pem
check_output "a chain ending in an untrusted root gives this error" 'self-signed certificate in certificate chain' \
  bash -c 'openssl s_client -connect localhost:4433 -servername example.com </dev/null 2>&1'
skip "the openSUSE Leap commands" "this test runs on Rocky; the Leap anchor path is tested in tests/security/cryptography/openssl/commands.sh"
check "the Rocky commands (from the note)" bash -ec "$(block 'self-signed certificate in certificate chain' 1 | sed -n '/RHEL/,$p' | sed 's/^# .*//')"
check_output "after update-ca-trust, the system store trusts it" 'Verify return code: 0 \(ok\)' \
  bash -c 'openssl s_client -connect localhost:4433 -servername example.com </dev/null 2>&1'

section "key values mismatch"
key other.pem
check_output "a key that does not match the certificate gives this error" 'key values mismatch' \
  bash -c 'timeout 5 openssl s_server -accept 4434 -cert cert.pem -key other.pem 2>&1; true'
h=$(run 'key values mismatch' 1 | cut -d' ' -f2 | sort -u | wc -l)
assert_eq "the right key: the two hashes are identical (from the note)" 1 "$h"
cp other.pem key.pem
h=$(run 'key values mismatch' 1 | cut -d' ' -f2 | sort -u | wc -l)
assert_eq "the wrong key: they differ" 2 "$h"
check_fails "and diff shows a difference (from the note)" run 'key values mismatch' 2
cp server.key key.pem
check "with the right key, diff prints nothing" run 'key values mismatch' 2

section "Hostname mismatch"
check_output "the SAN check (from the note)" 'DNS:example.com, DNS:localhost' run 'Hostname mismatch' 1
serve server.crt intermediate.crt
check_output "a name not in the SAN gives Hostname mismatch (Python)" 'Hostname mismatch' \
  python3 -c '
import socket, ssl
c = ssl.create_default_context(cafile="ca.crt")
try:
    c.wrap_socket(socket.create_connection(("127.0.0.1", 4433)), server_hostname="www.example.org")
except ssl.SSLCertVerificationError as e:
    print(e)'
openssl req -new -key key.pem -subj "/CN=cn-only.example.com" 2>/dev/null |
  openssl x509 -req -CA intermediate.crt -CAkey int.key -out cn-only.crt -days 1 2>/dev/null
serve cn-only.crt intermediate.crt
check "curl too: the CN-only certificate passes for cn-only.example.com" \
  curl -s -o /dev/null --cacert ca.crt --resolve cn-only.example.com:4433:127.0.0.1 https://cn-only.example.com:4433/
check_output "and openssl -verify_hostname" 'Verify return code: 0' \
  bash -c 'openssl s_client -connect localhost:4433 -CAfile ca.crt -verify_hostname cn-only.example.com </dev/null 2>&1'
check_output "Python falls back to the CN when there is no SAN (the correction)" '^connected$' \
  python3 -c '
import socket, ssl
c = ssl.create_default_context(cafile="ca.crt")
try:
    c.wrap_socket(socket.create_connection(("127.0.0.1", 4433)), server_hostname="cn-only.example.com")
    print("connected")
except ssl.SSLCertVerificationError as e:
    print(e)'
openssl req -x509 -key key.pem -out default.crt -days 1 -subj /CN=default 2>/dev/null
pkill -f 's_server -accept 4433' || true
sleep 0.3
openssl s_server -accept 4433 -cert default.crt -key key.pem -cert2 server.crt -key2 server.key -servername example.com -www -quiet >/dev/null 2>&1 &
retry 10 bash -c 'echo | openssl s_client -connect localhost:4433 >/dev/null 2>&1'
check_output "with -servername, the right certificate (from the note)" 'subject=CN ?= ?example.com' run 'Hostname mismatch' 2
check_output "without it, the default one (as the note says)" 'subject=CN ?= ?default' \
  bash -c 'openssl s_client -connect localhost:4433 </dev/null 2>&1'

section "certificate has expired or is not yet valid"
check_output "-dates and date -u (from the note)" '^notAfter=' run 'certificate has expired' 1
openssl req -new -key key.pem -subj /CN=old 2>/dev/null |
  openssl x509 -req -CA ca.crt -CAkey ca.key -not_before 20200101000000Z -not_after 20200201000000Z -out expired.crt 2>/dev/null
openssl req -new -key key.pem -subj /CN=future 2>/dev/null |
  openssl x509 -req -CA ca.crt -CAkey ca.key -not_before 20991201000000Z -not_after 20991231000000Z -out future.crt 2>/dev/null
check_output "an expired certificate: certificate has expired" 'certificate has expired' \
  bash -c 'openssl verify -CAfile ca.crt expired.crt 2>&1; true'
check_output "a future one: certificate is not yet valid" 'certificate is not yet valid' \
  bash -c 'openssl verify -CAfile ca.crt future.crt 2>&1; true'

section "unsupported on a PKCS#12 file"
openssl pkcs12 -export -legacy -in server.crt -inkey server.key -out old.p12 -passout pass:x
check_output "an old RC2 file without -legacy: unsupported (as the note says)" '0308010C.*unsupported.*RC2-40-CBC' \
  bash -c 'openssl pkcs12 -in old.p12 -nodes -passin pass:x -out /dev/null 2>&1; true'
check "-legacy reads it (from the note)" bash -ec "$(block 'unsupported' 1) -passin pass:x"
check_output "the key is extracted" 'BEGIN PRIVATE KEY' cat extracted.pem
check_output "a wrong passphrase: Mac verify error (the correction)" 'Mac verify error: invalid password\?' \
  bash -c 'openssl pkcs12 -in old.p12 -legacy -nodes -passin pass:wrong -out /dev/null 2>&1; true'
head -c 300 old.p12 >trunc.p12
check_output "a truncated file: not enough data (the correction)" 'not enough data' \
  bash -c 'openssl pkcs12 -in trunc.p12 -legacy -nodes -passin pass:x -out /dev/null 2>&1; true'

section "PEM routines::no start line"
openssl x509 -in server.crt -outform DER -out cert.der
openssl req -new -key key.pem -subj /CN=x -out thing.pem
check_output "-inform DER (from the note)" 'Subject: CN ?= ?example.com' bash -ec "$(block 'no start line' 1 | sed -n 1p)"
check_output "req -in on a CSR (from the note)" 'Certificate Request:' bash -ec "$(block 'no start line' 1 | sed -n 2p)"
check_output "OpenSSL 3 x509 reads DER without -inform (the correction)" 'subject=CN ?= ?example.com' openssl x509 -in cert.der -noout -subject
check_output "the openssl command says Could not find certificate (the correction)" 'Could not find certificate from' \
  bash -c 'echo garbage >g.pem; openssl x509 -in g.pem -noout 2>&1; true'
check_output "a TLS library loading a non-PEM file reports PEM lib" 'PEM lib|no start line' \
  python3 -c '
import ssl
try:
    ssl.create_default_context().load_cert_chain("g.pem")
except ssl.SSLError as e:
    print(e)'
check "DER to PEM (from the note)" bash -ec "$(block 'no start line' 2)"
check_output "cert.pem is PEM again" '^-----BEGIN CERTIFICATE-----$' head -1 cert.pem
sed 's/$/\r/' server.crt >crlf.pem
check_output "file says PEM certificate, with no word about CRLF (the correction)" '^crlf.pem: PEM certificate$' file crlf.pem
check_output "a PEM file with CRLF loads fine (the correction)" 'subject=CN ?= ?example.com' openssl x509 -in crlf.pem -noout -subject
check_output "and with a UTF-8 byte order mark too" 'subject=CN ?= ?example.com' \
  bash -c "printf '\\xef\\xbb\\xbf' | cat - server.crt | openssl x509 -noout -subject"
check "dos2unix removes the CR" bash -c 'dos2unix -q crlf.pem && ! grep -q $'"'"'\r'"'"' crlf.pem'

section "dh key too small / no shared cipher"
openssl req -x509 -newkey rsa:2048 -nodes -keyout rsa.key -out rsa.crt -days 1 -subj /CN=localhost 2>/dev/null
openssl dhparam -out dh1024.pem 1024 2>/dev/null
pkill -f 's_server -accept 4433' || true
sleep 0.3
openssl s_server -accept 4433 -cert rsa.crt -key rsa.key -dhparam dh1024.pem -tls1_2 \
  -cipher 'DHE-RSA-AES128-GCM-SHA256:@SECLEVEL=0' -www -quiet >/dev/null 2>&1 &
retry 10 bash -c 'echo | openssl s_client -connect localhost:4433 -cipher DEFAULT@SECLEVEL=0 >/dev/null 2>&1'
check_output "1024-bit DH parameters: dh key too small (as the note says)" 'dh key too small' \
  bash -c 'openssl s_client -connect localhost:4433 -tls1_2 -cipher DHE-RSA-AES128-GCM-SHA256 </dev/null 2>&1; true'
check "dhparam 2048 (from the note)" bash -ec "$(block 'dh key too small' 2)"
pkill -f 's_server -accept 4433' || true
sleep 0.3
openssl s_server -accept 4433 -cert rsa.crt -key rsa.key -dhparam dhparam.pem -tls1_2 -cipher DHE-RSA-AES128-GCM-SHA256 -www -quiet >/dev/null 2>&1 &
retry 10 bash -c 'echo | openssl s_client -connect localhost:4433 >/dev/null 2>&1'
check_output "with 2048-bit parameters the DHE handshake works" 'DHE-RSA-AES128-GCM-SHA256' \
  bash -c 'openssl s_client -connect localhost:4433 -tls1_2 -cipher DHE-RSA-AES128-GCM-SHA256 </dev/null 2>&1'
d=$(block 'dh key too small' 1 | local_)
check_output "s_client -tls1_2 (from the note)" 'TLSv1.2' bash -ec "$(sed -n 1p <<<"$d") </dev/null"
check_output "nmap ssl-enum-ciphers (from the note)" 'TLS_DHE_RSA_WITH_AES_128_GCM_SHA256 \(dh 2048\)' \
  bash -ec "$(sed -n 2p <<<"$d" | sed 's/-p 443 example.com/-p 4433 localhost/')"
pkill -f 's_server -accept 4433' || true
sleep 0.3
openssl s_server -accept 4433 -cert rsa.crt -key rsa.key -tls1_2 -cipher ECDHE-RSA-AES128-GCM-SHA256 -www >server.log 2>&1 &
retry 10 bash -c 'echo | openssl s_client -connect localhost:4433 >/dev/null 2>&1'
openssl s_client -connect localhost:4433 -tls1_2 -cipher ECDHE-RSA-AES256-GCM-SHA384 </dev/null >/dev/null 2>&1 || true
sleep 0.5
check_output "no common suite: the server logs no shared cipher" 'no shared cipher' cat server.log

section "signature does not verify"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out sk.pem
openssl pkey -in sk.pem -pubout -out pub.pem
head -c 1000 /dev/urandom | openssl dgst -sha256 -binary >file.sha256
openssl pkeyutl -sign -inkey sk.pem -in file.sha256 -pkeyopt digest:sha256 \
  -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:-1 -out file.sig
check_fails "a PSS signature fails with the default verify (as the note says)" \
  openssl pkeyutl -verify -pubin -inkey pub.pem -in file.sha256 -sigfile file.sig -pkeyopt digest:sha256
check_output "and verifies with the PSS options (from the note)" 'Signature Verified Successfully' run 'signature does not verify' 1

section "Debugging a live handshake"
serve server.crt intermediate.crt
h=$(block 'Debugging a live handshake' 1 | local_)
check_output "-showcerts (from the note)" 'Verify return code' bash -ec "$(sed -n 2p <<<"$h")"
check_output "-trace prints the protocol messages (from the note)" 'ClientHello' bash -ec "$(sed -n 5p <<<"$h")"
out=$(bash -ec "$(sed -n '/protocol versions/,$p' <<<"$h")")
assert_match "the version loop: TLS 1.3 OK (from the note)" '^tls1_3: OK$' "$out"
pkill -f 's_server -accept 4433' || true
sleep 0.3
openssl s_server -accept 4433 -cert server.crt -key server.key -cert_chain intermediate.crt -tls1_3 -www -quiet >/dev/null 2>&1 &
retry 10 bash -c 'echo | openssl s_client -connect localhost:4433 >/dev/null 2>&1'
out=$(bash -ec "$(sed -n '/protocol versions/,$p' <<<"$h")")
assert_match "a TLS 1.3-only server: tls1_2 not supported (from the note)" '^tls1_2: not supported$' "$out"
assert_match "and tls1_3 OK" '^tls1_3: OK$' "$out"
check_output "s_client prints Verify return code even when the handshake fails (the correction)" 'Verify return code' \
  bash -c 'openssl s_client -connect localhost:4433 -tls1_2 </dev/null 2>/dev/null; true'
check_fails "and exits non-zero" bash -c 'openssl s_client -connect localhost:4433 -tls1_2 </dev/null >/dev/null 2>&1'
check_output "OpenSSL 3 refuses -tls1_1 on the client side (the correction)" 'no protocols available' \
  bash -c 'openssl s_client -connect localhost:4433 -tls1_1 </dev/null 2>&1; true'

section "A certificate that works with curl -k and nothing else"
serve server.crt
check_fails "curl without -k fails on a server missing its intermediate" curl -s --cacert ca.crt https://localhost:4433/
check "curl -k works: TLS works, the trust chain does not (as the note says)" curl -sk -o /dev/null https://localhost:4433/
pkill -f 's_server -accept 4433' || true
