#!/usr/bin/env bash
# note: security/cryptography/openssl/introduction.md
# env: rocky
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/cryptography/openssl/introduction
block() { note_block "$NOTE" "$@"; }
cd "$(mktemp -d)"

section "The openssl command"
check_output "openssl help, list -commands, version -a (from the note)" 'OPENSSLDIR' bash -ec "$(block 1)"
check_output "list -commands has the pkey family" '\bgenpkey\b' openssl list -commands

section "The shape of the CLI"
check "old genrsa and new genpkey (from the note)" bash -ec "$(block 'The shape of the CLI' 2)"
check_output "the last key is Ed25519" 'ED25519' openssl pkey -in key.pem -noout -text
check_fails "ecparam (an old per-algorithm tool) does not know Ed25519" openssl ecparam -name ED25519 -genkey
check "genpkey makes ML-DSA keys too" openssl genpkey -algorithm ML-DSA-65 -out mldsa.pem

section "PEM and DER"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key -subj /CN=root -days 2 -out root.pem 2>/dev/null
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout int.key -subj /CN=int -days 2 \
  -CA root.pem -CAkey ca.key -addext basicConstraints=critical,CA:TRUE -out intermediate.crt 2>/dev/null
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout server.key -subj /CN=www.example.com -days 2 \
  -CA intermediate.crt -CAkey int.key -addext subjectAltName=DNS:www.example.com -out server.crt 2>/dev/null
cp server.crt cert.pem
check "PEM to DER and back (from the note)" bash -ec "$(block 'PEM and DER' 1)"
check_output "the DER file is binary" '^data$|Certificate' file -b cert.der
cmp -s <(openssl x509 -in cert.pem) <(openssl x509 -in cert.der -inform DER) && r=same || r=different
assert_eq "the round trip gives the same certificate" same "$r"
check_output "head -1 shows a PEM certificate" '^-----BEGIN CERTIFICATE-----$' head -1 cert.pem
check_output "head -1 shows an unencrypted key" '^-----BEGIN PRIVATE KEY-----$' head -1 server.key
openssl pkey -in server.key -aes256 -passout pass:x -out enc.key
check_output "head -1 shows an encrypted key" '^-----BEGIN ENCRYPTED PRIVATE KEY-----$' head -1 enc.key
check "build the chain, leaf first (from the note)" bash -ec "$(block 'PEM and DER' 3)"
check_output "the first certificate is the leaf" 'CN ?= ?www.example.com' openssl x509 -in fullchain.pem -noout -subject
check "a client verifies the chain from the root alone" \
  openssl verify -CAfile root.pem -untrusted fullchain.pem server.crt
cat intermediate.crt server.crt >reversed.pem
check "s_server accepts the right order (runs until the timeout)" bash -c \
  'timeout 2 openssl s_server -accept 4433 -cert fullchain.pem -key server.key -quiet </dev/null; [ $? = 124 ]'
check_fails "and refuses to start with the intermediate first" \
  timeout 2 openssl s_server -accept 4434 -cert reversed.pem -key server.key -quiet

section "Inspecting anything"
openssl req -new -key server.key -subj /CN=www.example.com -out req.csr
cp server.key key.pem
openssl req -x509 -key ca.key -subj /CN=root -days 2 -out ca.pem 2>/dev/null
touch index.txt && echo 01 >crlnumber
printf '[ca]\ndefault_ca=c\n[c]\ndatabase=index.txt\ncrlnumber=crlnumber\ndefault_md=sha256\ndefault_crl_days=1\n' >crl.cnf
openssl ca -config crl.cnf -gencrl -keyfile ca.key -cert ca.pem -out crl.pem 2>/dev/null
openssl pkcs12 -export -in cert.pem -inkey server.key -passout pass: -out bundle.p12
check "the five inspect commands (from the note)" bash -ec "$(block 'Inspecting anything' 1 | sed 's/-info -noout/-info -noout -passin pass:/')"

section "OpenSSL 3"
openssl pkcs12 -export -legacy -in cert.pem -inkey server.key -passout pass: -out old.p12
check_output "an RC2 PKCS#12 fails without -legacy, with the note's message" 'unsupported.*RC2-40-CBC' \
  bash -c 'openssl pkcs12 -in old.p12 -passin pass: -nodes -out /dev/null 2>&1; true'
check_output "and the first line is the one the note quotes" '^Error outputting keys and certificates' \
  bash -c 'openssl pkcs12 -in old.p12 -passin pass: -nodes -out /dev/null 2>&1; true'
check "-legacy opens it (from the note)" bash -ec "$(block 'OpenSSL 3' 1 | sed 's/-nodes/-passin pass: -nodes/')"
check_output "and extracts the key" 'BEGIN PRIVATE KEY' cat extracted.pem
echo data >m
check_output "rsautl prints a deprecation message" 'rsautl was deprecated in version 3.0' \
  bash -c 'openssl genpkey -algorithm RSA -out rsa.pem 2>/dev/null; openssl rsautl -sign -inkey rsa.pem -in m -out /dev/null 2>&1'
check_output "dgst -sign is not deprecated: no message (the correction)" '^$' \
  bash -c 'openssl dgst -sha256 -sign rsa.pem -out s m 2>&1'
check_output "version and providers (from the note)" 'OpenSSL Default Provider' bash -ec "$(block 'OpenSSL 3' 2)"
check_output "this is OpenSSL 3" '^OpenSSL 3\.' openssl version

section "Configuration"
check_output "OPENSSLDIR on Rocky (from the note)" '^OPENSSLDIR: "/etc/pki/tls"$' bash -ec "$(block Configuration 1)"
printf '[req]\nprompt=no\ndistinguished_name=dn\n[dn]\nCN=from-config\n' >my.cnf
check_output "OPENSSL_CONF picks the file (from the note)" 'CN ?= ?from-config' \
  bash -ec "$(block Configuration 2 | sed -n 1p | sed 's/\.\.\./-key key.pem | openssl req -noout -subject/')"
check_output "and so does -config" 'CN ?= ?from-config' \
  bash -ec "$(block Configuration 2 | sed -n 2p | sed 's/\.\.\./-key key.pem | openssl req -noout -subject/')"
check "-addext puts a SAN in the request (from the note)" bash -ec "$(block Configuration 3)"
check_output "the CSR carries both names" 'DNS:www.example.com, DNS:example.com' openssl req -in req.csr -noout -text

section "LibreSSL is not OpenSSL"
skip "LibreSSL on macOS" "needs a macOS host"
