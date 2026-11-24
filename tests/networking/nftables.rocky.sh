#!/usr/bin/env bash
# note: networking/nftables.md
# env: rocky
# The RHEL rows of the note. The rest runs on Leap (nftables.sh).
source "$NOTES_ROOT/tests/lib/assert.sh"

dnf -y -q install nftables >/dev/null

section "Persistence"
check_output "RHEL's nftables.service loads /etc/sysconfig/nftables.conf" '/etc/sysconfig/nftables\.conf' \
  cat /usr/lib/systemd/system/nftables.service

section "iptables and firewalld"
check_fails "a default install has no iptables.service" test -e /usr/lib/systemd/system/iptables.service
dnf -y -q install iptables-services >/dev/null
check "it comes from the iptables-services package" test -e /usr/lib/systemd/system/iptables.service
check "firewalld is a package here too" dnf -q info firewalld
