#!/usr/bin/env bash
# note: linux/storage/benchmark.md
# env: priv:leap
# A loop device stands in for /dev/sdb.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/storage/benchmark
zypper -n -q install --no-recommends e2fsprogs util-linux >/dev/null
cd "$(mktemp -d)"
truncate -s 1G sdb.img
SDB=$(losetup -fP --show sdb.img)
trap 'umount /mnt/bench 2>/dev/null; losetup -d "$SDB"; _t_finish' EXIT
trap 'exit 1' TERM INT

block=$(note_block "$NOTE" 'Filesystem benchmarking' 1)
section "Filesystem benchmarking"
skip "cfdisk" "interactive; sfdisk makes the same single partition"
echo ',,L' | sfdisk -q "$SDB"
n=${SDB#/dev/}
SDB1=${SDB}p1
[[ -e $SDB1 ]] || { IFS=: read -r maj min <"/sys/block/$n/${n}p1/dev" && mknod "$SDB1" b "$maj" "$min"; }   # no udev here
steps=$(grep -v '^cfdisk' <<<"$block" | sed "s|/dev/sdb1|$SDB1|g; s|^zypper install|zypper -n install|")
check "mkfs, mkdir, mount and zypper install (from the note)" bash -ec "$(grep -v '^bonnie' <<<"$steps")"
check_output "/mnt/bench is the new ext4" 'ext2/ext3' stat -f -c %T /mnt/bench
cmd=$(grep '^bonnie' <<<"$steps")
assert_eq "the note's command" 'bonnie++ -u 0 -n 256 -d /mnt/bench' "$cmd"
check_output "the old -s 1024 is refused on a machine with more RAM" 'File size should be double RAM' \
  bash -c 'bonnie++ -u 0 -n 256 -s 1024 -d /mnt/bench 2>&1; true'
# Twice the real RAM is too long for a test: -r makes bonnie++ assume 64 MB, and -n 4
# keeps the file test short. The rest is the note's command.
out=$(bash -ec "${cmd/-n 256/-n 4} -r 64" 2>&1)
size=$(sed -n 's/^1\.98,[^,]*,[^,]*,[^,]*,[^,]*,\([0-9]*\)M,.*/\1/p' <<<"$out")
check "without -s, the size is at least twice the (assumed) RAM: ${size}M" test "${size:-0}" -ge 128
assert_match "it runs the file creation tests" 'Create' "$out"
check_output "-n 256 needs 262144 inodes; this 1 GB disk has fewer" '^[0-9]+$' \
  bash -c "i=\$(df --output=iavail /mnt/bench | tail -1); ((i < 262144)) && echo \$i"

section "reiserfs is gone"
check_fails "the kernel has no reiserfs" grep -qw reiserfs /proc/filesystems
