#!/usr/bin/env bash
# note: linux/storage/swap.md
# env: priv:leap
# vm.swappiness and the list of swap areas belong to the Docker VM's kernel, which
# every container shares: the test puts the old value back and removes its swap areas.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/storage/swap
zypper -n -q install --no-recommends lvm2 >/dev/null
export DM_DISABLE_UDEV=1   # no udev: libdevmapper makes the /dev/mapper nodes
old=$(cat /proc/sys/vm/swappiness)
cd "$(mktemp -d)"
truncate -s 100M disk.img
DISK=$(losetup -f --show disk.img)
cleanup() {
  swapoff /dev/mapper/rhel-swap1 /dev/mapper/rhel-swap2 2>/dev/null || true
  vgchange -an rhel >/dev/null 2>&1 || true
  losetup -d "$DISK" 2>/dev/null || true
  echo "$old" >/proc/sys/vm/swappiness
}
trap 'cleanup; _t_finish' EXIT
trap 'exit 1' TERM INT

section "Identifying swap usage"
out=$(bash -ec "$(note_block "$NOTE" 'Identifying swap usage')")
assert_match "free -m has a Swap line" '^Swap:' "$out"
assert_match "swapon -s lists devices with size, usage and priority" '^Filename[[:space:]]+Type[[:space:]]+Size[[:space:]]+Used[[:space:]]+Priority' "$out"
check_output "swapon --show is the current form of swapon -s" 'NAME +TYPE +SIZE +USED +PRIO' swapon --show

section "Swappiness"
check_output "the value is read from /proc (from the note)" '^[0-9]+$' bash -ec "$(note_block "$NOTE" 'Swappiness' 1 | sed -n 's/^\$ //p')"
check "sysctl -w (from the note)" bash -ec "$(note_block "$NOTE" 'Swappiness' 2)"
assert_eq "the running value is 15" 15 "$(cat /proc/sys/vm/swappiness)"
echo 60 >/proc/sys/vm/swappiness
check_output "the drop-in file is applied by sysctl --system (from the note)" '99-swappiness\.conf' \
  bash -ec "$(note_block "$NOTE" 'Swappiness' 3)"
assert_eq "and sets 15" 15 "$(cat /proc/sys/vm/swappiness)"
check "the range goes up to 200 since Linux 5.8, not 100" sysctl -q -w vm.swappiness=200
check_fails "201 is refused" sysctl -q -w vm.swappiness=201

section "Swap priorities"
vgcreate -q rhel "$DISK" >/dev/null
lvcreate -q -n swap1 -L 20M rhel >/dev/null && lvcreate -q -n swap2 -L 20M rhel >/dev/null
mkswap -q /dev/mapper/rhel-swap1 && mkswap -q /dev/mapper/rhel-swap2
note_block "$NOTE" 'Swap priorities' 2 | grep ' swap ' >fstab
check "swapon -a reads the note's fstab lines" swapon -a -T fstab
show=$(swapon --show=NAME,PRIO --noheadings)
assert_match "pri=1 on swap1" 'rhel-swap1 +1$' "$show"
assert_match "pri=2 on swap2" 'rhel-swap2 +2$' "$show"
skip "the kernel fills the highest priority first" \
  "the Docker VM already uses its own swap file, and the swap allocator keeps using it; this needs a machine of its own"
