#!/usr/bin/env bash
# note: linux/storage/partitioning.md
# env: priv:leap
# Builds the note's layout on loop devices, mounted under /target, from the table.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/storage/partitioning
zypper -n -q install --no-recommends btrfsprogs dosfstools >/dev/null
cd "$(mktemp -d)"
T=/target
declare -A DEV
for fs in root var boot; do truncate -s 300M $fs.img; DEV[$fs]=$(losetup -f --show $fs.img); done
truncate -s 64M efi.img && DEV[efi]=$(losetup -f --show efi.img)
cleanup() {
  umount -R "$T" 2>/dev/null || true
  for d in "${DEV[@]}"; do losetup -d "$d" 2>/dev/null || true; done
}
trap 'cleanup; _t_finish' EXIT
trap 'exit 1' TERM INT

# The table rows: mount point, filesystem, options, size.
rows=$(sed -n 's/^| `\([^`]*\)` | \([a-z0-9]*\) | \(.*\) | \(.*\) |$/\1 \2 \3/p' "$NOTES_ROOT/content/$NOTE.md" | tr -d '`')
section "SUSE family — btrfs on EFI"
assert_match "the table has the /var/log/audit subvolume" '^/var/log/audit btrfs subvol=/var@/var/log/audit$' "$rows"
for fs in root var boot; do mkfs.btrfs -q -f "${DEV[$fs]}"; done
mkfs.vfat "${DEV[efi]}" >/dev/null
mkdir -p $T && mount "${DEV[root]}" $T
# Which filesystem holds a subvolume: /@/... is on /, /var@/... on /var, /boot@/... on /boot.
fs_of() { case $1 in /var@*) echo var ;; /boot@*) echo boot ;; *) echo root ;; esac; }
mount_row() {
  local mp=$1 type=$2 opts=$3 dev
  case $type in
    btrfs)
      if [[ $opts == subvol=* ]]; then
        local sv=${opts#subvol=} fs; fs=$(fs_of "$sv")
        dev=${DEV[$fs]}
        mkdir -p /mnt/top && mount "$dev" /mnt/top
        local parent=/mnt/top
        # Create each missing level as a subvolume, like the installer does.
        IFS=/ read -ra parts <<<"${sv#/}"
        for p in "${parts[@]}"; do
          parent=$parent/$p
          [[ -d $parent ]] || btrfs -q subvolume create "$parent"
        done
        umount /mnt/top
        mkdir -p "$T$mp" && mount -o "$opts" "$dev" "$T$mp"
      else
        case $mp in /var) dev=${DEV[var]} ;; /boot) dev=${DEV[boot]} ;; *) return 0 ;; esac
        mkdir -p "$T$mp" && mount "$dev" "$T$mp"
      fi ;;
    vfat) mkdir -p "$T$mp" && mount -o "$opts" "${DEV[efi]}" "$T$mp" ;;
    tmpfs) mkdir -p "$T$mp" && mount -t tmpfs tmpfs "$T$mp" ;;
    *) return 0 ;;
  esac
}
# Mount parents before children: /var before /var/log, and so on.
while read -r mp type opts; do
  [[ $mp == / || $type == swap ]] && continue
  check "mount $mp ($type, $opts)" mount_row "$mp" "$type" "$opts"
done < <(sort -k1,1 <<<"$rows")
check_output "/var/log/audit is its own btrfs subvolume" 'var@/var/log/audit' \
  bash -c "btrfs subvolume show $T/var/log/audit"
check_output "/boot/efi is vfat, mounted with utf8" " $T/boot/efi vfat .*utf8" cat /proc/mounts

section "Subvolumes do not have a fixed size"
assert_eq "/home and / report the same free space" "$(df --output=avail $T | tail -1)" "$(df --output=avail $T/home | tail -1)"
check "a quota group limit caps a subvolume" bash -c "btrfs quota enable $T && btrfs qgroup limit 20M $T/home"
check_fails "writing past the limit fails" bash -c "head -c 40M /dev/zero >$T/home/big && sync -f $T/home/big"
rm -f $T/home/big
# Logs fill the /var filesystem, not /.
root_before=$(df --output=avail $T | tail -1)
head -c 100M /dev/zero >$T/var/log/big && sync -f $T/var/log/big
assert_eq "data in /var/log does not use space on /" "$root_before" "$(df --output=avail $T | tail -1)"
check "but it does use the space of /var, shared with /var/tmp" \
  test "$(df --output=avail $T/var/tmp | tail -1)" = "$(df --output=avail $T/var/log | tail -1)"

section "Correction: /proc"
check_output "/proc is procfs, never a subvolume" '^proc$' stat -f -c %T /proc
