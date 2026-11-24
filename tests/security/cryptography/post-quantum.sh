#!/usr/bin/env bash
# note: security/cryptography/post-quantum.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/cryptography/post-quantum
block() { note_block "$NOTE" "$@"; }
cd "$(mktemp -d)"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout srv.key \
  -subj /CN=localhost -days 1 -out srv.crt 2>/dev/null
# server [ARGS...]: an s_server on port 4433, stopped by stop_server.
server() { openssl s_server -accept 4433 -cert srv.crt -key srv.key -quiet "$@" </dev/null >/dev/null 2>&1 & srv=$!; sleep 1; }
stop_server() { kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null || true; }
group() { openssl s_client -connect 127.0.0.1:4433 "$@" </dev/null 2>&1 | grep -i 'Negotiated TLS1.3 group'; }

section "Everything gets bigger"
openssl genpkey -algorithm ML-KEM-768 -out mlkem.pem
openssl pkey -in mlkem.pem -pubout -out mlkem.pub
# The SubjectPublicKeyInfo wrapper adds 22 bytes to the raw key.
assert_eq "an ML-KEM-768 public key is 1184 bytes" 1184 $(($(openssl pkey -pubin -in mlkem.pub -outform DER | wc -c) - 22))
openssl pkeyutl -encap -pubin -inkey mlkem.pub -out ct -secret ss
assert_eq "an ML-KEM-768 ciphertext is 1088 bytes" 1088 "$(wc -c <ct)"
assert_eq "and the shared secret 32 bytes" 32 "$(wc -c <ss)"
openssl genpkey -algorithm X25519 -out x.pem
assert_eq "an X25519 public key is 32 bytes" 32 $(($(openssl pkey -in x.pem -pubout -outform DER | wc -c) - 12))
echo message >m
openssl genpkey -algorithm ED25519 -out ed.pem && openssl pkeyutl -sign -rawin -inkey ed.pem -in m -out ed.sig
assert_eq "an Ed25519 signature is 64 bytes" 64 "$(wc -c <ed.sig)"
openssl genpkey -algorithm ML-DSA-65 -out d.pem && openssl pkeyutl -sign -rawin -inkey d.pem -in m -out d.sig
assert_eq "an ML-DSA-65 signature is 3309 bytes" 3309 "$(wc -c <d.sig)"
openssl genpkey -algorithm SLH-DSA-SHA2-128s -out s.pem && openssl pkeyutl -sign -rawin -inkey s.pem -in m -out s.sig
assert_eq "an SLH-DSA-128s signature is 7856 bytes" 7856 "$(wc -c <s.sig)"
server
hello=$(openssl s_client -connect 127.0.0.1:4433 -msg </dev/null 2>&1 | sed -n 's/.*\[length \([0-9a-f]*\)\], ClientHello$/\1/p' | head -1)
stop_server
check "a ClientHello with the hybrid key share is over 1460 bytes (one TCP segment)" test $((16#$hello)) -gt 1460

section "Turning it on"
check_output "OpenSSL 3.5 or later (from the note)" '^OpenSSL 3\.([5-9]|[1-9][0-9])' bash -ec "$(block 'Turning it on' 1 | sed -n 1p)"
check_output "it lists ML-KEM-768 (from the note)" 'ML-KEM-768' bash -ec "$(block 'Turning it on' 1 | sed -n 2p)"
check_output "and ML-DSA and SLH-DSA (from the note)" 'SLH-DSA' bash -ec "$(block 'Turning it on' 1 | sed -n 3p)"
server
console=$(block 'Turning it on' 2)
cmd=$(sed -n 1,2p <<<"$console" | sed 's/^\$ //; s/cloudflare.com:443/127.0.0.1:4433/')
check_output "the note's s_client check, against a local server" "^$(sed -n 3p <<<"$console")\$" bash -c "$cmd"
check_output "OpenSSL 3.5 offers X25519MLKEM768 by default: no -groups needed" 'X25519MLKEM768' group
stop_server
server -groups X25519
check_output "a classical-only server: the connection still works, with X25519 (silent fallback)" \
  'Peer Temp Key: X25519, 253 bits' \
  bash -c 'openssl s_client -connect 127.0.0.1:4433 -groups X25519MLKEM768:X25519:P-256 </dev/null 2>&1'
check_fails "and the note's grep prints nothing" group -groups X25519MLKEM768:X25519:P-256
stop_server
skip "s_client to cloudflare.com" "needs the internet; the same command ran against a local s_server"
check "generate ML-KEM and ML-DSA keys (from the note)" bash -ec "$(block 'Turning it on' 3)"
check_output "the key is ML-DSA-65" 'ML-DSA-65' openssl pkey -in mldsa.pem -noout -text
server
check_output "the note's client group list (from the note)" 'X25519MLKEM768' \
  bash -c "$(block 'Turning it on' 4 | grep '^openssl' | sed 's/example.com:443/127.0.0.1:4433/') </dev/null 2>&1"
stop_server

zypper -n -q install --no-recommends nginx >/dev/null
curve=$(block 'Turning it on' 4 | sed -n 's/^# \(ssl_ecdh_curve .*\)$/\1/p')
cat >/etc/nginx/conf.d/pq.conf <<CONF
server {
    listen 8443 ssl;
    ssl_certificate     $PWD/srv.crt;
    ssl_certificate_key $PWD/srv.key;
    $curve
}
CONF
check "nginx accepts the note's ssl_ecdh_curve line" nginx -t
nginx
check_output "and negotiates X25519MLKEM768" 'X25519MLKEM768' \
  bash -c 'openssl s_client -connect 127.0.0.1:8443 </dev/null 2>&1 | grep "Negotiated TLS1.3 group"'
check_output "a client with only P-256 still connects (the classical fallback)" 'Peer Temp Key: ECDH, prime256v1' \
  bash -c 'openssl s_client -connect 127.0.0.1:8443 -groups P-256 </dev/null 2>&1'
nginx -s stop

section "Kyber draft"
check_fails "OpenSSL 3.5 has no X25519Kyber768Draft00 group: the draft name is not ML-KEM" \
  openssl s_client -connect 127.0.0.1:1 -groups X25519Kyber768Draft00
