#!/usr/bin/env bash
# note: security/cryptography/foundations.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/cryptography/foundations
block() { note_block "$NOTE" "$@"; }
cd "$(mktemp -d)"
zypper -n -q install --no-recommends argon2 xxd >/dev/null

section "Symmetric encryption"
echo "top secret" >secret.txt
# The note's commands prompt for the passphrase; give it on the command line here.
check "encrypt with AES-256-CBC and PBKDF2 (from the note)" \
  bash -ec "$(block 'Symmetric encryption' 1 | sed -n 1,3p | sed 's/-salt/-salt -pass pass:pw/')"
rm secret.txt
check "decrypt (from the note)" bash -ec "$(block 'Symmetric encryption' 1 | sed -n 5,7p | sed 's/-iter 600000/-iter 600000 -pass pass:pw/')"
check_output "the plaintext is back" '^top secret$' cat secret.txt
check_fails "the wrong passphrase fails" openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass pass:bad -in secret.enc -out /dev/null
check_output "openssl speed -evp aes-256-gcm runs (from the note)" 'AES-256-GCM' \
  bash -c "$(block 'Symmetric encryption' 2 | sed -n 1p | sed 's/^\$ //; s/#.*//; s/speed/speed -seconds 1/')"
check_output "openssl speed rsa2048 runs (from the note)" 'rsa2048' \
  bash -c "$(block 'Symmetric encryption' 2 | sed -n 2p | sed 's/^\$ //; s/#.*//; s/speed/speed -seconds 1/')"

section "Modes of operation"
K=000102030405060708090a0b0c0d0e0f; IV=00000000000000000000000000000000
printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' >two-blocks
ecb=$(openssl enc -aes-128-ecb -K $K -nopad -in two-blocks | xxd -p -c 16)
assert_eq "ECB: two identical plaintext blocks give identical ciphertext blocks" \
  "$(sed -n 1p <<<"$ecb")" "$(sed -n 2p <<<"$ecb")"
cbc=$(openssl enc -aes-128-cbc -K $K -iv $IV -nopad -in two-blocks | xxd -p -c 16)
assert_no_match "CBC: the same two blocks differ" "^$(sed -n 1p <<<"$cbc")\$" "$(sed -n 2p <<<"$cbc")"
# Flip the lowest bit of byte 0 of ciphertext block 1: byte 0 of plaintext block 2 flips too.
openssl enc -aes-128-cbc -K $K -iv $IV -nopad -in two-blocks -out c.bin
first=$(xxd -p -l 1 c.bin)
printf '%b' "$(printf '\\x%02x' $((0x$first ^ 1)))" | dd of=c.bin bs=1 count=1 conv=notrunc 2>/dev/null
out=$(openssl enc -d -aes-128-cbc -K $K -iv $IV -nopad -in c.bin | tail -c 16)
assert_eq "CBC is malleable: one flipped ciphertext bit flips the same plaintext bit in the next block" \
  "@AAAAAAAAAAAAAAA" "$out"

section "AEAD"
check_output "openssl enc refuses AEAD ciphers (the correction)" 'AEAD ciphers not supported' \
  bash -c 'openssl enc -aes-256-gcm -pbkdf2 -pass pass:x -in secret.txt -out /dev/null 2>&1; true'
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout recipient.key \
  -subj /CN=recipient -days 1 -out recipient.crt 2>/dev/null
check "cms encrypts with AES-256-GCM (from the note)" bash -ec "$(block AEAD 2 | sed -n 2p)"
check_output "the CMS message is AuthEnvelopedData" 'authEnvelopedData|id-smime-ct-authEnvelopedData' \
  openssl cms -cmsout -print -in secret.cms
rm secret.txt
check "and decrypts (from the note)" bash -ec "$(block AEAD 2 | sed -n 3p)"
check_output "to the same text" '^top secret$' cat secret.txt
openssl cms -encrypt -aes-256-gcm -in secret.txt -out text.cms recipient.crt
check_output "without -binary, the line ending becomes CRLF (as the note warns)" '0d0a$' \
  bash -c 'openssl cms -decrypt -in text.cms -inkey recipient.key | xxd -p'

section "Hash functions"
console=$(block 'Hash functions' 1)
check_output "SHA-256 of hello (from the note)" "$(sed -n 2p <<<"$console" | sed 's/[()]/./g')" \
  bash -c "$(sed -n 1p <<<"$console" | sed 's/^\$ //')"
check_output "SHA-256 of hellp (from the note)" "$(sed -n 5p <<<"$console" | sed 's/[()]/./g')" \
  bash -c "$(sed -n 4p <<<"$console" | sed 's/^\$ //')"

section "MACs"
echo '{"event":"push"}' >payload.json
check_output "HMAC-SHA256 of a payload (from the note)" '^HMAC-SHA2-256\(payload.json\)= [0-9a-f]{64}$' \
  bash -ec "$(block MACs 1)"
h1=$(openssl dgst -sha256 -hmac "shared-secret" payload.json)
h2=$(openssl dgst -sha256 -hmac "other-secret" payload.json)
assert_no_match "another key gives another MAC" "${h1##*= }" "$h2"

section "Deriving keys"
check_output "argon2id via the reference CLI (from the note)" '^Encoded:.*\$argon2id\$v=19\$m=65536,t=3,p=4\$' \
  bash -ec "$(block 'From a password' 1)"
check_output "HKDF with openssl kdf (from the note)" '^([0-9A-F]{2}:){31}[0-9A-F]{2}$' \
  bash -ec "$(block 'From an existing key' 1)"
a=$(bash -ec "$(block 'From an existing key' 1 | sed 's/tls13 client traffic/encryption/')")
b=$(bash -ec "$(block 'From an existing key' 1 | sed 's/tls13 client traffic/mac/')")
assert_no_match "another info label gives an independent key" "^$a\$" "$b"

section "Asymmetric cryptography"
check "Ed25519, RSA-3072 and P-256 keys (from the note)" bash -ec "$(block 'Asymmetric cryptography' 1)"
check_output "the RSA key is 3072 bits" '3072 bit' openssl pkey -in rsa.pem -noout -text
check_output "the EC key is on P-256" 'NIST CURVE: P-256' openssl pkey -in ec.pem -noout -text
check_output "openssl speed rsa2048 rsa4096 ecdsap256 runs" 'ecdsa \(nistp256\)' \
  openssl speed -seconds 1 rsa2048 rsa4096 ecdsap256
openssl pkey -in rsa.pem -pubout -out rsa.pub
head -c 64 /dev/urandom >m
check_output "pkeyutl's default RSA padding is still PKCS#1 v1.5" 'oaep decoding error' bash -c \
  'openssl pkeyutl -encrypt -pubin -inkey rsa.pub -in m -out c && openssl pkeyutl -decrypt -inkey rsa.pem -pkeyopt rsa_padding_mode:oaep -in c 2>&1; true'

section "Key agreement"
check "X25519 keys and the two derivations (from the note)" bash -ec "$(block 'Key agreement' 2 | sed '/-derive/d')"
s1=$(bash -ec "$(block 'Key agreement' 2 | grep -- '-derive' | sed -n 1p)")
s2=$(bash -ec "$(block 'Key agreement' 2 | grep -- '-derive' | sed -n 2p)")
assert_match "a 32-byte secret" '^00000010: ' "$s1"
assert_eq "both sides derive the same secret" "$s1" "$s2"

section "Digital signatures"
head -c 100000 /dev/urandom >release.tar.gz
check_output "Ed25519 sign and verify (from the note)" '^Signature Verified Successfully$' bash -ec "$(block 'Digital signatures' 1)"
echo x >>release.tar.gz
check_fails "a changed file no longer verifies" openssl pkeyutl -verify -pubin -inkey public.pem -rawin \
  -in release.tar.gz -sigfile release.sig

section "Hybrid encryption"
openssl genpkey -algorithm RSA -out r2048.pem 2>/dev/null
openssl pkey -in r2048.pem -pubout -out r2048.pub
oaep() { head -c "$1" /dev/urandom | openssl pkeyutl -encrypt -pubin -inkey r2048.pub -pkeyopt rsa_padding_mode:oaep "${@:2}" -out /dev/null; }
check "RSA-2048 OAEP-SHA-256 encrypts 190 bytes" oaep 190 -pkeyopt rsa_oaep_md:sha256
check_fails "and not 191" oaep 191 -pkeyopt rsa_oaep_md:sha256
check "with the default OAEP digest (SHA-1), 214 bytes" oaep 214
check_fails "and not 215" oaep 215

section "Randomness"
check_output "rand -hex 32 (from the note)" '^[0-9a-f]{64}$' bash -ec "$(block Randomness 1 | sed -n 1p)"
check_output "rand -base64 32 (from the note)" '^[A-Za-z0-9+/]{43}=$' bash -ec "$(block Randomness 1 | sed -n 2p)"
