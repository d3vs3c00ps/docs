#!/usr/bin/env bash
# note: security/boot-integrity/luks.md
# env: rocky
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/boot-integrity/luks
block() { note_block "$NOTE" "$@"; }
# The LUKS containers are plain files: cryptsetup formats, dumps, converts and tests
# keys on a file with no loop device and no device-mapper, so the shared kernel is untouched.

section "Packages"
check "the note's dnf line installs with no extra repository (from the note)" \
  bash -ec "$(block 'Packages' 1) -q >/dev/null 2>&1"
check "the tpm2 pin comes with the clevis package" bash -c 'rpm -qf /usr/bin/clevis-encrypt-tpm2 | grep -q "^clevis-[0-9]"'
check_fails "clevis-pin-tpm2 is a different pin (tpm2plus), not needed for tpm2" \
  bash -c 'rpm -qf /usr/bin/clevis-encrypt-tpm2 | grep -q pin-tpm2'
check "clevis-luks-askpass.path ships with clevis-systemd" test -f /usr/lib/systemd/system/clevis-luks-askpass.path
dnf -y -q install swtpm swtpm-tools tpm2-abrmd dbus-daemon dracut openssl python3 >/dev/null 2>&1

# A software TPM behind tpm2-abrmd, as in the TPM note. Nothing touches the host's TPM.
mkdir -p /tmp/tpmstate
swtpm socket --tpm2 --tpmstate dir=/tmp/tpmstate --server type=tcp,port=2321 \
  --ctrl type=tcp,port=2322 --flags not-need-init,startup-clear --daemon
DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address)
export DBUS_SESSION_BUS_ADDRESS
tpm2-abrmd --session --tcti=swtpm:port=2321 --allow-root 2>/dev/null &
export TPM2TOOLS_TCTI=tabrmd:bus_type=session TCTI=tabrmd:bus_type=session
retry 10 tpm2_getcap properties-fixed
cd "$(mktemp -d)"
P='correct horse battery staple'
mkdir -p /dev/disk/by-id /dev/disk/by-uuid
# newdisk NAME: a 32 MiB file, linked where the note's commands expect a device.
newdisk() { truncate -s 32M "/tmp/$1.img" && ln -sf "/tmp/$1.img" "/dev/disk/by-id/$1"; }
byuuid() { local u; u=$(blkid -s UUID -o value "$1"); ln -sf "$(readlink -f "$1")" "/dev/disk/by-uuid/$u"; echo "/dev/disk/by-uuid/$u"; }

section "LUKS2 format"
newdisk root
check "luksFormat with the note's parameters (from the note)" \
  bash -ec "$(block 'LUKS2 format' 1 | sed 's|<stable-path>|root|; s|luksFormat|luksFormat -q|') <<<'$P'"
dump=$(cryptsetup luksDump /dev/disk/by-id/root)
assert_match "LUKS version 2" '^Version:[[:space:]]+2' "$dump"
assert_match "aes-xts-plain64, 512-bit key" 'cipher: aes-xts-plain64' "$dump"
assert_match "512 bits" 'Cipher key:[[:space:]]+512 bits' "$dump"
assert_match "the keyslot uses pbkdf2 with sha512" 'PBKDF:[[:space:]]+pbkdf2' "$dump"
assert_match "600000 iterations" 'Iterations:[[:space:]]+600000' "$dump"
newdisk argon
cryptsetup luksFormat -q --type luks2 --pbkdf-memory 65536 /dev/disk/by-id/argon <<<"$P"
check_output "the default PBKDF is argon2id" 'PBKDF:[[:space:]]+argon2id' cryptsetup luksDump /dev/disk/by-id/argon
convert=$(block 'LUKS2 format' 3)
check "luksConvertKey to pbkdf2, in place (from the note)" \
  bash -ec "${convert/<device>//dev/disk/by-id/argon}" <<<"$P"
check_output "the slot is now pbkdf2" 'PBKDF:[[:space:]]+pbkdf2' cryptsetup luksDump /dev/disk/by-id/argon
check "and the passphrase still opens it" cryptsetup open --test-passphrase /dev/disk/by-id/argon <<<"$P"
check_fails "fips-mode-setup is gone on Rocky 10 (as the note says)" command -v fips-mode-setup

section "Dracut integration"
check_output "add_dracutmodules is a dracut setting" 'add_dracutmodules' bash -c 'man -P cat dracut.conf 2>/dev/null || grep -rh add_dracutmodules /usr/lib/dracut/dracut-functions.sh /usr/bin/dracut'
check_fails "keep_dracutmodules is not (the correction)" grep -rq keep_dracutmodules /usr/bin/dracut /usr/lib/dracut
# The number prefix changes between releases (60clevis, then 50clevis on Rocky 10).
check "the clevis dracut module exists" bash -c 'ls -d /usr/lib/dracut/modules.d/[0-9][0-9]clevis'
check_output "and it depends on crypt" 'crypt' bash -c 'grep -A3 "^depends" /usr/lib/dracut/modules.d/[0-9][0-9]clevis/module-setup.sh'
skip "dracut --regenerate-all and lsinitrd" "the container has no kernel or /boot to build an initramfs for"

section "Bind LUKS to PCR 7"
DEV=$(byuuid /dev/disk/by-id/root)
check "clevis luks bind to PCR 7 (from the note)" \
  bash -ec "$(block 'Bind LUKS to PCR 7' 1 | sed 's|/dev/<device>|/dev/disk/by-id/root|')" <<<"$P"
list=$(clevis luks list -d "$DEV")
assert_match "clevis luks list shows a tpm2 binding on sha256, PCR 7" '^1: tpm2 .*"pcr_bank":"sha256".*"pcr_ids":"7"' "$list"
check "the TPM unseals the key: the slot's passphrase opens the volume" \
  bash -c "clevis luks pass -d '$DEV' -s 1 | cryptsetup open --test-passphrase '$DEV' --key-file -"
newdisk nobank
cryptsetup luksFormat -q --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 /dev/disk/by-id/nobank <<<"$P"
clevis luks bind -d /dev/disk/by-id/nobank tpm2 '{"pcr_ids":"7"}' <<<"$P"
nobank=$(clevis luks list -d /dev/disk/by-id/nobank)
assert_match "\"key\":\"ecc\" is the default (the correction)" '"key":"ecc"' "$nobank"
check_output "on Rocky 10 the tpm2 pin hands over to clevis-pin-tpm2" 'exec clevis-pin-tpm2' cat /usr/bin/clevis-encrypt-tpm2
assert_match "which defaults to the sha256 bank" '"pcr_bank":"sha256"' "$nobank"

section "Reseal (a PCR 7 change)"
check "the passphrase fallback works (from the note)" \
  bash -ec "$(block 'The reseal itself' 2 | sed -n '/--test-passphrase/p' | sed "s|\"\$DEV\"|'$DEV'|")" <<<"$P"
tpm2_pcrextend "7:sha256=$(printf 'new db entry' | sha256sum | cut -d' ' -f1)"
out=$(clevis luks pass -d "$DEV" -s 1 2>&1) && rc=0 || rc=$?
assert_match "after PCR 7 changes, the TPM refuses to unseal" '^[1-9]' "$rc"
assert_match "with TPM_RC_POLICY_FAIL (0x99D), as the note shows" '99[dD]|policy check failed' "$out"
regen=$(block 'The reseal itself' 2 | sed -n '/^SLOT=/,$p' | sed "s|\"\$DEV\"|'$DEV'|g")
check_output "clevis luks regen reseals in place, prompting for the passphrase (from the note)" 'regenerated successfully' \
  bash -c "$regen 2>&1" < <(printf 'y\n%s\n' "$P")
check_output "it kept slot 1 and one tpm2 token" '^1: tpm2' clevis luks list -d "$DEV"
assert_eq "exactly one binding" 1 "$(clevis luks list -d "$DEV" | grep -c tpm2)"
check "the new PCR 7 value unseals again" \
  bash -c "clevis luks pass -d '$DEV' -s 1 | cryptsetup open --test-passphrase '$DEV' --key-file -"

section "Factory or PXE provisioning"
mkdir -p /etc/pki/factory
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out factory.key 2>/dev/null
openssl pkey -in factory.key -pubout -out /etc/pki/factory/pub.pem
printf 'Authorization: Bearer test\n' >/run/factory-token.hdr
# A local stand-in for the escrow service: stores a POST, returns it on GET.
cat >escrow.py <<'PY'
import http.server, json
store = {}
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        d = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        store[d["host"]] = d["wrapped_key"]; self.send_response(201); self.end_headers()
    def do_GET(self):
        k = store.get(self.path.rsplit("/", 1)[-1])
        self.send_response(200 if k else 404); self.end_headers()
        if k: self.wfile.write(k.encode())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8080), H).serve_forever()
PY
python3 escrow.py &
retry 10 bash -c 'curl -s -o /dev/null http://127.0.0.1:8080/'
newdisk factory
TEMP_PASS='kickstart build passphrase'
cryptsetup luksFormat -q --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 /dev/disk/by-id/factory <<<"$TEMP_PASS"
byuuid /dev/disk/by-id/factory >/dev/null
block 'Factory or PXE provisioning' 1 | sed -e 's|/dev/<device>|/dev/disk/by-id/factory|' \
  -e 's|https://secrets.example.com|http://127.0.0.1:8080|' -e '/^dracut /d' >provision.sh
check "the provisioning script runs (from the note, escrow on a local stub)" \
  env TEMP_PASS="$TEMP_PASS" HOSTNAME=node-01 bash provision.sh
FDEV=/dev/disk/by-uuid/$(blkid -s UUID -o value /dev/disk/by-id/factory)
check_fails "the build passphrase no longer opens the volume" cryptsetup open --test-passphrase "$FDEV" <<<"$TEMP_PASS"
recov=$(curl -s http://127.0.0.1:8080/v1/recovery-keys/node-01 | base64 -d |
  openssl pkeyutl -decrypt -inkey factory.key -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256)
check "the escrowed key, unwrapped with the private key, opens the volume" \
  bash -c "printf '%s' '$recov' | cryptsetup open --test-passphrase '$FDEV' --key-file -"
fslot=$(clevis luks list -d "$FDEV" | awk -F: '/tpm2/{print $1; exit}')
check "the TPM binding opens it too" \
  bash -c "clevis luks pass -d '$FDEV' -s '$fslot' | cryptsetup open --test-passphrase '$FDEV' --key-file -"
assert_eq "two keyslots remain: recovery key and clevis" 2 "$(cryptsetup luksDump "$FDEV" | grep -c '^  [0-9]*: luks2')"
check_output "openssl rsautl still exists but is deprecated" 'deprecated' bash -c 'openssl rsautl -help 2>&1'

section "Secondary data partitions"
newdisk data
block 'Secondary data partitions' 1 | sed -e 's/luksFormat/luksFormat -q/' -e '2s/$/ <<<"$P"/' -e '4s/$/ <<<"$P"/' >data.sh
check "format and bind a data volume (from the note)" env P="$P" DATA_DEV=/dev/disk/by-id/data bash -e data.sh
check_output "it is bound to PCR 7" 'tpm2' clevis luks list -d /dev/disk/by-id/data
assert_match "the crypttab line has four fields and no _netdev" '^luks-data +UUID=[^ ]+ +none +discard$' \
  "$(block 'Secondary data partitions' 2 | grep -v '^#')"
skip "systemctl enable clevis-luks-askpass.path" "the plain container has no systemd as PID 1; the unit file is checked under Packages"

section "Binding to Tang as the second factor"
dnf -y -q install tang socat >/dev/null 2>&1
mkdir -p /var/db/tang && /usr/libexec/tangd-keygen /var/db/tang
# tangd is an inetd-style program; socat stands in for its systemd socket on port 80.
tang_up() { socat TCP-LISTEN:80,reuseaddr,fork EXEC:"/usr/libexec/tangd /var/db/tang" & tang=$!; retry 10 curl -sf http://127.0.0.1/adv; }
tang_up
newdisk tang
cryptsetup luksFormat -q --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 /dev/disk/by-id/tang <<<"$P"
DEV=$(byuuid /dev/disk/by-id/tang)
block 'Binding to Tang' 1 | sed 's|http://tang.example.com|http://127.0.0.1|' >tang.sh
check "tang-show-keys and an sss t:2 bind of TPM and Tang (from the note)" env DEV="$DEV" bash -e tang.sh <<<"$P"
check_output "clevis luks list shows the sss binding with both pins" '^1: sss .*"t":2.*tang.*tpm2|^1: sss .*"t":2.*tpm2.*tang' clevis luks list -d "$DEV"
check "with both pins reachable, it unlocks unattended" \
  bash -c "clevis luks pass -d '$DEV' -s 1 | cryptsetup open --test-passphrase '$DEV' --key-file -"
kill "$tang" && wait "$tang" 2>/dev/null || true
check_fails "with Tang stopped, t:2 denies (as the note says)" clevis luks pass -d "$DEV" -s 1
tang_up
check "Tang back: it unlocks again" bash -c "clevis luks pass -d '$DEV' -s 1 >/dev/null"
kill "$tang" 2>/dev/null || true

section "Not run"
skip "mokutil --set-sbat-policy and the SBAT objcopy lines" "mokutil needs firmware variables; the same objcopy lines run in the secure-boot test"
skip "auditctl -w /usr/bin/clevis" "an audit rule would load into the shared Docker kernel"
