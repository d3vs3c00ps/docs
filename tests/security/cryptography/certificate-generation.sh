#!/usr/bin/env bash
# note: security/cryptography/certificate-generation.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/cryptography/certificate-generation
block() { note_block "$NOTE" "$@"; }
ext() { openssl x509 -in "$1" -noout -ext "$2"; }
cd "$(mktemp -d)"
W=$PWD

section "Route 1 — one certificate, no state"
mkdir r1 && cd r1
block 'Route 1' 1 >generate.sh
check "the script parses" bash -n generate.sh
check "the usage example runs it (from the note)" bash -ec "$(block Usage 1 | sed 's|^\./generate.sh|bash generate.sh|')"
CRT=certs/bastion-01.example.com.crt
check_output "the CA is marked as a CA, with pathlen:0" 'critical.*'$'\n''.*CA:TRUE, pathlen:0' ext ca/ExampleCA.crt basicConstraints
check_output "the CA has keyCertSign" 'Certificate Sign' ext ca/ExampleCA.crt keyUsage
check_output "the server certificate has the DNS and IP SAN" 'DNS:bastion-01.example.com, DNS:bastion.example.com, IP Address:10.0.0.5' ext "$CRT" subjectAltName
check_output "and serverAuth" 'TLS Web Server Authentication' ext "$CRT" extendedKeyUsage
check_output "and no nonRepudiation or dataEncipherment" '^ *Digital Signature, Key Encipherment$' ext "$CRT" keyUsage
check_output "the key and certificate files are mode 600" '^600 600$' \
  bash -c 'echo "$(stat -c %a ca/ExampleCA.key) $(stat -c %a private/bastion-01.example.com.key)"'
check_output "it keeps the serial file" '^[0-9A-F]+$' cat ca/ExampleCA.srl
mkdir ../r1b && cd ../r1b
bash ../r1/generate.sh -c Lab -s other.example.com >/dev/null 2>&1
check_output "with no -a, the SAN defaults to the CN" 'DNS:other.example.com' ext certs/other.example.com.crt subjectAltName
check_output "without -d, the default is 3650 days" 'notAfter=' bash -c \
  'end=$(date -d "$(openssl x509 -in certs/other.example.com.crt -noout -enddate | cut -d= -f2)" +%s); [ $(( (end - $(date +%s)) / 86400 )) -ge 3649 ] && echo notAfter=ok'
cd "$W/r1"
openssl x509 -req -in csr/bastion-01.example.com.csr -CA ca/ExampleCA.crt -CAkey ca/ExampleCA.key \
  -CAserial ca/ExampleCA.srl -out noext.crt -days 1 2>/dev/null
check_fails "without -extfile, x509 -req drops the SAN in the CSR (as the note warns)" \
  bash -c 'openssl x509 -in noext.crt -noout -ext subjectAltName | grep -q DNS'
openssl x509 -req -in csr/bastion-01.example.com.csr -CA ca/ExampleCA.crt -CAkey ca/ExampleCA.key \
  -CAserial ca/ExampleCA.srl -copy_extensions copy -out copied.crt -days 1 2>/dev/null
check_output "-copy_extensions copy keeps it (OpenSSL 3)" 'DNS:bastion.example.com' ext copied.crt subjectAltName
s1=$(openssl x509 -in noext.crt -noout -serial); s2=$(openssl x509 -in copied.crt -noout -serial)
assert_no_match "with the .srl kept, the next certificate gets another serial" "^$s1\$" "$s2"
mv ca/ExampleCA.srl keep.srl
openssl x509 -req -in csr/bastion-01.example.com.csr -CA ca/ExampleCA.crt -CAkey ca/ExampleCA.key -CAcreateserial -out a.crt 2>/dev/null
rm ca/ExampleCA.srl
openssl x509 -req -in csr/bastion-01.example.com.csr -CA ca/ExampleCA.crt -CAkey ca/ExampleCA.key -CAcreateserial -out b.crt 2>/dev/null
mv keep.srl ca/ExampleCA.srl
sa=$(openssl x509 -in a.crt -noout -serial | cut -d= -f2); sb=$(openssl x509 -in b.crt -noout -serial | cut -d= -f2)
assert_match "with no .srl, -CAcreateserial starts from a random 160-bit serial (the correction)" '^[0-9A-F]{38,40}$' "$sa"
assert_no_match "so deleting it does not repeat a serial" "^$sa\$" "$sb"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout sub.key -subj /CN=Sub -days 1 \
  -CA ca/ExampleCA.crt -CAkey ca/ExampleCA.key -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign -out sub.crt 2>/dev/null
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout l.key -subj /CN=l -days 1 \
  -CA sub.crt -CAkey sub.key -out l.crt 2>/dev/null
check_output "pathlen:0: the CA cannot issue an intermediate" 'path length constraint exceeded' \
  bash -c 'openssl verify -CAfile ca/ExampleCA.crt -untrusted sub.crt l.crt 2>&1; true'

section "Route 2 — a CA you keep"
mkdir "$W/r2" && cd "$W/r2"
block 'ca.cnf' 1 >ca.cnf
block 'san.cfg' 1 >san.cfg
block 'The generation script' 1 >gen.sh
check "the generation script runs (from the note)" bash gen.sh
check_output "the layout matches the note" 'ca/ca_example.com/db/ca_example.com.crl.srl' find ca -type f
D=cluster.internal.example.com
check "the certificate verifies against the CA" openssl verify -CAfile ca/ca_example.com/ca_example.com.crt $D.crt
check_output "it has every SAN from san.cfg" 'DNS:cluster.internal.example.com, DNS:node-01.internal.example.com, DNS:node-02.internal.example.com, DNS:node-03.internal.example.com, IP Address:10.0.0.11, IP Address:10.0.0.12, IP Address:10.0.0.13' \
  ext $D.crt subjectAltName
check_output "serverAuth and clientAuth, for mutual TLS" 'TLS Web Server Authentication, TLS Web Client Authentication' ext $D.crt extendedKeyUsage
check_output "keyUsage comes from [ server_cert ], not from the CSR" '^ *Digital Signature, Key Encipherment$' ext $D.crt keyUsage
check_output "the CA certificate lasts ten years, thanks to -days" '20(3[5-9])' \
  openssl x509 -in ca/ca_example.com/ca_example.com.crt -noout -enddate
openssl req -new -x509 -key ca/ca_example.com/private/ca_example.com.key -out no-days.crt -config ca.cnf
check_output "without -days, req -x509 makes a 30-day CA (the correction)" '^30$' bash -c \
  'echo $(( ($(date -d "$(openssl x509 -in no-days.crt -noout -enddate | cut -d= -f2)" +%s) - $(date -d "$(openssl x509 -in no-days.crt -noout -startdate | cut -d= -f2)" +%s)) / 86400 ))'
check_output "the CA certificate is a CA with keyCertSign" 'CA:TRUE' ext ca/ca_example.com/ca_example.com.crt basicConstraints
console=$(block 'Issuing more certificates' 2)
check_output "the index has the note's line" \
  "^V	[0-9]{12}Z		01	unknown	/C=FR/ST=Example State/L=Example City/O=Example Corp/CN=cluster.internal.example.com\$" \
  cat ca/ca_example.com/db/ca_example.com.db
assert_match "and the note's sample has the same shape" '^V	[0-9]{12}Z		01	unknown	/C=FR/' "$(sed -n 2p <<<"$console")"
sed 's/^commonName *=.*/commonName          = node-04.internal.example.com/' san.cfg >san-node-04.cfg
check "issuing node-04 (from the note)" bash -ec "$(block 'Issuing more certificates' 1)"
check_output "the index now has two lines" '^2$' bash -c 'wc -l <ca/ca_example.com/db/ca_example.com.db'
# copy_extensions = copy: only extensions missing from [ server_cert ] come from the CSR.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out evil.key
openssl req -new -key evil.key -subj /CN=evil -addext basicConstraints=critical,CA:TRUE -out evil.csr
openssl ca -batch -config ca.cnf -out evil.crt -infiles evil.csr 2>/dev/null
check_output "with this config, a CSR asking for CA:TRUE still gets CA:FALSE" 'CA:FALSE' ext evil.crt basicConstraints
sed 's/^x509_extensions         = server_cert$/x509_extensions         = no_bc/; $a [ no_bc ]\nsubjectKeyIdentifier = hash' ca.cnf >ca-nobc.cnf
openssl ca -batch -config ca-nobc.cnf -out evil2.crt -infiles evil.csr 2>/dev/null
check_output "with no basicConstraints in the extension section, the CSR mints a CA" 'CA:TRUE' ext evil2.crt basicConstraints

section "Revoking a certificate"
check "revoke, gencrl, print (from the note)" bash -ec "$(block 'Revoking a certificate' 1)"
check_output "the index marks it R" '^R	' cat ca/ca_example.com/db/ca_example.com.db
check_output "the CRL lists serial 01" 'Serial Number: 01' openssl crl -in ca/ca_example.com/ca_example.com.crl -noout -text
console=$(block 'Revoking a certificate' 2)
check_output "plain verify still says OK (from the note)" "$(sed -n 2p <<<"$console" | sed 's/ *#.*//')" \
  bash -c "$(sed -n 1p <<<"$console" | sed 's/^\$ //')"
cmd=$(sed -n '/^\$ cat/p; /^\$ openssl verify -crl_check/p' <<<"$console" | sed 's/^\$ //' | paste -sd ';')
out=$(bash -c "$cmd" 2>&1 || true)
assert_match "with -crl_check: the note's error 23 line" "$(sed -n 6p <<<"$console")" "$out"
assert_match "and the note's last line" "$(sed -n 7p <<<"$console")" "$out"
check_fails "and it exits non-zero" bash -c "$cmd"
check_output "-CRLfile gives the same result without a bundle (from the note)" 'certificate revoked' \
  bash -c "$(block 'Revoking a certificate' 3) 2>&1; true"

section "Trusting the CA (openSUSE Leap)"
cd "$W/r1"
check_fails "before: the system store does not trust the lab CA" openssl verify certs/bastion-01.example.com.crt
check "copy and update-ca-certificates (from the note)" bash -ec "$(block 'Trusting the CA' 1 | sed 's/^sudo //')"
check "after: openssl verify trusts it with no -CAfile" openssl verify certs/bastion-01.example.com.crt
skip "RHEL and Debian trust stores" "RHEL is tested in certificate-generation.rocky.sh; no Debian test environment"

section "Verifying the result"
check_output "SAN check (from the note)" 'DNS:bastion-01.example.com' bash -ec "$(block 'Verifying the result' 1)"
check_output "chain check (from the note)" ': OK$' bash -ec "$(block 'Verifying the result' 2)"
check "key and certificate match (from the note)" bash -ec "$(block 'Verifying the result' 3)"
check_fails "a different key does not match" bash -c \
  'diff <(openssl x509 -in certs/bastion-01.example.com.crt -noout -pubkey) <(openssl pkey -in ../r1b/private/other.example.com.key -pubout)'
echo "127.0.0.1 bastion-01.example.com other.example.com" >>/etc/hosts
cat certs/bastion-01.example.com.crt >chain.pem
openssl s_server -accept 443 -cert chain.pem -key private/bastion-01.example.com.key -quiet </dev/null >/dev/null 2>&1 &
sleep 1
check_output "s_client end to end (from the note)" 'Verify return code: 0 \(ok\)' \
  bash -c "$(block 'Verifying the result' 4) </dev/null 2>&1"
check_output "s_client alone does not check the name: another name still says ok" 'Verify return code: 0 \(ok\)' \
  bash -c 'openssl s_client -connect other.example.com:443 -servername other.example.com -CAfile ca/ExampleCA.crt </dev/null 2>&1'
check_output "with -verify_hostname it does (the correction)" 'Verify return code: 62 \(hostname mismatch\)' \
  bash -c 'openssl s_client -connect other.example.com:443 -servername other.example.com -verify_hostname other.example.com -CAfile ca/ExampleCA.crt </dev/null 2>&1'
kill %1
