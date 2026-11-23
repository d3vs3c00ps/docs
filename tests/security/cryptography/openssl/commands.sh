#!/usr/bin/env bash
# note: security/cryptography/openssl/commands.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/cryptography/openssl/commands
block() { note_block "$NOTE" "$@"; }
# run HEADING N [SED]: run a block of the note, optionally edited by a sed script.
run() { bash -ec "$(block "$1" "$2" | sed "${3:-}")"; }
cd "$(mktemp -d)"

# A CA with an intermediate, for the signing and verifying sections.
ca() {
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key -out ca.crt \
    -days 30 -subj "/CN=Test Root" -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout int.key -out int.csr -subj "/CN=Test Int" 2>/dev/null
  printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' >int.ext
  openssl x509 -req -in int.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out intermediate.crt -days 30 -extfile int.ext 2>/dev/null
}
ca

section "Generating keys"
gen=$(block 'Generating keys' 1)
check "RSA 3072 (from the note)" bash -ec "$(sed -n 2p <<<"$gen")"
check_output "it is a 3072-bit key" 'Private-Key: \(3072 bit' openssl pkey -in key.pem -noout -text
check "ECDSA P-256 (from the note)" bash -ec "$(sed -n 5p <<<"$gen")"
check_output "it is on prime256v1" 'prime256v1|P-256' openssl pkey -in key.pem -noout -text
check "Ed25519 (from the note)" bash -ec "$(sed -n 8p <<<"$gen")"
check_output "it is an ED25519 key" 'ED25519 Private-Key' openssl pkey -in key.pem -noout -text
# The passphrase prompt needs a terminal; give it on the command line instead.
check "encrypted key (from the note, with -pass)" bash -ec "$(sed -n '11,12p' <<<"$gen") -pass pass:test"
check_output "the file is an encrypted PKCS#8 key" 'BEGIN ENCRYPTED PRIVATE KEY' head -1 key.pem
cp key.pem key-enc.pem
check "inspect and extract the public half (from the note)" bash -ec "$(block 'Generating keys' 2 | sed 's/-in key.pem/& -passin pass:test/')"
check_output "pub.pem is a public key" 'BEGIN PUBLIC KEY' head -1 pub.pem
check "remove the passphrase (from the note)" bash -ec "$(block 'Generating keys' 3 | sed -n 2p | sed 's/ *#.*//; s/$/ -passin pass:test/')"
check_output "the key is now plain" 'BEGIN PRIVATE KEY' head -1 key.pem
check "add a passphrase (from the note)" bash -ec "$(block 'Generating keys' 3 | sed -n 1p | sed 's/ *#.*//; s/$/ -passout pass:test/')"
check_output "key-enc.pem is encrypted" 'BEGIN ENCRYPTED' head -1 key-enc.pem

section "Key file modes (the correction)"
umask 022
rm -f new.pem && openssl genpkey -algorithm ED25519 -out new.pem
check_output "with umask 022, a new key file from genpkey is mode 600" '^600$' stat -c %a new.pem
rm -f new.pem && openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout new.pem -out /dev/null -subj /CN=x 2>/dev/null
check_output "and from req -keyout" '^600$' stat -c %a new.pem
touch old.pem && chmod 644 old.pem && openssl genpkey -algorithm ED25519 -out old.pem
check_output "an existing 644 file keeps mode 644 (as the note warns)" '^644$' stat -c %a old.pem
check_output "pub.pem follows the umask" '^644$' stat -c %a pub.pem
check "umask 077 and chmod 600 (from the note)" bash -ec "$(block 'Generating keys' 4); [ \$(stat -c %a key.pem) = 600 ]"
check "-noenc is the OpenSSL 3 name of -nodes" bash -c 'openssl req -help 2>&1 | grep -q -- "-noenc"'

section "Certificate signing requests"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out key.pem
check "a CSR with a SAN (from the note)" run 'Certificate signing requests' 1
check_output "the CSR has both SAN names" 'DNS:www.example.com, DNS:example.com' openssl req -in req.csr -noout -text
check_output "the subject is the sanitised one" 'O ?= ?Example Corp' openssl req -in req.csr -noout -subject
check "key and CSR in one step (from the note)" run 'Certificate signing requests' 2
check_output "a 3072-bit RSA key" 'Private-Key: \(3072 bit' openssl pkey -in key.pem -noout -text
check_output "inspect and verify the CSR (from the note)" 'verify OK|Certificate request self-signature verify OK' \
  run 'Certificate signing requests' 4

section "Self-signed certificates"
check "the self-signed certificate (from the note)" run 'Self-signed certificates' 1
check_output "SAN with DNS and IP (from the note's -ext check)" 'DNS:www.example.com, DNS:localhost, IP Address:127.0.0.1' \
  bash -ec "$(block 'Certificate signing requests' 3)"
check_output "basicConstraints CA:FALSE is critical" 'Basic Constraints: critical' openssl x509 -in cert.pem -noout -text
check_output "-purpose: an SSL server" 'SSL server : Yes' openssl x509 -in cert.pem -noout -purpose

section "Inspecting certificates"
check_output "every inspect command works (from the note)" 'sha256 Fingerprint=' run 'Inspecting certificates' 1
check "-checkend 30 days: exit 0 for a 365-day certificate (from the note)" run 'Inspecting certificates' 2
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout s.key -out soon.pem -days 10 -subj /CN=soon 2>/dev/null
check_fails "and exit 1 for one that expires in 10 days" openssl x509 -in soon.pem -noout -checkend 2592000
assert_eq "2592000 seconds is 30 days" 2592000 $((30 * 86400))
mkdir -p /etc/pki/tls/certs && cp cert.pem /etc/pki/tls/certs/ok.pem && cp soon.pem /etc/pki/tls/certs/soon.pem
out=$(run 'Inspecting certificates' 3)
assert_match "the monitoring loop reports the expiring one (from the note)" 'EXPIRING: /etc/pki/tls/certs/soon.pem \(notAfter=' "$out"
assert_no_match "and not the other" 'ok\.pem' "$out"

section "Signing a CSR with your own CA"
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout key.pem -out req.csr -subj /CN=www.example.com \
  -addext "subjectAltName=DNS:only-in-the-csr.example.com" 2>/dev/null
block 'Signing a CSR' 2 >ext.cnf
check "openssl x509 -req with -extfile (from the note)" run 'Signing a CSR' 1
check_output "the SAN comes from ext.cnf" 'DNS:www.example.com, DNS:example.com' openssl x509 -in cert.pem -noout -ext subjectAltName
openssl x509 -req -in req.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out nosan.pem -days 1 2>/dev/null
check_fails "without -extfile, the CSR's SAN is not copied (as the note says)" \
  bash -c 'openssl x509 -in nosan.pem -noout -ext subjectAltName | grep -q only-in-the-csr'

section "Verifying"
cp cert.pem leaf-by-root.pem
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout lk.pem -out l.csr -subj /CN=leaf 2>/dev/null
openssl x509 -req -in l.csr -CA intermediate.crt -CAkey int.key -CAcreateserial -out leaf.pem -days 1 2>/dev/null
v=$(block Verifying 1)
check_output "verify -CAfile (from the note)" 'cert.pem: OK' bash -ec "$(sed -n 1p <<<"$v")"
check_output "verify with -untrusted intermediate (from the note)" 'OK' bash -ec "$(sed -n 2p <<<"$v" | sed 's/cert.pem/leaf.pem/')"
check_fails "and it fails without the intermediate" openssl verify -CAfile ca.crt leaf.pem
cp ca.crt /etc/pki/trust/anchors/test-root.crt && update-ca-certificates >/dev/null 2>&1
check_output "verify -CApath /etc/ssl/certs after update-ca-certificates (from the note)" 'cert.pem: OK' bash -ec "$(sed -n 3p <<<"$v")"
h=$(run Verifying 2 | cut -d' ' -f2 | sort -u | wc -l)
assert_eq "the two public-key hashes are identical (from the note)" 1 "$h"
check "diff of the public keys prints nothing (from the note)" run Verifying 3
openssl x509 -in cert.pem -noout -modulus >/dev/null 2>&1 || true
old1=$(openssl x509 -in cert.pem -noout -pubkey | openssl sha256)
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out other.pem
old2=$(openssl pkey -in other.pem -pubout | openssl sha256)
check_fails "a different key gives a different hash" test "$old1" = "$old2"
openssl req -x509 -newkey rsa:2048 -nodes -keyout rk.pem -out rc.pem -days 1 -subj /CN=r 2>/dev/null
a=$(openssl x509 -in rc.pem -noout -modulus | openssl sha256)
b=$(openssl pkey -in rk.pem -noout -pubout | openssl sha256)
check_fails "the old -modulus vs pkey -noout -pubout form never matches, even for the right RSA key (the correction)" test "$a" = "$b"
assert_eq "pkey -noout -pubout prints nothing" "" "$(openssl pkey -in rk.pem -noout -pubout)"
assert_eq "the RSA form with rsa -modulus on both sides matches" \
  "$(openssl x509 -in rc.pem -noout -modulus)" "$(openssl rsa -in rk.pem -noout -modulus)"

section "PKCS#12"
cp intermediate.crt chain.pem
check "export a bundle (from the note, with -passout)" bash -ec "$(block 'PKCS#12' 1) -passout pass:test"
p=$(block 'PKCS#12' 2)
check_output "-info (from the note)" 'MAC: sha256' bash -ec "$(sed -n 1p <<<"$p" | sed 's/$/ -passin pass:test/')"
check_output "-nokeys gets the certificates (from the note)" 'BEGIN CERTIFICATE' \
  bash -ec "$(sed -n 2p <<<"$p") -passin pass:test; cat certs.pem"
check_output "-nocerts -nodes gets the key (from the note)" 'BEGIN PRIVATE KEY' \
  bash -ec "$(sed -n 3p <<<"$p") -passin pass:test; cat key.pem"
openssl pkcs12 -export -legacy -out bundle.p12 -inkey key.pem -in cert.pem -passout pass:test
check_fails "an old RC2/3DES file fails without -legacy" openssl pkcs12 -in bundle.p12 -nodes -passin pass:test -out /dev/null
check "and opens with -legacy (from the note)" bash -ec "$(sed -n 4p <<<"$p" | sed 's/ *#.*//') -passin pass:test"

section "s_client"
# A local server stands in for example.com: tests never connect to the internet.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout srv.key -out srv.crt -days 30 \
  -subj /CN=example.com -addext "subjectAltName=DNS:example.com" -CA ca.crt -CAkey ca.key 2>/dev/null
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout def.key -out def.crt -days 30 -subj /CN=default 2>/dev/null
openssl s_server -accept 4433 -cert def.crt -key def.key -cert2 srv.crt -key2 srv.key -servername example.com \
  -www -quiet >/dev/null 2>&1 &
retry 10 bash -c 'echo | openssl s_client -connect localhost:4433 >/dev/null 2>&1'
local_() { sed 's/example\.com:443/localhost:4433/g'; }
check_output "s_client with SNI gets the named certificate (from the note)" 'subject=CN ?= ?example.com' \
  bash -ec "$(block s_client 1 | local_) </dev/null"
check_output "without -servername, the default one (as the note says)" 'subject=CN ?= ?default' \
  bash -c 'openssl s_client -connect localhost:4433 </dev/null 2>/dev/null'
c=$(block s_client 2 | local_)
check_output "-showcerts (from the note)" 'BEGIN CERTIFICATE' bash -ec "$(grep showcerts <<<"$c")"
check_output "-CAfile: Verify return code 0 (from the note)" 'Verify return code: 0 \(ok\)' \
  bash -ec "$(grep -- -CAfile <<<"$c" | sed 's/-CAfile/-servername example.com -CAfile/')"
check_output "-tls1_2 forces TLS 1.2 (from the note)" 'Protocol *: TLSv1.2|TLSv1.2, Cipher' bash -ec "$(grep -- -tls1_2 <<<"$c") </dev/null"
check_output "-tls1_3 forces TLS 1.3 (from the note)" 'TLSv1.3' bash -ec "$(grep -- -tls1_3 <<<"$c") </dev/null"
# An unknown protocol name is refused before connecting; smtp and ldap go on to connect.
protos=$(openssl s_client -connect 127.0.0.1:1 -starttls bogus 2>&1 || true)
assert_match "-starttls refuses an unknown protocol and lists the valid ones" 'Value must be one of' "$protos"
assert_match "smtp is one of them" '^[[:space:]]*smtp$' "$protos"
assert_match "ldap is one of them" '^[[:space:]]*ldap$' "$protos"
for proto in smtp ldap; do
  check_output "-starttls $proto is accepted (it fails only at connect)" 'connect|Connection refused' \
    bash -c "openssl s_client -connect 127.0.0.1:1 -starttls $proto </dev/null 2>&1; true"
done
skip "STARTTLS against a mail and an LDAP server" "needs an SMTP and an LDAP server; only the option names are checked"
check_output "just the expiry (from the note)" '^notAfter=' bash -ec "$(sed -n '/Just the expiry/,$p' <<<"$c" | grep -v '^#')"
check_output "</dev/null makes s_client exit by itself" 'DONE|closed|CONNECTED' \
  timeout 10 bash -c 'openssl s_client -connect localhost:4433 </dev/null 2>&1'
check_fails "without it, s_client waits for input" timeout 3 bash -c 'sleep 10 | openssl s_client -connect localhost:4433 >/dev/null 2>&1'
kill %1
check "s_server -www serves TLS (from the note)" bash -ec "$(block s_client 3) >/dev/null 2>&1 & sleep 1; curl -sk https://localhost:4433/ | grep -q 'Ciphers supported'; kill %1"

section "Cipher suites"
check_output "ciphers -v with a filter (from the note)" 'ECDHE' run 'Cipher suites' 1
check_output "the TLS 1.3 suites" 'TLS_AES_256_GCM_SHA384' bash -c "$(block 'Cipher suites' 1 | sed -n 2p)"
check_fails "MD5 suites are filtered out" bash -c "$(block 'Cipher suites' 1 | sed -n 1p) | grep -q 'Mac=MD5'"

section "Miscellaneous"
m=$(block Miscellaneous 1)
check_output "rand -hex 32 gives 64 hex characters (from the note)" '^[0-9a-f]{64}$' bash -ec "$(sed -n 1p <<<"$m")"
check_output "rand -base64 32 (from the note)" '^[A-Za-z0-9+/]{43}=$' bash -ec "$(sed -n 2p <<<"$m")"
echo data >file.tar.gz
check_output "dgst -sha256 (from the note)" "^SHA2-256\\(file.tar.gz\\)= $(sha256sum file.tar.gz | cut -d' ' -f1)\$" bash -ec "$(sed -n 3p <<<"$m")"
check_output "speed rsa2048 ecdsap256 (from the note, 1 s per test)" 'rsa +2048 bits.*sign/s|256 bits ecdsa' \
  bash -ec "$(sed -n 4p <<<"$m" | sed 's/speed/speed -seconds 1/')"
openssl s_server -accept 4433 -cert srv.crt -key srv.key -www -quiet >/dev/null 2>&1 &
sleep 1
# s_time exits non-zero when the server closes connections early; the statistics are what matter.
check_output "s_time (from the note, against the local server for 2 s)" 'connections in' \
  bash -c "$(sed -n 5p <<<"$m" | local_) -time 2 -new 2>&1; true"
kill %1

section "A CSR without subjectAltName"
openssl req -new -key srv.key -subj /CN=cn-only.example.com 2>/dev/null |
  openssl x509 -req -CA ca.crt -CAkey ca.key -out cn-only.crt -days 1 2>/dev/null
check_fails "a certificate signed from a CSR with no SAN has no SAN" \
  bash -c 'openssl x509 -in cn-only.crt -noout -ext subjectAltName | grep -q DNS'
openssl s_server -accept 4436 -cert cn-only.crt -key srv.key -www -quiet >/dev/null 2>&1 &
retry 10 bash -c 'echo | openssl s_client -connect localhost:4436 >/dev/null 2>&1'
check "curl still accepts it, by falling back to the CN (as the note now says)" \
  curl -s -o /dev/null --cacert ca.crt --resolve cn-only.example.com:4436:127.0.0.1 https://cn-only.example.com:4436/
skip "browsers and Go refuse it" "no browser or Go toolchain in this image"
kill %1
