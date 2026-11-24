#!/usr/bin/env bash
# note: security/cryptography/pki-and-x509.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/cryptography/pki-and-x509
block() { note_block "$NOTE" "$@"; }
cd "$(mktemp -d)"

# ec KEY: a new P-256 key.
ec() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1"; }
# sign OUT SUBJ ISSUER_CRT ISSUER_KEY KEY [EXT...]: issue a certificate with req -x509 -CA.
sign() {
  local out=$1 subj=$2 ica=$3 ikey=$4 key=$5 a=() e
  shift 5
  for e in "$@"; do a+=(-addext "$e"); done
  openssl req -x509 -new -key "$key" -subj "$subj" -days "${DAYS:-2}" -CA "$ica" -CAkey "$ikey" "${a[@]}" -out "$out" 2>/dev/null
}
ec root.key && openssl req -x509 -new -key root.key -subj /CN=Root -days 2 -out root.pem \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign
ec int.key && sign intermediate.pem /CN=Intermediate root.pem root.key int.key \
  basicConstraints=critical,CA:TRUE,pathlen:0 keyUsage=critical,keyCertSign,cRLSign
ec leaf.key && sign leaf.pem "/C=US/ST=Example State/L=Example City/O=Example Corp/CN=www.example.com" \
  intermediate.pem int.key leaf.key "subjectAltName=DNS:www.example.com,DNS:*.example.com" \
  extendedKeyUsage=serverAuth keyUsage=critical,digitalSignature basicConstraints=critical,CA:FALSE

section "X.509"
check_output "every certificate here is version 3" 'Version: 3 \(0x2\)' openssl x509 -in leaf.pem -noout -text

section "Issuer and Subject"
check_output "openssl prints the DN in the note's one-line form" \
  "^subject=$(block 'Issuer and Subject' 1)\$" openssl x509 -in leaf.pem -noout -subject
ec cn.key && sign cn-only.pem /CN=www.example.com intermediate.pem int.key cn.key
check "OpenSSL itself still falls back to the CN when there is no SAN (as the note says)" \
  openssl verify -CAfile root.pem -untrusted intermediate.pem -verify_hostname www.example.com cn-only.pem
# Go's crypto/x509 stands in for a modern client: it ignores the CN, like browsers.
zypper -n -q install --no-recommends go >/dev/null
mkdir gocheck && cat >gocheck/main.go <<'GO'
package main

import (
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"os"
)

func load(p string) *x509.Certificate {
	b, _ := os.ReadFile(p)
	d, _ := pem.Decode(b)
	c, err := x509.ParseCertificate(d.Bytes)
	if err != nil {
		panic(err)
	}
	return c
}

func main() {
	roots, inter := x509.NewCertPool(), x509.NewCertPool()
	roots.AddCert(load("root.pem"))
	inter.AddCert(load("intermediate.pem"))
	_, err := load(os.Args[1]).Verify(x509.VerifyOptions{Roots: roots, Intermediates: inter, DNSName: os.Args[2]})
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	fmt.Println("OK")
}
GO
(cd gocheck && go mod init gocheck >/dev/null 2>&1 && go build -o ../gocheck.bin .)
check_output "a modern client (Go) rejects the CN-only certificate" 'legacy Common Name field' \
  bash -c './gocheck.bin cn-only.pem www.example.com; true'
check_output "and accepts the certificate with a SAN" '^OK$' ./gocheck.bin leaf.pem www.example.com
skip "browsers ignore the CN" "needs a browser; Go's verifier stood in for one"

section "Extensions"
ski=$(openssl x509 -in leaf.pem -noout -ext subjectKeyIdentifier | tail -1 | tr -d ' :' | tr 'A-F' 'a-f')
# For P-256, the subjectPublicKey bits are the last 65 bytes of the DER public key.
sha1=$(openssl pkey -in leaf.key -pubout -outform DER | tail -c 65 | openssl dgst -sha1 -r | cut -d' ' -f1)
assert_eq "the SKI is the SHA-1 of the public key (160 bits)" "$sha1" "$ski"
aki=$(openssl x509 -in leaf.pem -noout -ext authorityKeyIdentifier | tail -1 | tr -d ' :' | tr 'A-F' 'a-f')
iski=$(openssl x509 -in intermediate.pem -noout -ext subjectKeyIdentifier | tail -1 | tr -d ' :' | tr 'A-F' 'a-f')
assert_eq "the leaf's AKI is the issuer's SKI" "$iski" "${aki#keyid}"

section "Wildcard certificates"
v() { openssl verify -CAfile root.pem -untrusted intermediate.pem -verify_hostname "$1" leaf.pem; }
check "*.example.com matches login.example.com" v login.example.com
check_fails "and not the parent example.com" v example.com
check_fails "and not a deeper name a.b.example.com" v a.b.example.com

section "Certificate signing requests"
ec req.key
openssl req -new -key req.key -subj /CN=app.example.com -addext subjectAltName=DNS:app.example.com -out app.csr
openssl x509 -req -in app.csr -CA intermediate.pem -CAkey int.key -days 1 -out plain.pem 2>/dev/null
check_fails "x509 -req drops the CSR's SAN by default (the correction)" \
  bash -c 'openssl x509 -in plain.pem -noout -ext subjectAltName | grep -q DNS'
openssl x509 -req -in app.csr -CA intermediate.pem -CAkey int.key -days 1 -copy_extensions copy -out copied.pem 2>/dev/null
cp copied.pem cert.pem
check_output "-copy_extensions copy keeps it; the note's check shows it" 'DNS:app.example.com' \
  bash -ec "$(block 'Certificate signing requests' 2)"
mkdir -p ca && touch ca/index.txt && echo 01 >ca/serial
printf '[ca]\ndefault_ca=c\n[c]\ndir=ca\ndatabase=$dir/index.txt\nserial=$dir/serial\nnew_certs_dir=$dir\ndefault_md=sha256\npolicy=p\ndefault_days=1\nunique_subject=no\n[p]\ncommonName=supplied\n' >ca.cnf
openssl ca -batch -config ca.cnf -cert intermediate.pem -keyfile int.key -in app.csr -out ca-default.pem 2>/dev/null
check_fails "openssl ca without copy_extensions drops it too" \
  bash -c 'openssl x509 -in ca-default.pem -noout -ext subjectAltName | grep -q DNS'
sed 's/^policy=p$/&\ncopy_extensions=copy/' ca.cnf >ca-copy.cnf
openssl ca -batch -config ca-copy.cnf -cert intermediate.pem -keyfile int.key -in app.csr -out ca-copy.pem 2>/dev/null
check_output "and keeps it with copy_extensions" 'DNS:app.example.com' openssl x509 -in ca-copy.pem -noout -ext subjectAltName

section "How a chain is actually verified"
check "leaf + intermediate verify against the root alone" \
  openssl verify -CAfile root.pem -untrusted intermediate.pem leaf.pem
check_fails "without the intermediate there is no path" openssl verify -CAfile root.pem leaf.pem
check_output "a plain verify passes for any name: it does not check one" ': OK$' \
  openssl verify -CAfile root.pem -untrusted intermediate.pem leaf.pem
check "the note's -verify_hostname command (from the note)" bash -ec "$(block 'How a chain' 1)"
check_fails "and it fails for another name" openssl verify -CAfile root.pem -untrusted intermediate.pem \
  -verify_hostname www.example.org leaf.pem
# Signatures: a certificate signed by another key does not verify.
ec other.key && openssl req -x509 -new -key other.key -subj /CN=Intermediate -days 2 -out fake-int.pem \
  -addext basicConstraints=critical,CA:TRUE
check_output "a wrong issuer key: signature failure" 'certificate signature failure|unable to get local issuer' \
  bash -c 'openssl verify -CAfile root.pem -untrusted fake-int.pem leaf.pem 2>&1; true'
# Dates on every certificate, not only the leaf.
ec old.key && openssl req -x509 -new -key old.key -subj /CN=OldInt -not_before 20200101000000Z -not_after 20210101000000Z \
  -CA root.pem -CAkey root.key -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign -out old-int.pem 2>/dev/null
ec l2.key && sign leaf2.pem /CN=l2.example.com old-int.pem old.key l2.key subjectAltName=DNS:l2.example.com
check_output "an expired intermediate fails, at depth 1" 'error 10 at 1 depth lookup: certificate has expired' \
  bash -c 'openssl verify -CAfile root.pem -untrusted old-int.pem leaf2.pem 2>&1; true'
# basicConstraints: a leaf cannot issue.
ec x.key && sign by-leaf.pem /CN=evil.example.com leaf.pem leaf.key x.key subjectAltName=DNS:evil.example.com
check_output "a certificate issued by a CA:FALSE leaf is rejected" 'invalid CA certificate' \
  bash -c 'cat intermediate.pem leaf.pem >u.pem; openssl verify -CAfile root.pem -untrusted u.pem by-leaf.pem 2>&1; true'
# pathlen:0 on the intermediate: no CA below it.
ec sub.key && sign sub.pem /CN=Sub intermediate.pem int.key sub.key basicConstraints=critical,CA:TRUE keyUsage=critical,keyCertSign
ec l3.key && sign leaf3.pem /CN=l3.example.com sub.pem sub.key l3.key subjectAltName=DNS:l3.example.com
check_output "pathlen:0 stops a further CA below the intermediate" 'path length constraint exceeded' \
  bash -c 'cat intermediate.pem sub.pem >u2.pem; openssl verify -CAfile root.pem -untrusted u2.pem leaf3.pem 2>&1; true'
# keyUsage and extendedKeyUsage.
ec nk.key && sign nokcs.pem /CN=NoKCS root.pem root.key nk.key basicConstraints=critical,CA:TRUE keyUsage=critical,digitalSignature
ec l4.key && sign leaf4.pem /CN=l4.example.com nokcs.pem nk.key l4.key
check_fails "a CA without keyCertSign cannot issue" openssl verify -CAfile root.pem -untrusted nokcs.pem leaf4.pem
ec cl.key && sign client.pem /CN=client intermediate.pem int.key cl.key extendedKeyUsage=clientAuth
check "a clientAuth-only certificate verifies as a client" \
  openssl verify -CAfile root.pem -untrusted intermediate.pem -purpose sslclient client.pem
check_fails "but not as a server: it lacks serverAuth" \
  openssl verify -CAfile root.pem -untrusted intermediate.pem -purpose sslserver client.pem
