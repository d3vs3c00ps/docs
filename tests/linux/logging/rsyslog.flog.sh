#!/usr/bin/env bash
# note: linux/logging/rsyslog.md
# env: go
# timeout: 900
# The note's test-log generator, flog. The Go image stands in for `zypper install go`.
source "$NOTES_ROOT/tests/lib/assert.sh"

section "Generating test logs"
install=$(note_block linux/logging/rsyslog 'Generating test logs' 1 | grep '^go install')
check "go install flog (from the note)" bash -ec "$install"
run=$(note_block linux/logging/rsyslog 'Generating test logs' 1 | grep 'flog -f' | sed "s|~/go/bin|$(go env GOPATH)/bin|; s|/var/log/generated.log|/tmp/generated.log|")
check "flog writes 2000 RFC5424 lines (from the note)" bash -ec "$run"
check_output "2000 lines" '^2000$' bash -c 'wc -l </tmp/generated.log'
check_output "in RFC5424 layout" '^<[0-9]+>[0-9] [0-9]{4}-[0-9]{2}-[0-9]{2}T' head -1 /tmp/generated.log
versions=$(cut -d' ' -f1 /tmp/generated.log | sed 's/^<[0-9]*>//' | sort -u | tr '\n' ' ')
assert_match "but the VERSION field is random, not always 1 (the note's warning)" '^1 2 3 $' "$versions"
