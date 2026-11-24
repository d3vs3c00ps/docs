#!/usr/bin/env bash
# note: security/cryptography/certificate-generation.md
# env: rocky
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/cryptography/certificate-generation
cd "$(mktemp -d)"

section "Route 1 on Rocky"
note_block "$NOTE" 'Route 1' 1 >generate.sh
check "the usage example runs (from the note)" \
  bash -ec "$(note_block "$NOTE" Usage 1 | sed 's|^\./generate.sh|bash generate.sh|') >/dev/null 2>&1"

section "Trusting the CA (RHEL, Rocky and Fedora)"
check_fails "before: the system store does not trust the lab CA" openssl verify certs/bastion-01.example.com.crt
check "copy and update-ca-trust (from the note)" \
  bash -ec "$(note_block "$NOTE" 'Trusting the CA' 2 | sed 's/^sudo //')"
check "after: openssl verify trusts it with no -CAfile" openssl verify certs/bastion-01.example.com.crt
check_output "and the CA is in the extracted bundle" 'ExampleCA' \
  bash -c 'trust list --filter=ca-anchors | grep -A2 ExampleCA'
