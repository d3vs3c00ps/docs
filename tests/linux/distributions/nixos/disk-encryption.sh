#!/usr/bin/env bash
# note: linux/distributions/nixos/disk-encryption.md
# env: nixos
# timeout: 1800
# The configuration blocks are evaluated as a normal host (initrd and boot cannot run
# in a container; booting them needs a VM). The disk commands run on image files.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/nixos.sh"

NOTE=linux/distributions/nixos/disk-encryption
cd "$(mktemp -d)"
tools=(nixpkgs#parted nixpkgs#cryptsetup nixpkgs#lvm2 nixpkgs#dosfstools nixpkgs#e2fsprogs nixpkgs#util-linux nixpkgs#openssh)
PATH=$(nix shell "${tools[@]}" --command bash -c 'echo $PATH'):$PATH
# A note block with the disks replaced by image files, without sudo.
blk() { note_block "$NOTE" "$1" "$2" | sed 's/^sudo //; s|/dev/nvme0n1p2|luks.img|g; s|/dev/nvme0n1|disk.img|g'; }
cleanup() {
  vgchange -an vg >/dev/null 2>&1 || true
  cryptsetup close cryptroot >/dev/null 2>&1 || true
  losetup -j luks.img -O NAME --noheadings 2>/dev/null | xargs -r -n1 losetup -d 2>/dev/null || true
}
trap 'rc=$?; cleanup; _t_finish $rc' EXIT
# evq HEADING N ATTR JQ: a block evaluated as a host, filtered with jq.
evq() { nixos_eval --host --block "$1" "$2" "$3" | jq -cSr "$4"; }
# ev_err ATTR: the error of evaluating ATTR, which must fail.
ev_err() { ! nixos_eval --host "$@" 2>&1; }

section "Installing onto an encrypted disk"
truncate -s 2G disk.img
check "the partitioning commands, on an image file (from the note)" bash -ec "$(blk "Installing onto" 1 | sed -n '/parted/p')"
table=$(parted -m disk.img unit MiB print)
assert_match "partition 1: 1MiB to 1GiB, flagged esp" '^1:1(\.00)?MiB:1024MiB:.*esp' "$table"
assert_match "partition 2: the rest of the disk" '^2:1024MiB:204[78]' "$table"
truncate -s 64M fat.img
check "mkfs.fat -F32 -n boot" bash -ec "$(blk "Installing onto" 1 | sed -n '/mkfs.fat/p' | sed 's|disk.imgp1|fat.img|')"
check_output "the ESP is labelled boot" 'BOOT|boot' blkid -o value -s LABEL fat.img
truncate -s 600M luks.img
echo -n 'correct horse battery staple' >pass
check "luksFormat with the note's options" bash -ec "$(blk "Installing onto" 1 | sed -n '/luksFormat/,/luks.img/p' | tr -d '\\\n') --batch-mode --key-file pass"
dump=$(cryptsetup luksDump luks.img)
assert_match "LUKS2" 'Version:[[:space:]]+2' "$dump"
assert_match "aes-xts-plain64" 'cipher: aes-xts-plain64' "$dump"
assert_match "512-bit key" 'Cipher key:[[:space:]]+512 bits' "$dump"
assert_match "argon2id" 'PBKDF:[[:space:]]+argon2id' "$dump"
if cryptsetup open luks.img cryptroot --key-file pass 2>err && [[ -e /dev/mapper/cryptroot ]]; then
  _t_ok "cryptsetup open (from the note)"
  check "LVM inside the container (from the note)" bash -ec "$(blk "Installing onto" 2 | sed 's/-L 16G/-L 64M/')"
  check_output "swap and root are logical volumes" 'root.*swap|swap.*root' bash -c 'lvs --noheadings -o lv_name vg | tr -d " " | sort | tr "\n" " "'
  check_output "root is ext4 labelled nixos" 'ext4' blkid /dev/vg/root
  check_output "swap is labelled swap" 'LABEL="swap"' blkid /dev/vg/swap
else
  skip "cryptsetup open and the LVM block" "device-mapper is not usable in this container: $(head -1 err)"
fi
cleanup

section "The configuration"
check "the block evaluates as a whole system" nixos_eval --host --block "## The configuration" 1 system.build.toplevel.drvPath
check_output "the LUKS device has allowDiscards and preLVM" '"allowDiscards":true.*"preLVM":true' \
  evq "## The configuration" 1 boot.initrd.luks.devices.cryptroot '{allowDiscards, preLVM}'
check_output "blkid gives the UUID to use" 'UUID=' blkid luks.img

section "TPM auto-unlock"
check_output "the systemd initrd is the default on 26.05" '^true$' nixos_eval --host boot.initrd.systemd.enable
check "the TPM block evaluates" nixos_eval --host --block "TPM auto-unlock" 1 system.build.toplevel.drvPath
check_output "the crypttab options reach the initrd's crypttab" 'cryptroot .*tpm2-device=auto,tpm2-measure-pcr=yes' \
  evq "TPM auto-unlock" 1 'boot.initrd.systemd.contents."/etc/crypttab".text' .
check "systemd-cryptenroll has the note's flags" bash -c 'systemd-cryptenroll --help | grep -q -- --tpm2-pcrs && systemd-cryptenroll --help | grep -q -- --wipe-slot'
skip "enrolling the TPM" "needs a TPM 2.0 device"

section "Remote unlock over SSH"
check "the block evaluates" nixos_eval --host --block "Remote unlock" 1 system.build.toplevel.drvPath
check_output "the initrd SSH listens on 2222" '^2222$' nixos_eval --host --block "Remote unlock" 1 boot.initrd.network.ssh.port
check_output "the host key stays a path on disk, not a store path" '^\["/etc/secrets/initrd/ssh_host_ed25519_key"\]$' \
  nixos_eval --host --block "Remote unlock" 1 boot.initrd.network.ssh.hostKeys
check "ssh-keygen for the initrd host key (from the note)" bash -ec "$(note_block "$NOTE" "Remote unlock" 3 | sed 's/^sudo //')"
check_output "the key is ed25519" 'ED25519' ssh-keygen -lf /etc/secrets/initrd/ssh_host_ed25519_key.pub
# The correction: written as a path, the key is copied into the world-readable store.
out=$(NIXOS_MODULE='{ boot.initrd.network.ssh.hostKeys = [ /etc/secrets/initrd/ssh_host_ed25519_key ]; }' \
  nixos_eval --host boot.initrd.network.ssh.hostKeys)
assert_match "as a Nix path, the private key lands in /nix/store" '/nix/store/[a-z0-9]{32}-ssh_host_ed25519_key' "$out"
check_output "readable by everyone there" '^-r--r--r--' bash -c "ls -l $(jq -r '.[0]' <<<"$out")"
skip "unlocking at boot over SSH" "needs a booted initrd; a VM test, CI only"

section "Impermanence"
check_output "without the module, environment.persistence does not exist" "option .environment.persistence. does not exist" \
  ev_err --block "## Impermanence" 1 system.build.toplevel.drvPath
imp=$(nix eval --impure --raw --expr 'builtins.fetchTarball "https://github.com/nix-community/impermanence/archive/master.tar.gz"')
# shellcheck disable=SC2089,SC2090 # the quotes are for Nix, not for the shell
NIXOS_MODULE="{ notes, ... }: { imports = [ $imp/nixos.nix (notes.module \"## Impermanence\" 1) ]; }"
# shellcheck disable=SC2090
export NIXOS_MODULE
check_output "with the impermanence module, root is a tmpfs" '"tmpfs"' nixos_eval --host 'fileSystems."/".fsType'
check_output "and /var/log is bind-mounted from /persist" '"/persist/var/log"' nixos_eval --host 'fileSystems."/var/log".device'
check "the whole system evaluates" nixos_eval --host system.build.toplevel.drvPath
unset NIXOS_MODULE
