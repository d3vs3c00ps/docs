#!/usr/bin/env bash
# note: security/cryptography/openssl/signing.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/cryptography/openssl/signing
block() { note_block "$NOTE" "$@"; }
run() { bash -ec "$(block "$@")"; }
cd "$(mktemp -d)"
head -c 100000 /dev/urandom >file.tar.gz
echo "hello" >file.txt
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out key.pem
openssl pkey -in key.pem -pubout -out pub.pem

section "Hashing"
out=$(run Hashing 1)
sum=$(sha256sum file.tar.gz | cut -d' ' -f1)
assert_match "openssl dgst prints the SHA-256 (from the note)" "= $sum\$" "$(sed -n 1p <<<"$out")"
assert_match "sha256sum prints the same hash" "^$sum " "$(sed -n 2p <<<"$out")"
assert_eq "the binary digest in base64 is the same hash" "$sum" \
  "$(sed -n 3p <<<"$out" | openssl base64 -d | od -An -tx1 | tr -d ' \n')"

section "HMAC"
check_output "HMAC-SHA256 with a shared secret (from the note)" '^HMAC-SHA2-256\(file.txt\)= [0-9a-f]{64}$' run HMAC 1
a=$(openssl dgst -sha256 -hmac "shared-secret" file.txt)
b=$(openssl dgst -sha256 -hmac "other-secret" file.txt)
check_fails "another secret gives another HMAC" test "$a" = "$b"

section "Signing data"
s=$(block 'Signing data' 1)
check "pkeyutl sign over the digest (from the note)" bash -ec "$(sed -n '2,4p' <<<"$s")"
check_output "and verify (from the note)" 'Signature Verified Successfully' bash -ec "$(sed -n '7,9p' <<<"$s")"
echo x >>file.tar.gz
check_fails "a changed file no longer verifies" bash -ec "$(sed -n '7,9p' <<<"$s")"
head -c -2 file.tar.gz >t && mv t file.tar.gz
openssl genpkey -algorithm ED25519 -out ed25519.pem
openssl pkey -in ed25519.pem -pubout -out ed25519-pub.pem
check_output "Ed25519 signs the file itself with -rawin (from the note)" 'Signature Verified Successfully' run 'Signing data' 2
check_fails "Ed25519 refuses a digest option" \
  openssl pkeyutl -sign -inkey ed25519.pem -rawin -in file.tar.gz -pkeyopt digest:sha256 -out /dev/null
check_output "dgst -sign and -verify (from the note)" 'Verified OK' run 'Signing data' 3
check_output "dgst -sign with -sigopt PSS works (the correction)" 'Verified OK' run 'Signing data' 4
check_fails "a PSS signature fails with the default PKCS#1 v1.5 verify" \
  openssl dgst -sha256 -verify pub.pem -signature file.sig file.tar.gz

section "RSA-PSS"
openssl dgst -sha256 -binary file.tar.gz >file.sha256
check_output "pkeyutl PSS sign and verify (from the note)" 'Signature Verified Successfully' run RSA-PSS 1
check_fails "verifying the PSS signature without the PSS options fails (as the note says)" \
  openssl pkeyutl -verify -pubin -inkey pub.pem -in file.sha256 -sigfile file.sig -pkeyopt digest:sha256
openssl pkeyutl -sign -inkey key.pem -in file.sha256 -pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pss \
  -pkeyopt rsa_pss_saltlen:-1 -out sig2
check_fails "PSS is randomised: two signatures of the same digest differ" cmp -s file.sig sig2

section "Encrypting with a public key"
echo "a secret" >secret.txt
check "OAEP encrypt and decrypt (from the note)" run 'Encrypting with a public key' 1
check_output "the round trip gives the secret back" '^a secret$' cat secret.txt
head -c 190 /dev/zero >m190 && head -c 191 /dev/zero >m191
oaep() { openssl pkeyutl -encrypt -pubin -inkey pub.pem -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 -in "$1" -out /dev/null; }
check "RSA-2048 with OAEP-SHA256 takes 190 bytes (as the note says)" oaep m190
check_fails "and not 191" oaep m191
check_output "rsautl is deprecated in OpenSSL 3 (as the note says)" 'deprecated in version 3.0' \
  bash -c 'openssl rsautl -help 2>&1; true'
openssl pkeyutl -encrypt -pubin -inkey pub.pem -in secret.txt -out def.enc
check "pkeyutl with no padding option uses PKCS#1 v1.5 (as the note says)" \
  openssl pkeyutl -decrypt -inkey key.pem -pkeyopt rsa_padding_mode:pkcs1 -in def.enc -out /dev/null

section "Symmetric encryption"
cp file.txt orig.txt
# The passphrase prompt needs a terminal; give it with -pass.
check "enc with PBKDF2 (from the note)" bash -ec "$(block 'Symmetric encryption' 1 | sed '/-in /s/$/ -pass pass:test/')"
check "the decrypted file matches" cmp file.txt orig.txt
check_output "without -pbkdf2, OpenSSL 3 warns (as the note says)" 'deprecated key derivation used' \
  bash -c 'echo x | openssl enc -aes-256-cbc -pass pass:x 2>&1 >/dev/null'
kdf() { openssl enc -aes-256-cbc -pass pass:x -S 0011223344556677 -P "$@" 2>/dev/null | grep '^key'; }
assert_eq "the legacy default hash is SHA-256, not MD5 (the correction)" "$(kdf -md sha256)" "$(kdf)"
check_fails "MD5 gives another key" test "$(kdf -md md5)" = "$(kdf)"
# 64 bytes: a change in the first block leaves the last block, and so the padding, intact.
head -c 64 /dev/zero | tr '\0' 'a' >plain.txt
openssl enc -aes-256-cbc -pbkdf2 -iter 1000 -pass pass:x -in plain.txt -out e.bin
printf '\x01' | dd of=e.bin bs=1 seek=16 conv=notrunc 2>/dev/null
check "enc has no authentication: a changed ciphertext decrypts with no error (as the note says)" \
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 1000 -pass pass:x -in e.bin -out changed.txt
check_fails "and the output is silently different" cmp -s plain.txt changed.txt

section "CMS"
openssl req -x509 -key key.pem -out cert.pem -days 1 -subj "/CN=Signer" 2>/dev/null
cp cert.pem ca.crt
cp cert.pem recipient-cert.pem
c=$(block CMS 1)
check "cms -sign -nodetach (from the note)" bash -ec "$(sed -n '2,3p' <<<"$c")"
rm -f file.txt
check_output "cms -verify gives the content back (from the note)" 'Verification successful' \
  bash -ec "$(sed -n 6p <<<"$c") 2>&1"
check_output "file.txt is restored" '^hello$' cat file.txt
check_fails "byte for byte, with LF line endings (-binary)" grep -q $'\r' file.txt
openssl cms -sign -in file.txt -signer cert.pem -inkey key.pem -nodetach -out text.p7s -outform PEM
openssl cms -verify -in text.p7s -inform PEM -CAfile ca.crt -out text.out 2>/dev/null
check "without -binary, the content comes back with CRLF line endings (the correction)" grep -q $'\r' text.out
openssl cms -sign -in file.txt -signer cert.pem -inkey key.pem -out det.p7s -outform PEM
check_fails "without -nodetach the signature is detached and -verify fails (the correction)" \
  openssl cms -verify -in det.p7s -inform PEM -CAfile ca.crt -out /dev/null
check "a detached signature verifies with -content" \
  openssl cms -verify -in det.p7s -inform PEM -CAfile ca.crt -content file.txt -out /dev/null
cp file.txt orig.txt
check "cms -encrypt with AES-256-GCM (from the note)" bash -ec "$(sed -n '9,10p' <<<"$c")"
check_output "it is AuthEnvelopedData" 'authEnvelopedData|id-smime-ct-authEnvelopedData' \
  bash -c 'openssl cms -cmsout -print -in file.p7m -inform PEM | head -5'
check "cms -decrypt (from the note)" bash -ec "$(sed -n 12p <<<"$c")"
check "the decrypted file matches" cmp file.txt orig.txt
head -c 1000000 /dev/urandom >big.bin
check "CMS encrypts a 1 MB file: no RSA size limit" \
  openssl cms -encrypt -in big.bin -out big.p7m -aes-256-gcm recipient-cert.pem

section "Signing container images and artifacts"
skip "cosign sign-blob and verify-blob" "cosign belongs to the supply-chain/cosign note; this test is about openssl"
