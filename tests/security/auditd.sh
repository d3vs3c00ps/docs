#!/usr/bin/env bash
# note: security/auditd.md
# env: rocky-systemd
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/auditd
# noscripts: no %post, so nothing can start auditd. The container shares the Docker
# host's kernel: this test never sends a rule or a signal to the kernel audit system.
dnf -y -q install --setopt=install_weak_deps=False --setopt=tsflags=noscripts audit audit-rules >/dev/null
cd "$(mktemp -d)"

section "Where the rules live"
check "the sample rule sets are in /usr/share/audit-rules (the correction)" test -f /usr/share/audit-rules/30-stig.rules
check "a PCI DSS set too" bash -c 'ls /usr/share/audit-rules/30-pci-dss-*.rules'
check_fails "and no CIS set" bash -c 'ls /usr/share/audit-rules/ | grep -i cis'
check_fails "the old /usr/share/audit/ path is gone on audit 4" test -d /usr/share/audit
check_output "audit-rules.service runs augenrules --load at boot" 'ExecStart=.*augenrules --load' \
  cat /usr/lib/systemd/system/audit-rules.service
check "the note's commands exist (augenrules, auditctl)" bash -c "$(note_block "$NOTE" 'Where the rules live' 1 | awk '{print "command -v", $1}')"
skip "augenrules --load and auditctl -l" "they load rules into the kernel, which is the shared Docker host's kernel"

section "Rule ordering"
# A stand-in auditctl, so augenrules' immutable check does not query the kernel.
mkdir -p stub && printf '#!/bin/sh\necho "enabled 1"\n' >stub/auditctl && chmod +x stub/auditctl
rm -f /etc/audit/rules.d/*.rules
note_block "$NOTE" 'Ignoring events' 1 >/etc/audit/rules.d/10-exclude.rules
note_block "$NOTE" 'Ignoring events' 2 >/etc/audit/rules.d/9-never.rules
note_block "$NOTE" 'Tag rules with a key' 1 >/etc/audit/rules.d/50-identity.rules
note_block "$NOTE" 'Making the rule set immutable' 1 >/etc/audit/rules.d/20-finalize.rules
printf -- '-b 8192\n' >/etc/audit/rules.d/99-buffers.rules
check "augenrules (no --load) compiles the fragments" env PATH="$PWD/stub:$PATH" augenrules
rules=$(grep -v '^#' /etc/audit/audit.rules | grep .)
assert_eq "natural order: 9- before 10-, -b moved to the top, -e 2 moved to the end" \
  "-b 8192
$(note_block "$NOTE" 'Ignoring events' 2)
$(note_block "$NOTE" 'Ignoring events' 1)
$(note_block "$NOTE" 'Tag rules with a key' 1)
-e 2" "$rules"
skip "the rules' syntax" "auditctl checks a rule only when it sends it to the kernel, which is shared with the Docker host"

section "Excluding what you do not need"
# A small log with today's dates: two runs of vi writing /etc/shadow, one of cat.
now=$(date +%s)
{
  for i in 1 2 3; do
    t=$((now - 60 * i))
    exe=/usr/bin/vi comm=vi key=identity
    ((i == 3)) && exe=/usr/bin/cat comm=cat key="(null)"
    [[ $key == identity ]] && key='"identity"'
    echo "type=SYSCALL msg=audit($t.100:$((100 + i))): arch=c000003e syscall=257 success=yes exit=3 a0=ffffff9c a1=1 a2=241 a3=1b6 items=1 ppid=1 pid=$((200 + i)) auid=0 uid=0 gid=0 euid=0 suid=0 fsuid=0 egid=0 sgid=0 fsgid=0 tty=pts0 ses=1 comm=\"$comm\" exe=\"$exe\" subj=unconfined key=$key"
    echo "type=CWD msg=audit($t.100:$((100 + i))): cwd=\"/root\""
    echo "type=PATH msg=audit($t.100:$((100 + i))): item=0 name=\"/etc/shadow\" inode=1 dev=fd:00 mode=0100000 ouid=0 ogid=0 rdev=00:00 nametype=NORMAL cap_fp=0 cap_fi=0 cap_fe=0 cap_fver=0 cap_frootid=0"
  done
} >/var/log/audit/audit.log
report=$(bash -c "$(note_block "$NOTE" 'Excluding what you do not need' 1 | sed -n 2p)" 2>&1)
assert_match "aureport -x --summary counts events by executable (from the note)" '2 +/usr/bin/vi' "$report"
report=$(bash -c "$(note_block "$NOTE" 'Excluding what you do not need' 1 | sed -n 5p)" 2>&1)
assert_match "aureport -s --summary, with -i, names the syscall (from the note)" '3 +openat' "$report"

section "Tag rules with a key"
check_output "ausearch -k finds the tagged events (from the note)" 'key="identity"' \
  bash -c "$(note_block "$NOTE" 'Tag rules with a key' 2)"
check_fails "and only those: cat's event has no key" bash -c "ausearch -k identity | grep -q 'comm=\"cat\"'"

section "Restarting auditd"
check_output "auditd.service has RefuseManualStop=yes on RHEL" '^RefuseManualStop=yes' cat /usr/lib/systemd/system/auditd.service
# The same setting on a harmless unit shows the message, without touching auditd.
printf '[Service]\nExecStart=/usr/bin/sleep infinity\n[Unit]\nRefuseManualStop=yes\n' >/etc/systemd/system/refuse-demo.service
systemctl daemon-reload
check_output "systemctl restart is refused, with the note's message" \
  'Operation refused, unit refuse-demo.service may be requested by dependency only \(it is configured to refuse manual start/stop\)' \
  bash -c 'systemctl restart refuse-demo 2>&1; true'
check_fails "without weak dependencies, there is no service command" command -v service
check_output "audit recommends initscripts-service, which has it" '^initscripts-service' dnf -q repoquery --recommends audit
dnf -y -q install --setopt=tsflags=noscripts initscripts-service >/dev/null
check "then service is there" command -v service
legacy=/usr/libexec/initscripts/legacy-actions/auditd/restart
check_output "the legacy restart action sends 'auditctl --signal stop'" '^/sbin/auditctl --signal stop' cat "$legacy"
check_output "then runs systemctl start auditd" 'systemctl start auditd' cat "$legacy"
skip "service auditd restart" "it signals and starts auditd, which would take over the shared kernel's audit system"
