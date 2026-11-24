#!/usr/bin/env bash
# note: linux/distributions/opensuse-leap.md
# env: leap-systemd
# timeout: 1200
# Two local repositories with a tiny "demo" package (1.0 from vendor A, 2.0 from
# vendor B) test priorities, vendor stickiness, locks and orphans.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/distributions/opensuse-leap
F=$NOTES_ROOT/content/$NOTE.md
nb() { note_block "$NOTE" "$@"; }
Z="zypper -n -q"
$Z install --no-recommends rpm-build createrepo_c os-update permissions cronie >/dev/null

# demo VERSION VENDOR REPO: build a noarch demo package into REPO.
demo() {
  local d; d=$(mktemp -d)
  cat >"$d/demo.spec" <<SPEC
Name: demo
Version: $1
Release: 1
Summary: demo
License: MIT
Vendor: $2
BuildArch: noarch
%description
demo
%install
mkdir -p %{buildroot}/usr/share/demo %{buildroot}/usr/share/doc/demo
echo $1 > %{buildroot}/usr/share/demo/version
echo doc > %{buildroot}/usr/share/doc/demo/README
%files
/usr/share/demo/version
%doc /usr/share/doc/demo/README
SPEC
  rpmbuild -bb --quiet --define "_topdir $d" "$d/demo.spec" >/dev/null 2>&1
  mkdir -p "$3" && cp "$d"/RPMS/noarch/*.rpm "$3"/ && createrepo_c -q "$3"
}
demo 1.0 VendorA /srv/repo-a
demo 2.0 VendorB /srv/repo-b
$Z addrepo --no-gpgcheck file:///srv/repo-a repo-a >/dev/null
$Z addrepo --no-gpgcheck file:///srv/repo-b repo-b >/dev/null
$Z refresh >/dev/null

section "Which release these notes target"
check_output "the container is Leap 16.0" '^VERSION_ID="16\.0"' cat /etc/os-release
check_output "NetworkManager is in the distribution" 'NetworkManager' bash -c "$Z info NetworkManager | grep '^Name'"
check_output "wicked is still in the repository (community package)" 'bp160' bash -c "$Z info wicked | grep '^Version'"

section "Reclaiming disk space"
check "zypper clean --all (from the note)" bash -ec "$(nb 'Reclaiming disk space' 1)"
check "zypper clean, packages only (from the note)" bash -ec "$(nb 'Reclaiming disk space' 2)"
check_output "the correction: --packages does not exist" 'flag --packages is not known' bash -c 'zypper clean --packages 2>&1; true'
check_output "keeppackages is off: the Keep column says No or -" '\| (No|-) +\|' bash -c 'zypper repos --details | grep repo-oss'
check "zypper packages --unneeded (from the note)" bash -ec "$(nb 'Reclaiming disk space' 3)"
$Z install demo >/dev/null
check "zypper remove --clean-deps (from the note)" bash -ec "$(nb 'Reclaiming disk space' 4 | sed 's/zypper remove/zypper -n remove/; s/<package>/demo/')"
mkdir -p /etc/rpm/macros.d
nb 'Reclaiming disk space' 5 >/etc/rpm/macros.d/macros.lang
check_fails "rpm does not read /etc/rpm/macros.d/ (the original place)" bash -c "rpm -E '%_install_langs' | grep -q en_GB"
rm -r /etc/rpm/macros.d
nb 'Reclaiming disk space' 5 >/etc/rpm/macros.lang
check_output "it reads /etc/rpm/macros.lang" '^en:en_US:en_GB$' rpm -E '%_install_langs'
nb 'Reclaiming disk space' 6 >>/etc/zypp/zypp.conf
$Z install demo >/dev/null
check_fails "rpm.install.excludedocs = yes: the package's doc file is not installed" test -e /usr/share/doc/demo/README
check "but its other files are" test -e /usr/share/demo/version
sed -i '/^rpm.install.excludedocs/d' /etc/zypp/zypp.conf
$Z remove demo >/dev/null
tip=$(grep -o "rpm -qa --queryformat '%{SIZE}\\\\t%{NAME}\\\\n' | sort -n | tail -20" "$F")
check_output "the largest-packages tip" '^[0-9]+	[a-z]' bash -c "$tip"

section "Repository priorities"
check "zypper modifyrepo --priority (from the note)" bash -ec "$(nb 'Repository priorities' 1 | sed 's/<alias>/repo-b/')"
check_output "repo-b now has priority 90" 'repo-b .*\| +90 ' bash -c 'zypper repos --details'
check "the maximum priority 2147483647 is accepted" zypper -q modifyrepo --priority 2147483647 repo-b
zypper -q modifyrepo --priority 100 repo-b
$Z install demo >/dev/null
check_output "priority before version: 1.0 from repo-a (99), not 2.0 from repo-b (100)" '^demo-1\.0' rpm -q demo
$Z remove demo >/dev/null
zypper -q modifyrepo --priority 99 repo-b

section "Vendor stickiness"
$Z install demo-1.0 >/dev/null
$Z update >/dev/null || true
check_output "zypper update does not move demo to another vendor" '^demo-1\.0' rpm -q demo
cmd=$(nb 'Vendor stickiness' 1 | sed 's/zypper install/zypper -n install/; s/openSUSE:repo-oss/repo-b/; s/<package>/demo/')
check "--allow-vendor-change --from (from the note)" bash -ec "$cmd"
check_output "now demo is 2.0, from VendorB" '^demo-2\.0' rpm -q demo
$Z remove demo >/dev/null

section "Locking a package"
$Z install demo-1.0 >/dev/null
lk=$(nb 'Locking a package' 1 | sed 's/kernel-default/demo/; s/#.*//')
check "zypper addlock (from the note)" bash -ec "$(sed -n 1p <<<"$lk")"
check_output "zypper locks lists it" 'demo' bash -ec "$(sed -n 2p <<<"$lk")"
check_output "locks live in /etc/zypp/locks" 'solvable_name: demo' cat /etc/zypp/locks
out=$(zypper -n update 2>&1)
check_output "with the lock, demo stays at 1.0" '^demo-1\.0' rpm -q demo
assert_match "zypper update says it is held back, and goes on" 'will NOT be installed|not be installed' "$out"
check_fails "an explicit install of the update is refused" zypper -n install --allow-vendor-change demo-2.0
check "zypper removelock (from the note)" bash -ec "$(sed -n 3p <<<"$lk")"
check "addlock accepts a glob" zypper -q addlock 'kernel-*'
check_output "the glob is stored as such" 'kernel-\*' cat /etc/zypp/locks
zypper -q removelock 'kernel-*'
$Z remove demo >/dev/null

section "Repositories on Leap 16"
check_output "openSUSE-repos manages the repositories" '^openSUSE-repos-Leap' rpm -q openSUSE-repos-Leap
r=$(zypper repos --details)
for a in openSUSE:repo-oss openSUSE:repo-non-oss openSUSE:repo-oss-debug; do
  assert_match "alias $a" "\| $a +\|" "$r"
done
assert_match "from cdn.opensuse.org" 'cdn\.opensuse\.org' "$r"
assert_no_match "no update repository" 'repo-update' "$r"
check "enable and disable by alias (from the note)" bash -ec "$(nb 'Repositories on Leap 16' 2)"
check_output "repo-non-oss is enabled" 'openSUSE:repo-non-oss +\| [^|]+\| Yes' bash -c 'zypper repos'
zypper -q modifyrepo --disable openSUSE:repo-non-oss
skip "openSUSE:repo-oss-source" "the container's openSUSE service does not list a source repository"
check "third-party repos still go to /etc/zypp/repos.d" test -f /etc/zypp/repos.d/repo-a.repo
add=$(nb 'Repositories on Leap 16' 3 | sed 's|<project>|security|; s|<alias>|security|')
check "addrepo with --priority 100, then refresh (from the note, the security project)" bash -ec "$add"
check_output "the repository has priority 100" 'security .*\| +100 ' bash -c 'zypper repos --details'

section "Lynis (now in repo-oss)"
check_output "lynis is in the distribution repository" '^Repository +: repo-oss' bash -c "$Z info --repo openSUSE:repo-oss lynis"
check "zypper install lynis (from the note)" bash -ec "$(nb 'Auditing with lynis' 1 | sed 's/zypper install/zypper -n -q install/')"
check_output "lynis audit system --quick (from the note)" 'Lynis security scan details|Hardening index' \
  bash -c "timeout 300 $(nb 'Auditing with lynis' 2) 2>&1"
check "the report is in /var/log/lynis-report.dat" test -s /var/log/lynis-report.dat
zypper -q removerepo security

section "Unattended upgrades"
check "install and enable the timer (from the note)" bash -ec "$(nb 'Unattended upgrades' 1 | sed 's/zypper install/zypper -n -q install/')"
check "os-update.timer is active" systemctl is-active os-update.timer
check "vendor defaults are in /usr/share/os-update/os-update.conf" test -f /usr/share/os-update/os-update.conf
nb 'Unattended upgrades' 2 >/etc/os-update.conf
S=/usr/libexec/os-update
check "os-update reads /etc/os-update.conf" grep -q '/etc/os-update.conf' $S
for v in UPDATE_CMD REBOOT_CMD RESTART_SERVICES IGNORE_SERVICES_FROM_RESTART SERVICES_TRIGGERING_REBOOT LOG_TAG; do
  check "$v is a setting of os-update" grep -q "^$v=" $S
done
for v in auto dup up security; do check "UPDATE_CMD=$v is handled" grep -Eq "^[[:space:]]+\"?$v\"?\)" $S; done
for v in auto rebootmgr reboot; do check "REBOOT_CMD=$v is handled" grep -Eq "^[[:space:]]+\"?$v\"?\)" $S; done
check "UPDATE_CMD=security runs zypper patch --category security" grep -q 'patch .*--category security' $S
check "systemctl edit works on the timer (drop-in)" bash -c 'mkdir -p /etc/systemd/system/os-update.timer.d && printf "[Timer]\nOnCalendar=\nOnCalendar=*-*-* 03:00\n" >/etc/systemd/system/os-update.timer.d/override.conf && systemctl daemon-reload && systemctl cat os-update.timer | grep -q "03:00"'
check "journalctl -t (from the note)" bash -ec "$(nb 'Unattended upgrades' 4)"
check "the dry run of security patches (from the note)" bash -ec "$(nb 'Unattended upgrades' 5)"

section "Restarting what the patch affected"
check "zypper ps -s and needs-rebooting run (from the note)" bash -c "$(nb 'Restarting what the patch' 1 | sed 's/#.*//'); true"
check_output "zypper needs-rebooting exists" '[Rr]eboot' bash -c 'zypper needs-rebooting 2>&1; true'
check "os-update uses zypper ps to find services to restart" grep -q 'zypper ps' $S
check_fails "but it does not call zypper needs-rebooting (the note said it did)" grep -q 'needs-rebooting' $S

section "Useful commands"
check "patch-check and list-patches (from the note)" bash -c "$(nb 'Useful commands' 1); true"
check_output "zypper patch-check runs" 'patches needed|needed' bash -c 'zypper patch-check 2>&1; true'
$Z remove demo >/dev/null 2>&1 || true
check "--download-only (from the note)" bash -ec "$(nb 'Useful commands' 2 | sed 's/zypper install/zypper -n install/; s/<package>/demo/')"
check_fails "demo is not installed" rpm -q demo
check "the RPM is in /var/cache/zypp/packages/" bash -c 'ls /var/cache/zypp/packages/*/*/demo-*.rpm /var/cache/zypp/packages/*/demo-*.rpm 2>/dev/null | grep -q .'
check_output "rpm -qf and what-provides (from the note)" 'iproute2' bash -ec "$(nb 'Useful commands' 3)"
check "zypper verify (from the note)" bash -ec "$(nb 'Useful commands' 4 | sed 's/zypper verify/zypper -n verify/')"

section "SELinux"
check_output "the targeted policy is in the distribution" '^Name +: selinux-policy-targeted' bash -c "$Z info selinux-policy-targeted"
check_output "and enforcing is its default mode" 'SELINUX=enforcing' bash -c "$Z install --no-recommends selinux-policy-targeted >/dev/null 2>&1; cat /etc/selinux/config"
skip "sestatus, getenforce, AVC denials" "SELinux cannot be enabled inside a container; it belongs to the host kernel"
check_output "setroubleshoot and audit (ausearch) are in the distribution" 'setroubleshoot' bash -c "$Z info setroubleshoot audit | grep '^Name'"

section "File permissions and setuid monitoring"
$Z install --no-recommends sudo util-linux >/dev/null
par=$(chkstat --system --warn --level 'paranoid' 2>&1 || true)
assert_match "paranoid would remove the setuid bit of sudo" '/usr/bin/sudo' "$par"
assert_match "and of su" '/usr/bin/su' "$par"
chmod 755 /usr/bin/sudo
check_output "the correction: chkstat reads --dry-run as the path to check" '\-\-dry-run: .*Cannot check this path' \
  bash -c 'chkstat --system --dry-run 2>&1; true'
check_fails "and reports nothing about the rest" bash -c 'chkstat --system --dry-run 2>&1 | grep -q /usr/bin/sudo'
check_output "--warn (from the note) reports the wrong mode" '/usr/bin/sudo' bash -c "$(nb 'File permissions and setuid' 1 | grep -- '--warn' | sed 's/#.*//') 2>&1; true"
check_output "without changing it" '^755$' stat -c %a /usr/bin/sudo
check "chkstat --system (from the note)" bash -c "$(nb 'File permissions and setuid' 1 | grep -- '--system  ' | sed 's/#.*//')"
check_output "applies the profile: the setuid bit of sudo is back" '^4755$' stat -c %a /usr/bin/sudo
check_output "PERMISSION_SECURITY is in /etc/sysconfig/security" '^PERMISSION_SECURITY=' cat /etc/sysconfig/security
for p in easy secure paranoid; do check "profile $p ships in /usr/share/permissions/" test -f /usr/share/permissions/permissions.$p; done
check "/etc/permissions.local exists" test -f /etc/permissions.local

section "Verifying package integrity"
check_output "file digests are SHA-256 (algorithm 8)" '^8$' rpm -q --qf '%{FILEDIGESTALGO}\n' bash
echo '# local change' >>/etc/zypp/zypp.conf
echo x >>/usr/share/os-update/os-update.conf
chmod 600 /usr/lib/systemd/system/os-update.service
out=$(rpm -V os-update libzypp 2>&1 || true)
assert_match "rpm -V flags a changed config file with 5 and c" '^S\.5\.\.\.\.T\.  c /etc/zypp/zypp\.conf$' "$out"
assert_match "and a changed non-config file" '^S\.5\.\.\.\.T\.    /usr/share/os-update/os-update\.conf$' "$out"
assert_match "and a mode change with M" '^\.M\.+  +/usr/lib/systemd/system/os-update\.service$' "$out"
old=$(rpm -V os-update libzypp | grep -v '^..5......  c ' || true)
assert_match "the original filter still shows the mode-only change (it is not a content filter)" 'os-update\.service' "$old"
new=$(bash -c "$(nb 'Verifying package integrity' 2 | sed 's/rpm -Va/rpm -V os-update libzypp/')" || true)
assert_match "the note's filter shows the changed non-config file" 'os-update\.conf' "$new"
assert_no_match "and not the mode-only change" 'os-update\.service' "$new"
assert_no_match "nor the config file" 'zypp\.conf' "$new"
check "rpm --verify --all runs (from the note)" bash -c "$(nb 'Verifying package integrity' 1) >/dev/null; true"

section "Finding orphaned packages"
$Z install demo-1.0 >/dev/null
zypper -q removerepo repo-a
zypper -q modifyrepo --disable repo-b
check_output "--remove-orphaned (from the note)" 'demo' bash -c "$(nb 'Finding orphaned packages' 4 | sed 's/dist-upgrade/-n dist-upgrade --dry-run/') 2>&1 | grep -A3 REMOVED"
check_output "a package no repository provides is orphaned (from the note)" 'demo' bash -ec "$(nb 'Finding orphaned packages' 1)"
check_output "zypper dist-upgrade keeps it (the note said it removes it)" '^demo-1\.0' \
  bash -c 'zypper -n dist-upgrade --dry-run >/dev/null 2>&1; zypper -n dist-upgrade --dry-run 2>&1 | grep -q "demo" && echo listed; rpm -q demo'
check_fails "dup would not remove demo" bash -c 'zypper -n dist-upgrade --dry-run 2>&1 | grep -A3 "REMOVED" | grep -qw demo'
$Z remove demo >/dev/null

section "Linux Malware Detect (maldet)"
url=$(nb 'Linux Malware Detect' 1 | grep -o 'https\?://[^ ]*')
check_output "the maldet tarball URL answers" '^200$' curl -sSL -o /tmp/maldet.tgz -w '%{http_code}' "$url"
check_output "it holds an install.sh" '/install\.sh$' tar -tzf /tmp/maldet.tgz
skip "./install.sh, maldet -u" "a third-party root installer: the test does not run it"
$Z install --no-recommends clamav >/dev/null
check "SUSE names the unit clamd.service" systemctl cat clamd.service
check "and freshclam.service" systemctl cat freshclam.service
check_fails "there is no clamav-daemon.service" systemctl cat clamav-daemon.service
check "/var/lib/clamav exists for the symlinks" test -d /var/lib/clamav
check_output "the clamscan options (from the note)" 'Infected files: 0' \
  bash -c "cd /tmp && $(touch /tmp/empty.hdb; nb 'Linux Malware Detect' 4 | sed 's|clamscan |clamscan -d /tmp/empty.hdb /usr/share/os-update |') 2>&1; true"

section "Restricting cron"
useradd -m your.name && useradd -m bob
echo ALL >/etc/cron.deny
check_output "the correction: ALL in cron.deny does not deny other users" 'no crontab for bob' bash -c "su bob -c 'crontab -l' 2>&1; true"
rm /etc/cron.deny
check "echo your.name >> /etc/cron.allow (from the note)" bash -ec "$(nb 'Restricting cron' 1)"
check_output "your.name may use crontab" 'no crontab for your.name' bash -c "su your.name -c 'crontab -l' 2>&1; true"
check_output "anyone else is refused once cron.allow exists" 'not allowed' bash -c "su bob -c 'crontab -l' 2>&1; true"
echo bob >/etc/cron.deny
check_output "cron.deny is ignored when cron.allow exists" 'not allowed' bash -c "su bob -c 'crontab -l' 2>&1; true"
: >/etc/cron.allow
check_output "with an empty cron.allow, root may still use crontab" 'no crontab for root' bash -c 'crontab -l 2>&1; true'
rm -f /etc/cron.allow /etc/cron.deny
check_output "with only cron.deny, a listed user is refused" 'not allowed' bash -c "echo bob >/etc/cron.deny; su bob -c 'crontab -l' 2>&1; true"
rm -f /etc/cron.deny

section "Disabling Ctrl+Alt+Del"
check "systemctl mask (from the note)" bash -ec "$(nb 'Disabling Ctrl+Alt+Del' 1)"
assert_link "it is a link to /dev/null" /etc/systemd/system/ctrl-alt-del.target /dev/null

section "Disabling the Magic SysRq key"
# kernel.sysrq belongs to the shared Docker VM kernel: write the file, do not apply it.
check "the drop-in file (from the note, without sysctl --system)" bash -ec "$(nb 'Magic SysRq' 1 | grep -v 'sysctl --system')"
check_output "systemd-sysctl would apply it" 'kernel.sysrq = 0' bash -c '/usr/lib/systemd/systemd-sysctl --cat-config 2>&1; true'
skip "sysctl --system" "kernel.sysrq is global to the Docker VM shared by every container"
check "the shipped sysctl settings are in /usr/lib/sysctl.d" test -d /usr/lib/sysctl.d
check_fails "there is no /etc/sysctl.conf on Leap 16" test -e /etc/sysctl.conf
