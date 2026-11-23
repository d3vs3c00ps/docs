#!/usr/bin/env bash
# note: security/boot-integrity/secure-boot.md
# env: rocky
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/boot-integrity/secure-boot
block() { note_block "$NOTE" "$@"; }
sudo() { "$@"; }
export -f sudo
# The note is written for x86_64. On arm64 the same files end in aa64 instead of x64.
case $(uname -m) in x86_64) A=x64 ;; aarch64) A=aa64 ;; esac
arch() { sed -e "s/shimx64/shim$A/g" -e "s/grubx64/grub$A/g"; }
# The packages put the real, signed EFI binaries under /boot/efi, as on an installed
# system. Nothing is enrolled or booted: there is no firmware in a container.
dnf -y -q install "shim-$A" "grub2-efi-$A" pesign mokutil binutils kernel-core kernel-devel \
  openssl nss-tools xz python3 >/dev/null 2>&1
KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core | tail -1)
cd "$(mktemp -d)"

section "The files on the ESP"
esp=$(bash -c "$(block 'The files on the ESP' 1)" 2>&1)
assert_match "the vendor directory is EFI/rocky/ on Rocky (from the note)" '/boot/efi/EFI/rocky/' "$esp"
for f in "shim$A.efi" "grub$A.efi" "mm$A.efi"; do
  assert_match "it holds $f" "$f" "$esp"
done
check "fallback and the removable-media copy of shim are in EFI/BOOT/" \
  bash -c "ls /boot/efi/EFI/BOOT/ | grep -qi 'BOOT${A}.EFI' && ls /boot/efi/EFI/BOOT/ | grep -qi 'fb${A}.efi'"
check "BOOT${A^^}.EFI is a copy of shim" \
  bash -c "cmp -s /boot/efi/EFI/BOOT/BOOT${A^^}.EFI /boot/efi/EFI/rocky/shim$A.efi"

section "SBAT"
sbat=$(block 'SBAT' 1 | grep '^objcopy' | arch)
check_output "the .sbat section of GRUB has a grub generation line (from the note)" '^grub,[0-9]+,' \
  bash -c "$(sed -n 1p <<<"$sbat")"
levels=$(bash -c "$(sed -n 2p <<<"$sbat")" 2>/dev/null)
assert_match "shim carries a .sbatlevel section (from the note)" 'sbat,1,' "$levels"
assert_eq "with two built-in levels" 2 "$(grep -c '^sbat,1,' <<<"$levels")"
help=$(mokutil --help 2>&1)
for o in --list-sbat-revocations --set-sbat-policy --sb-state --db --list-enrolled --list-new --import --kek --pk --dbx; do
  assert_match "mokutil has $o" "$o" "$help"
done
check_fails "mokutil --sb-state fails with no EFI variables (a container)" bash -c 'mokutil --sb-state 2>/dev/null'

section "One script"
check_output "the check script runs to the end (from the note)" '== pending ==' bash -c "$(block 'One script' 1 | arch)"
check_output "and finds the shim's signers" 'Microsoft|Rocky' bash -c "$(block 'One script' 1 | arch)"
skip "UEFI mode, Secure Boot state, lockdown" "reported for the Docker VM, not for a machine this note is about"

section "Is my shim dual-signed?"
out=$(bash -c "$(block 'Is my shim dual-signed' 1 | arch)" 2>&1)
assert_match "the readiness check prints the two counts (from the note)" '^2011 sig: [0-9]+ \| 2023 sig: [0-9]+$' "$out"
assert_match "Rocky 10's shim is dual-signed (2011 + 2023)" 'DUAL-SIGNED' "$out"
pes=$(pesign -S -i "/boot/efi/EFI/rocky/shim$A.efi")
assert_match "pesign -S names the 2011 signer" 'Microsoft Windows UEFI Driver Publisher' "$pes"
assert_match "and the 2023 signer" 'Microsoft UEFI CA 2023 signer' "$pes"
skip "Rocky 8 and 9 shims" "the test image is Rocky 10"

section "Signing your own kernel modules"
mkdir -p /root/module-signing
block 'Generate a key pair' 2 | grep -v '^#' >/root/module-signing/x509.conf
check "generate the key pair (from the note)" bash -ec "$(block 'Generate a key pair' 3)"
check_output "MOK.der is DER, as mokutil --import expects" 'Certificate' \
  bash -c 'openssl x509 -inform DER -in /root/module-signing/MOK.der -noout -subject && echo Certificate'
check_output "the private key is mode 600" '^600$' stat -c %a /root/module-signing/MOK.priv
(cd /root/module-signing && check "convert to PEM and read it (from the note)" bash -ec "$(block 'Generate a key pair' 4)")
cert=$(openssl x509 -inform DER -in /root/module-signing/MOK.der -noout -text)
assert_match "CA:FALSE" 'CA:FALSE' "$cert"
assert_match "code signing only" 'Code Signing' "$cert"
assert_match "a 4096-bit RSA key" 'Public-Key: \(4096 bit\)' "$cert"
assert_match "signed with SHA-512" 'sha512WithRSAEncryption' "$cert"

# A real module from kernel-core, its distribution signature removed, then re-signed with
# the note's key. modinfo reads the result offline; nothing is loaded.
mod=$(find "/lib/modules/$KVER/kernel" -name 'dummy.ko*' | head -1)
mkdir -p "/lib/modules/$KVER/extra"
case $mod in *.xz) xz -dc "$mod" ;; *) cat "$mod" ;; esac >vboxdrv.ko
python3 - vboxdrv.ko <<'PY'
import struct, sys
p = sys.argv[1]; d = open(p, "rb").read(); m = b"~Module signature appended~\n"
if d.endswith(m):
    sig_len = struct.unpack(">I", d[-len(m) - 4:-len(m)])[0]
    d = d[:-len(m) - 12 - sig_len]
open(p, "wb").write(d)
PY
cp vboxdrv.ko "/lib/modules/$KVER/extra/vboxdrv.ko"
check_fails "the stripped module has no signature" bash -c "modinfo -F sig_id /lib/modules/$KVER/extra/vboxdrv.ko | grep ."
check "sign-file from kernel-devel (from the note)" \
  bash -ec "$(block 'Sign the module' 1 | sed "s/\$(uname -r)/$KVER/g")"
sig=$(modinfo "/lib/modules/$KVER/extra/vboxdrv.ko" | grep -E '^sig')
assert_match "modinfo: sig_id PKCS#7 (from the note)" '^sig_id: +PKCS#7' "$sig"
assert_match "signer is the note's key" '^signer: +Example Corp Module Signing Key' "$sig"
assert_match "sig_hashalgo sha256" '^sig_hashalgo: +sha256' "$sig"
check_fails "sign-file is only in kernel-devel: no kernel-devel, no sign-file" \
  test -e "/usr/src/kernels/$(uname -r)/scripts/sign-file"
skip "mokutil --import, MokManager, keyctl .platform, modprobe" "need firmware, a reboot and a kernel to load into"
skip "the unsigned-module scan over lsmod" "lsmod lists the Docker VM's modules, whose files are not in this container"

section "Signing a kernel"
# The note leaves the NSS import as "a separate step"; the test does it with pk12util.
openssl pkcs12 -export -inkey /root/module-signing/MOK.priv -in /root/module-signing/MOK.pem \
  -name 'Example Corp Module Signing Key' -passout pass: -out mok.p12
pk12util -d /etc/pki/pesign -i mok.p12 -W '' >/dev/null
mkdir -p /boot && cp "/lib/modules/$KVER/vmlinuz" "/boot/vmlinuz-$KVER"
if pesign -S -i "/boot/vmlinuz-$KVER" >/dev/null 2>&1; then
  check "pesign --sign the kernel (from the note)" \
    bash -ec "$(block 'Signing a kernel' 1 | sed -n 1,4p | sed "s/\$(uname -r)/$KVER/g")"
  check_output "pesign -S shows the new signature" 'Example Corp Module Signing Key' \
    bash -ec "$(block 'Signing a kernel' 1 | sed -n '$p' | sed "s/\$(uname -r)/$KVER/g")"
else
  skip "pesign on the kernel" "this architecture's vmlinuz is not a PE binary"
fi
