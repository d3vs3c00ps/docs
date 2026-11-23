#!/usr/bin/env bash
# note: security/boot-integrity/tpm.md
# env: rocky
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/boot-integrity/tpm
block() { note_block "$NOTE" "$@"; }
# The note's commands use sudo; the test runs as root, with no sudo installed.
sudo() { "$@"; }
export -f sudo
run() { bash -ec "$(block "$@")"; }
dnf -y -q install swtpm swtpm-tools tpm2-tools tpm2-abrmd dbus-daemon systemd >/dev/null 2>&1

# swtpm is a software TPM 2.0. tpm2-abrmd is a resource manager in front of it, the
# user-space twin of the kernel's /dev/tpmrm0. Nothing here touches the host's TPM or kernel.
mkdir -p /tmp/tpmstate
swtpm socket --tpm2 --tpmstate dir=/tmp/tpmstate --server type=tcp,port=2321 \
  --ctrl type=tcp,port=2322 --flags not-need-init,startup-clear --daemon
DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address)
export DBUS_SESSION_BUS_ADDRESS
tpm2-abrmd --session --tcti=swtpm:port=2321 --allow-root 2>/dev/null &
abrmd=$!
export TPM2TOOLS_TCTI=tabrmd:bus_type=session
retry 10 tpm2_getcap properties-fixed
cd "$(mktemp -d)"
pcr() { tpm2_pcrread "sha256:$1" | grep -o '0x[0-9A-Fa-f]*' | cut -c3- | tr 'A-F' 'a-f'; }

section "Seeing the extend operation"
sim=$(run 'Seeing the extend operation' 1 | cut -d' ' -f1)
assert_match "the simulation prints a SHA-256 (from the note)" '^[0-9a-f]{64}$' "$sim"
out=$(run 'Seeing the extend operation' 2)
assert_match "pcrreset then pcrread: PCR 16 is all zeros (from the note)" '16 ?: 0x0{64}' "$(sed -n 2p <<<"$out")"
assert_eq "the real extend gives the simulated value" "$sim" "$(pcr 16)"
ha=$(printf a | sha256sum | cut -d' ' -f1)
hb=$(printf b | sha256sum | cut -d' ' -f1)
tpm2_pcrreset 16 && tpm2_pcrextend "16:sha256=$ha" && tpm2_pcrextend "16:sha256=$hb"
ab=$(pcr 16)
tpm2_pcrreset 16 && tpm2_pcrextend "16:sha256=$hb" && tpm2_pcrextend "16:sha256=$ha"
check_fails "order matters: A then B differs from B then A" test "$ab" = "$(pcr 16)"
check "PCR 16 is resettable" tpm2_pcrreset 16
check "PCR 23 is resettable" tpm2_pcrreset 23
check_fails "PCR 7 is not (as the note says)" tpm2_pcrreset 7
check_fails "PCR 0 is not" tpm2_pcrreset 0
check_fails "PCR 17 is not, from locality 0 (DRTM only)" tpm2_pcrreset 17

section "What PCR 7 actually measures"
# A real UEFI event log with Secure Boot (a Google Cloud VM), from tpm2-tools' test fixtures.
log=/tmp/binary_bios_measurements
curl -fsSL -o "$log" https://raw.githubusercontent.com/tpm2-software/tpm2-tools/5.7/test/integration/fixtures/event-gce-ubuntu-2104-log.bin
echo "8334fef7db8976292abeaf39e16abcecd8fc01f501bac50f8f6bd837425029c5  $log" | sha256sum -c --quiet
ev=$(bash -ec "$(block 'What PCR 7 actually measures' 1 | sed "s|/sys/kernel/security/tpm0/binary_bios_measurements|$log|")")
for v in SecureBoot PK KEK db dbx; do
  assert_match "PCR 7 measures the $v variable (from the note's command)" "UnicodeName: $v\$" "$ev"
done
assert_match "then EV_SEPARATOR" 'EV_SEPARATOR' "$ev"
assert_match "then EV_EFI_VARIABLE_AUTHORITY" 'EV_EFI_VARIABLE_AUTHORITY' "$ev"
skip "SbatLevel and MokListRT in PCR 7" "that log has no shim SBAT events; the note's Rocky output was measured on real hardware"

section "Is one present?"
skip "ls /dev/tpm0 /dev/tpmrm0 and /sys/class/tpm" "a container has no TPM device; swtpm stands in through TPM2TOOLS_TCTI"
p=$(block 'Is one present' 1)
check_output "tpm2_getcap properties-fixed (from the note)" 'TPM2_PT_FAMILY_INDICATOR' bash -ec "$(grep getcap <<<"$p")"
check_output "the manufacturer (from the note)" 'TPM2_PT_MANUFACTURER' run 'Is one present' 2
check_output "tpm2_getcap pcrs lists the banks" 'sha256: \[ 0, 1, 2' bash -c "$(block 'Is one present' 2 | grep 'getcap pcrs')"
check_output "the minimum of transient objects is 3 (as the note says: often three)" 'raw: 0x3$' \
  bash -c 'tpm2_getcap properties-fixed | grep -A1 TPM2_PT_HR_TRANSIENT_MIN'
check_output "reading a bank that does not exist is an error, not an empty result" 'unsupported bank' \
  bash -c 'tpm2_pcrread sha3_256:0 2>&1; true'
check_fails "and it fails" tpm2_pcrread sha3_256:0

section "Reading PCRs"
r=$(block 'Reading PCRs' 1)
check_output "every PCR in the sha256 bank (from the note)" '23 ?: 0x' bash -ec "$(sed -n 1p <<<"$r")"
check_output "just the boot-relevant ones (from the note)" '9 ?: 0x' bash -ec "$(sed -n 2p <<<"$r")"
check_output "PCR 7 (from the note)" '^ +7 ?: 0x[0-9A-F]{64}$' bash -ec "$(sed -n 3p <<<"$r")"

section "Baseline and drift detection"
check "capture a baseline (from the note)" run 'Baseline and drift' 1
check_output "the copies are mode 600" '^600$' bash -c 'stat -c %a /root/pcr-baseline*.txt | sort -u'
check_output "nothing changed: PCRs unchanged (from the note)" 'PCRs unchanged' run 'Baseline and drift' 2
block 'Baseline and drift' 4 >/usr/local/sbin/pcr-check.sh
chmod +x /usr/local/sbin/pcr-check.sh
block 'Baseline and drift' 3 >/etc/systemd/system/pcr-check.service
check "the unit passes systemd-analyze verify (from the note)" systemd-analyze verify /etc/systemd/system/pcr-check.service
check "the script passes bash -n" bash -n /usr/local/sbin/pcr-check.sh
# logger needs a syslog socket; record its messages in a file instead.
mkdir -p /tmp/fakebin
printf '#!/bin/sh\n{ echo "$*"; [ -t 0 ] || cat; } >>/tmp/logger.out\n' >/tmp/fakebin/logger
chmod +x /tmp/fakebin/logger
check "the check passes against the baseline" env PATH="/tmp/fakebin:$PATH" /usr/local/sbin/pcr-check.sh
check_output "and logs that PCRs match" 'PCRs match baseline' cat /tmp/logger.out
tpm2_pcrextend "7:sha256=$ha"
check_fails "after PCR 7 moves, the check exits 1" env PATH="/tmp/fakebin:$PATH" /usr/local/sbin/pcr-check.sh
check_output "and logs PCR drift detected" 'auth.warning -t pcr-check PCR drift detected' cat /tmp/logger.out
check_output "with the diff of the moved PCR" '^> +7 ?: 0x' cat /tmp/logger.out
check_fails "the note's diff command fails too" run 'Baseline and drift' 2

section "Sealing a secret by hand"
mkdir seal && cd seal
check_output "seal to PCR 7, then unseal (from the note)" '^my-secret-key$' run 'Sealing a secret by hand' 1
tpm2_pcrextend "7:sha256=$hb"
unseal=$(block 'Sealing a secret by hand' 1 | sed -n '/# 4\./,$p' | grep -v flushcontext)
check_output "after PCR 7 changes, unseal fails with a policy error 0x99D" 'policy check failed|0x99D|0x99d' \
  bash -c "$unseal 2>&1; true"
check_fails "and returns an error" bash -ec "$unseal"
check "the cleanup (from the note)" run 'Sealing a secret by hand' 2
assert_no_file "the context files are gone" primary.ctx
cd ..

section "tpm2_flushcontext -t"
# Talk to the TPM directly, as through /dev/tpm0: with no resource manager, transient
# objects stay loaded after each tool exits.
kill "$abrmd" && wait "$abrmd" 2>/dev/null || true
export TPM2TOOLS_TCTI=swtpm:port=2321
retry 10 tpm2_getcap properties-fixed
tpm2_flushcontext -t
mkdir raw && cd raw
check_output "on a raw TPM, the note's sealing steps run out of object memory (as the note says)" \
  'out of memory for object contexts' bash -c "$(block 'Sealing a secret by hand' 1) 2>&1; true"
cd ..
tpm2_flushcontext -t
tpm2_flushcontext -s 2>/dev/null || true
full=
for i in $(seq 1 10); do
  if ! out=$(tpm2_createprimary -C o -g sha256 -G ecc -c "p$i.ctx" 2>&1); then full=$out; break; fi
done
assert_match "creating objects without flushing them fills the TPM: out of memory for object contexts" \
  'out of memory for object contexts|0x902' "$full"
check "tpm2_flushcontext -t (from the note)" tpm2_flushcontext -t
check "then a new object loads again" tpm2_createprimary -C o -g sha256 -G ecc -c after.ctx
tpm2_flushcontext -t

section "tpm2_clear"
tpm2_createprimary -C o -c prim.ctx >/dev/null && tpm2_evictcontrol -C o -c prim.ctx 0x81000001 >/dev/null
tpm2_flushcontext -t
check_output "a persistent object exists" '0x81000001' tpm2_getcap handles-persistent
check "tpm2_clear" tpm2_clear
check_fails "tpm2_clear wipes it (as the note says)" bash -c 'tpm2_getcap handles-persistent | grep -q 0x81000001'
