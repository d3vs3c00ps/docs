#!/usr/bin/env bash
# note: linux/logging/rsyslog.md
# env: rocky
# The RHEL half of the note's RELP install block. The rest runs on Leap (rsyslog.sh).
source "$NOTES_ROOT/tests/lib/assert.sh"

section "Using RELP"
check "RHEL: dnf install -y rsyslog-relp (from the note)" \
  bash -ec "$(note_block linux/logging/rsyslog 'Using RELP' 1 | grep '^dnf ' | sed 's/ *#.*//')"
check_output "it ships imrelp and omrelp" 'imrelp\.so' rpm -ql rsyslog-relp
check_output "and omrelp" 'omrelp\.so' rpm -ql rsyslog-relp
