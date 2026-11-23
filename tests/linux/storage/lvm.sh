#!/usr/bin/env bash
# note: linux/storage/lvm.md
# env: priv:leap
# Loop devices stand in for the disks. The device-mapper names are global to the
# Docker host, so everything is torn down on exit.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/storage/lvm
zypper -n -q install --no-recommends lvm2 parted xfsprogs e2fsprogs >/dev/null
# No udev in the container: libdevmapper creates the /dev/mapper nodes itself.
export DM_DISABLE_UDEV=1
cd "$(mktemp -d)"
truncate -s 600M sda.img
truncate -s 110M sdb.img
SDA=$(losetup -f --show sda.img)
SDB=$(losetup -fP --show sdb.img)
cleanup() {
  umount /mnt/root /mnt/data 2>/dev/null || true
  vgchange -an system >/dev/null 2>&1 || true
  losetup -d "$SDA" "$SDB" 2>/dev/null || true
}
trap 'cleanup; _t_finish' EXIT
trap 'exit 1' TERM INT

# The container's /dev does not get new partition nodes: make them from sysfs.
part_node() {
  local p=${1}p1 n=${1#/dev/}
  [[ -e $p ]] || { IFS=: read -r maj min <"/sys/block/$n/${n}p1/dev" && mknod "$p" b "$maj" "$min"; }
  echo "$p"
}
# Run a note block with /dev/sdb (and /dev/sdb1) pointing at the loop device.
run_block() { bash -ec "$(sed -e "s|/dev/sdb1|$SDB1|g; s|/dev/sdb|$SDB|g" <<<"$1")"; }
# The `$ cmd` lines of a console block.
cmds() { note_block "$NOTE" "$1" "${2:-1}" | sed -n 's/^\$ //p'; }

# The existing system: a VG "system" with a root LV on the first disk.
pvcreate -q "$SDA" && vgcreate -q system "$SDA" && lvcreate -q -n root -L 320M system >/dev/null
mkfs.xfs -q /dev/mapper/system-root
mkdir -p /mnt/root && mount /dev/mapper/system-root /mnt/root

section "1. Find the new disk"
check_output "/proc/partitions lists the new disk" " ${SDB#/dev/}\$" bash -ec "$(cmds 'Find the new disk')"
skip "SCSI rescan of a hot-added disk" "loop devices are not SCSI; the Docker VM has no SCSI host"

section "2. Partition it"
SDB1=$SDB
# Interactive parted needs a terminal. It also takes several commands as arguments,
# which runs the session's commands in order.
session=$(note_block "$NOTE" 'Partition it' 2 | sed 's/^(parted) //' | grep -v '^quit$' | tr '\n' ' ')
check "the interactive session's commands (from the note)" bash -c "parted -s $SDB $session >/dev/null"
check_output "made one GPT partition flagged lvm" '^1:.*lvm;' parted -sm "$SDB" print
parted -s "$SDB" mklabel msdos
check "the non-interactive commands (from the note)" run_block "$(note_block "$NOTE" 'Partition it' 3)"
check_output "same result: GPT, one partition, lvm flag" '^1:.*lvm;' parted -sm "$SDB" print
check_output "the label is gpt" ':gpt:' parted -sm "$SDB" print
SDB1=$(part_node "$SDB")
check_output "/proc/partitions now shows the partition" " ${SDB1#/dev/}\$" cat /proc/partitions

section "3. Create the physical volume"
check_output "pvs lists one PV" "$SDA +system" bash -ec "$(cmds 'Create the physical volume' 1)"
check_output "pvcreate (from the note)" 'successfully created' run_block "$(cmds 'Create the physical volume' 2)"

section "4. Extend the volume group"
check_output "the new PV has no VG" "$SDB1 +lvm2" pvs
check_output "vgextend (from the note)" 'successfully extended' run_block "$(cmds 'Extend the volume group' | grep vgextend)"
check_output "pvdisplay shows the new PV in the VG" "VG Name +system" bash -c "pvdisplay $SDB1"
check_output "with 4 MiB extents" 'PE Size +4\.00 MiB' bash -c "pvdisplay $SDB1"

section "5. Extend the logical volume"
out=$(bash -ec "$(cmds 'Extend the logical volume' 1)" 2>&1)
assert_match "lvextend -L+10M rounds up to 12 MiB (3 extents)" 'Rounding size to boundary between physical extents: 12\.00 MiB' "$out"
assert_match "and prints the output shown in the note" 'Size of logical volume system/root changed from 320\.00 MiB \(80 extents\) to 332\.00 MiB \(83 extents\)' "$out"
check "lvextend -l +100%FREE (from the note)" bash -ec "$(note_block "$NOTE" 'Extend the logical volume' 2)"
check_output "the VG has no free space left" '^ *0 *$' vgs --noheadings -o vg_free_count system
check_output "lvdisplay shows two segments" 'Segments +2' lvdisplay system/root
check_output "lvdisplay -m shows which PV each segment is on" "Physical volume[[:space:]]+$SDB1" lvdisplay -m system/root

section "6. Grow the filesystem"
before=$(df -m --output=size /mnt/root | tail -1)
check_output "xfs_growfs with the device path (from the note)" 'data blocks changed from' \
  bash -ec "$(cmds 'Grow the filesystem' 1)"
after=$(df -m --output=size /mnt/root | tail -1)
check "the mounted filesystem grew ($before -> $after MiB)" test "$after" -gt "$before"
# ext4: a second LV, so resize2fs has its own volume.
truncate -s 200M sdc.img
SDC=$(losetup -f --show sdc.img)
trap 'cleanup; losetup -d $SDC 2>/dev/null; _t_finish' EXIT
vgextend -q system "$SDC" && lvcreate -q -n data -L 100M system >/dev/null
mkfs.ext4 -q /dev/mapper/system-data
mkdir -p /mnt/data && mount /dev/mapper/system-data /mnt/data
lvextend -q -L+40M system/data >/dev/null
check_output "resize2fs grows a mounted ext4 online" 'on-line resizing required' \
  bash -ec "$(note_block "$NOTE" 'Grow the filesystem' 2 | sed 's|system-root|system-data|')"
tip=$(grep -o 'lvextend -r -l +100%FREE /dev/mapper/system-root' "$NOTES_ROOT/content/$NOTE.md" | head -1)
assert_eq "the tip shows lvextend -r" 'lvextend -r -l +100%FREE /dev/mapper/system-root' "$tip"
before=$(df -m --output=size /mnt/data | tail -1)
check "lvextend -r (from the tip) on the ext4 volume" bash -ec "${tip/system-root/system-data}"
after=$(df -m --output=size /mnt/data | tail -1)
check "grew the volume and the filesystem in one step ($before -> $after MiB)" test "$after" -gt "$before"

section "XFS cannot be shrunk"
blocks=$(xfs_growfs -n /mnt/root | sed -n 's/^data *= *bsize=[0-9]* *blocks=\([0-9]*\),.*/\1/p')
check_output "the correction: -D shrinks a little free space at the end, as experimental" \
  'EXPERIMENTAL.*shrink' xfs_growfs -D $((blocks - 2560)) /mnt/root
check_fails "xfs_growfs cannot shrink by half" xfs_growfs -D $((blocks / 2)) /mnt/root
check_output "ext4 cannot shrink while mounted" 'On-line shrinking not supported' \
  bash -c 'resize2fs /dev/mapper/system-data 50M 2>&1; true'
umount /mnt/data && e2fsck -fy /dev/mapper/system-data >/dev/null 2>&1 || true
check "ext4 can shrink while unmounted" resize2fs /dev/mapper/system-data 50M
