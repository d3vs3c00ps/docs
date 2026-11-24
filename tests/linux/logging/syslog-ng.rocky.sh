#!/usr/bin/env bash
# note: linux/logging/syslog-ng.md
# env: rocky-systemd
# The RHEL family: EPEL, the s_sys source name and /etc/default/syslog-ng.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/logging/syslog-ng
yes_dnf() { sed 's/^dnf install "/dnf -y -q install "/; s/^dnf install -y/dnf -y -q install/'; }

section "Installation (RHEL family)"
check_fails "syslog-ng is not in the base repositories" dnf -q list --available syslog-ng
check "EPEL, then syslog-ng (from the note)" bash -ec "$(note_block "$NOTE" Installation 2 | yes_dnf)"
check_output "syslog-ng comes from EPEL" 'epel' bash -c "dnf -q info --installed syslog-ng | grep -i 'from repo'"
dnf -y -q install rsyslog >/dev/null
check "dnf remove -y rsyslog (from the note)" bash -ec "$(note_block "$NOTE" Installation 3)"
check_fails "rsyslog is gone" rpm -q rsyslog
dnf -y -q install dnf-plugins-core >/dev/null
check "the COPR repository of the tip can be enabled" dnf -y -q copr enable czanik/syslog-ng-stable
check_output "and offers syslog-ng" 'syslog-ng' dnf -q --repo 'copr:*' list --available syslog-ng

section "Configuration"
check_output "RHEL's default source is s_sys" '^source s_sys \{' cat /etc/syslog-ng/syslog-ng.conf

section "Running in a container"
check "the note's /etc/default/syslog-ng line" bash -ec "$(note_block "$NOTE" 'Running in a container' 2) && echo \"\$SYSLOGNG_OPTS\" | grep -q no-caps"
note_block "$NOTE" 'Running in a container' 2 >/etc/default/syslog-ng
check "the unit reads /etc/default/syslog-ng" bash -c "systemctl cat syslog-ng | grep -q 'EnvironmentFile=-/etc/default/syslog-ng'"
check "enable --now (from the note)" bash -ec "$(note_block "$NOTE" 'Enabling the service' 1)"
check_output "syslog-ng runs with --no-caps" '--no-caps' bash -c 'sleep 2; ps -o args= -C syslog-ng'
