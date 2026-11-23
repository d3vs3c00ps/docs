#!/usr/bin/env bash
# note: security/kernel-modules.md
# env: leap
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/kernel-modules
MODULEJAIL_VERSION=v1.6.3
# The container shares the Docker host's kernel and cannot load modules (no
# CAP_SYS_MODULE). This test never tries: it works on the Leap 16 kernel's module tree,
# unpacked from the RPMs, with modinfo and `modprobe -n` (dry run).
zypper -n -q install --no-recommends kmod cpio >/dev/null
cd "$(mktemp -d)"
zypper -n -q --pkg-cache-dir "$PWD/cache" download kernel-default kernel-default-extra kernel-default-optional >/dev/null
R=$PWD/root
mkdir "$R"
find cache -name 'kernel-default*.rpm' -print0 | while IFS= read -r -d '' f; do (cd "$R" && rpm2cpio "../$f" | cpio -idm --quiet); done
K=$(ls "$R/usr/lib/modules")
depmod -b "$R" "$K"
# mp CONFDIR ARGS: modprobe in dry-run mode, on the unpacked tree, with only CONFDIR's config.
mp() { local c=$1; shift; modprobe -n -v -d "$R" -S "$K" -C "$c" "$@"; }

section "Kernel module attack surface"
n=$(find "$R/usr/lib/modules/$K" -name '*.ko*' | wc -l)
base=$(rpm2cpio "$(find cache -name 'kernel-default-6*.rpm')" | cpio -t --quiet 2>/dev/null | grep -c '\.ko')
if [[ $(uname -m) == x86_64 ]]; then
  assert_match "the Leap 16 kernel ships about 4,900 modules on x86_64 ($n)" '^4[5-9][0-9]{2}$|^5[0-2][0-9]{2}$' "$n"
  assert_match "about 2,300 in kernel-default alone ($base)" '^2[0-5][0-9]{2}$' "$base"
else
  assert_match "the Leap 16 kernel ships about 6,600 modules on arm64 ($n)" '^6[0-9]{3}$' "$n"
  assert_match "about 2,600 in kernel-default alone ($base)" '^2[0-9]{3}$' "$base"
fi

section "Blacklisting by hand"
mkdir hard; note_block "$NOTE" 'Blacklisting by hand' 1 >hard/hardening.conf
mods=$(awk '$1 == "install" { print $2 }' hard/hardening.conf)
for m in decnet econet ipx p8023 af_802154; do
  check_fails "$m (removed from the kernel, the correction) is not in the list" grep -qw "$m" hard/hardening.conf
  check_fails "and this kernel does not have it" modinfo -b "$R" -k "$K" "$m"
done
check "every install line has its blacklist line" \
  bash -c "diff <(awk '\$1==\"install\"{print \$2}' hard/hardening.conf) <(awk '\$1==\"blacklist\"{print \$2}' hard/hardening.conf)"
check_fails "no /bin/true left" grep -q '/bin/true' hard/hardening.conf
present=0 blocked=0
for m in $mods; do
  modinfo -b "$R" -k "$K" "$m" >/dev/null 2>&1 || continue
  present=$((present + 1))
  mp hard "$m" 2>&1 | grep -q '^install /bin/false' && blocked=$((blocked + 1))
done
assert_eq "modprobe would run /bin/false for each listed module this kernel has ($present)" "$present" "$blocked"
assert_match "most of the list exists in a 6.12 kernel" '^(1[5-9]|2[0-9])$' "$present"
check_output "dccp is still in the 6.12 kernel (removed in 6.16)" 'dccp\.ko' modinfo -b "$R" -k "$K" -F filename dccp

# The socket alias belongs to dccp_ipv4, which needs dccp.
alias=net-pf-2-proto-33-type-6
mkdir bl none && echo 'blacklist dccp' >bl/bl.conf
check_output "the kernel's socket alias for DCCP is dccp_ipv4's" "^alias $alias dccp_ipv4\$" cat "$R/usr/lib/modules/$K/modules.alias"
check_output "without config, the alias loads dccp, then dccp_ipv4" 'insmod .*/dccp\.ko.*' mp none "$alias"
check_output "with only blacklist dccp, the alias still loads dccp (the callout)" 'insmod .*/dccp\.ko' mp bl "$alias"
check_output "and modprobe dccp by name still would" 'insmod .*/dccp\.ko' mp bl dccp
check_output "with install dccp /bin/false, the alias runs /bin/false for the dependency" '^install /bin/false' mp hard "$alias"
check_fails "so dccp.ko is never inserted" bash -c "mp hard '$alias' 2>&1 | grep -q '/dccp\.ko'"
check_fails "/bin/false makes the load fail" /bin/false
check "the note's dracut command is a real dracut option" bash -c "zypper -n -q install --no-recommends dracut >/dev/null && dracut --help | grep -q -- '-f, --force'"

section "modulejail"
check "download the pinned version (from the note)" bash -ec "$(note_block "$NOTE" modulejail 1 | grep '^curl')"
assert_match "the note pins the latest tag" "/$MODULEJAIL_VERSION/" "$(note_block "$NOTE" modulejail 1)"
# Test-only overrides from modulejail itself: a fake /proc/modules and the unpacked tree.
# modulejail refuses to block more than 99% of the tree, so "load" about 150 modules.
{ printf '%s\n' overlay br_netfilter xfs virtio_net; sed -n 's|.*/\([^/]*\)\.ko.*|\1|p' "$R/usr/lib/modules/$K/modules.order" | grep -v dccp | awk 'NR <= 150'; } |
  sed 's/-/_/g; s/$/ 16384 0 - Live 0x0/' >proc-modules
export MODULEJAIL_PROC_MODULES=$PWD/proc-modules MODULEJAIL_KVER=$K MODULEJAIL_MODULES_ROOT=$R/usr/lib/modules MODULEJAIL_NO_UPDATE_CHECK=1
dry=$(bash -c "$(note_block "$NOTE" modulejail 1 | grep -e '--dry-run' | sed 's/^sudo //')" 2>&1)
assert_match "--dry-run prints a summary (from the note)" 'blacklist|block' "$dry"
assert_no_file "and writes nothing" /etc/modprobe.d/modulejail-blacklist.conf
check "a real run (from the note)" bash -c "$(note_block "$NOTE" modulejail 1 | tail -1 | sed 's/^sudo //')"
out=/etc/modprobe.d/modulejail-blacklist.conf
assert_file "it writes the file the note names" "$out"
check_output "it blocks dccp, which is not loaded" '^install dccp ' cat "$out"
check_fails "and leaves overlay, which is loaded" grep -q '^install overlay ' "$out"
check_output "default lines log and exit 0" '^install dccp .*logger -t modulejail.*exit 0' cat "$out"
check_output "wc -l on the file (from the note)" '[0-9]{4} ' bash -c "$(note_block "$NOTE" modulejail 3)"
total=$(wc -l <"$out")
rm "$out"
check "-p desktop (from the note)" bash -c "$(note_block "$NOTE" modulejail 2 | sed 's/^sudo //')"
desktop=$(wc -l <"$out")
check "the desktop profile blocks fewer modules ($desktop, against $total)" test "$desktop" -lt "$total"
check_fails "it keeps the sound core" grep -q '^install snd ' "$out"
check_output "-f makes blocked loads fail" '^install dccp .*/bin/false' bash -c "sh ./modulejail -f -o f.conf >/dev/null 2>&1; cat f.conf"
check_output "--install-initramfs-hook exists" 'install-initramfs-hook' sh ./modulejail --help

section "The complementary controls"
check_output "Leap 16's kernel turns on lockdown with Secure Boot" '^CONFIG_LOCK_DOWN_IN_EFI_SECURE_BOOT=y' cat "$R/usr/lib/modules/$K/config"
check_output "and does not force it otherwise" '^CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y' cat "$R/usr/lib/modules/$K/config"
skip "/sys/kernel/security/lockdown" "it shows the Docker host's kernel, not a Secure Boot machine"

section "Preventing loading entirely"
skip "kernel.modules_disabled=1" "one-way switch on the shared Docker host kernel"
check_output "the sysctl exists in this kernel's sysctl list" 'modules_disabled' bash -c 'ls /proc/sys/kernel/'
check "modules-load.d names real modules (from the note)" \
  bash -c "for m in \$(note_block $NOTE 'modules_disabled=1' 1 | grep -v '^#'); do modinfo -b '$R' -k '$K' \"\$m\" >/dev/null || exit 1; done"

section "Auditing"
skip "auditctl -a ... -S init_module,finit_module" "it adds a rule to the shared Docker host kernel"
