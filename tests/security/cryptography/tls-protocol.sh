#!/usr/bin/env bash
# note: security/cryptography/tls-protocol.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/cryptography/tls-protocol
block() { note_block "$NOTE" "$@"; }
cd "$(mktemp -d)"
zypper -n -q install --no-recommends xxd >/dev/null
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ec.key -subj /CN=localhost -days 1 -out ec.crt 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -keyout rsa.key -subj /CN=localhost -days 1 -out rsa.crt 2>/dev/null
# server CERT KEY [ARGS...]: s_server on 4433 until stop_server.
server() { openssl s_server -accept 4433 -cert "$1" -key "$2" -quiet "${@:3}" </dev/null >/dev/null 2>&1 & srv=$!; sleep 1; }
stop_server() { kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null || true; }
client() { openssl s_client -connect 127.0.0.1:4433 "$@" </dev/null 2>&1; }
# msgs ARGS...: the handshake message names, in order, one per line.
msgs() { client -msg "$@" | sed -n 's/^\(<<<\|>>>\) TLS 1\.[23], \(Handshake \[[^]]*\], \)\{0,1\}\([A-Za-z]*\).*/\1 \3/p'; }

section "Handshake protocol (TLS 1.2)"
server ec.crt ec.key
m12=$(msgs -tls1_2 | grep -v RecordHeader | tr '\n' ' ')
assert_match "the TLS 1.2 handshake runs in the note's order, 1 to 8" \
  '>>> ClientHello <<< ServerHello <<< Certificate <<< ServerKeyExchange <<< ServerHelloDone >>> ClientKeyExchange >>> ChangeCipherSpec >>> Finished' "$m12"
stop_server
server rsa.crt rsa.key
m_rsa=$(msgs -tls1_2 -cipher AES128-GCM-SHA256 | tr '\n' ' ')
assert_match "static RSA key exchange: it runs" 'ClientKeyExchange' "$m_rsa"
assert_no_match "and has no ServerKeyExchange (no ephemeral value)" 'ServerKeyExchange' "$m_rsa"
stop_server

section "Record protocol"
server ec.crt ec.key
check_output "compression is off" '^Compression: NONE$' client
stop_server

section "Key derivation"
secret=0102030405060708090a0b0c0d0e0f10; seed=$(printf 'master secretclientrandomserverrandom' | xxd -p | tr -d '\n')
prf=$(openssl kdf -keylen 48 -kdfopt digest:SHA256 -kdfopt hexsecret:$secret -kdfopt hexseed:"$seed" TLS1-PRF | tr -d ':')
hmac() { xxd -r -p | openssl mac -digest SHA256 -macopt hexkey:$secret HMAC; }
a1=$(printf %s "$seed" | hmac); a2=$(printf %s "$a1" | hmac)
p=$(printf %s "$a1$seed" | hmac)$(printf %s "$a2$seed" | hmac)
assert_eq "P_SHA256 with A(i) || seed in each block matches OpenSSL's TLS 1.2 PRF (the correction)" "$prf" "${p:0:96}"
old=$(printf %s "$a1" | hmac)$(printf %s "$a2" | hmac)
assert_no_match "the earlier formula, without the seed, does not" "^$prf\$" "${old:0:96}"
assert_eq "the 48-byte master secret takes two SHA-256 blocks" 96 "${#prf}"

section "Message authentication"
check_output "HMAC formula: openssl computes HMAC-SHA256" 'SHA2-256\(stdin\)= [0-9a-f]{64}$' \
  bash -c 'echo -n data | openssl dgst -sha256 -hmac key'

section "What TLS 1.3 changed"
server ec.crt ec.key
m13=$(client -msg)
check_output "TLS 1.3 is negotiated by default" '^Protocol: TLSv1.3$' client
assert_match "the server's Certificate is encrypted (sent as inner content)" \
  'InnerContent \[length 0001\]'$'\n''<<< TLS 1\.3, Handshake \[length [0-9a-f]+\], Certificate' "$m13"
assert_match "a dummy ChangeCipherSpec is still sent, for middleboxes" 'TLS 1\.3, ChangeCipherSpec' "$m13"
assert_no_match "there is no ServerKeyExchange in TLS 1.3" 'ServerKeyExchange' "$m13"
check_output "the TLS 1.3 suite name from the note works" 'Cipher is TLS_AES_256_GCM_SHA384' \
  client -ciphersuites "$(block 'What TLS 1.3 changed' 1)"
stop_server

section "What to configure today"
for s in TLS_AES_256_GCM_SHA384 TLS_AES_128_GCM_SHA256 TLS_CHACHA20_POLY1305_SHA256; do
  check_output "OpenSSL enables $s by default" "^$s " openssl ciphers -s -v -tls1_3
done
# OpenSSL names the TLS 1.2 suites differently; -stdname prints the IANA name too.
std=$(openssl ciphers -stdname -v ALL)
# The note lists them as text, not in a code block.
while read -r s; do
  assert_match "TLS 1.2 suite $s exists in OpenSSL" "^$s " "$std"
done < <(sed -n '/^### TLS 1.2, while/,/^### Never/p' "$NOTES_ROOT/content/$NOTE.md" | grep -o 'TLS_[A-Z0-9_]*')
default=$(openssl ciphers -stdname -s -v DEFAULT)
assert_no_match "the default list has no RC4, 3DES, NULL, export or anonymous suites" \
  'RC4|3DES|_DES_|NULL|EXPORT|_anon_' "$default"
check_output "the hybrid group line is accepted (from the note)" 'Negotiated TLS1.3 group: X25519MLKEM768' \
  bash -c "openssl s_server -accept 4434 -cert ec.crt -key ec.key -quiet </dev/null >/dev/null 2>&1 & sleep 1; \
    openssl s_client -connect 127.0.0.1:4434 -groups '$(block 'Key exchange and curves' 1)' </dev/null 2>&1; kill %1"
server ec.crt ec.key
check_output "TLS 1.1 is refused by OpenSSL 3 at the default security level" 'no protocols available' \
  bash -c 'openssl s_client -connect 127.0.0.1:4433 -tls1_1 </dev/null 2>&1; true'
check_output "TLS 1.2 still works" '^Protocol: TLSv1.2$' client -tls1_2
stop_server
skip "0-RTT replay, CT logs, HSTS" "need a real client population or public logs; nothing to run locally"
