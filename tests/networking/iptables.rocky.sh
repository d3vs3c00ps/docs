#!/usr/bin/env bash
# note: networking/iptables.md
# env: rocky-systemd
# The RHEL part of "Persistence". The rest runs on Leap (iptables.sh).
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=networking/iptables

section "Persistence"
check "install iptables-services and enable both units (from the note)" \
  bash -ec "$(note_block "$NOTE" Persistence 3 | sed 's/^dnf install/dnf -y -q install/')"
check "iptables.service is active" systemctl is-active iptables
check "ip6tables.service is active" systemctl is-active ip6tables
check_output "it loads /etc/sysconfig/iptables" '/etc/sysconfig/iptables' systemctl cat iptables
check_output "the default file is there" '^\*filter' cat /etc/sysconfig/iptables
check_output "and its rules are loaded" 'icmp' iptables -S INPUT
iptables -F INPUT
iptables -A INPUT -p tcp --dport 8443 -j ACCEPT
iptables-save >/etc/sysconfig/iptables
iptables -F INPUT
check "a restart" systemctl restart iptables
check_output "restores what was saved in /etc/sysconfig/iptables" 'dport 8443' iptables -S INPUT
