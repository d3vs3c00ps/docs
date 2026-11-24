#!/usr/bin/env bash
# note: security/auditd.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

# openSUSE claims of the note. Nothing here talks to the kernel audit system.
zypper -n -q install --no-recommends audit >/dev/null

section "Where the rules live"
check "Leap 16 ships the sample sets in /usr/share/audit-rules" test -f /usr/share/audit-rules/30-stig.rules
check_output "the default rules.d file turns off syscall auditing with -a task,never" '^-a task,never' \
  cat /etc/audit/rules.d/audit.rules

section "Restarting auditd"
check_fails "openSUSE's auditd.service has no RefuseManualStop" grep -q RefuseManualStop /usr/lib/systemd/system/auditd.service
