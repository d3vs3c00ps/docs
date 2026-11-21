#!/usr/bin/env bash
# note: containers/containerd/basics.md
# env: priv:leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=containers/containerd/basics
# The note's openSUSE line installs containerd; check it on Leap 16 itself.
leap=$(note_block "$NOTE" 1 | grep zypper | sed 's/^sudo //')
assert_eq "the note's openSUSE install line" 'zypper install containerd' "$leap"

section "Installing (openSUSE Leap)"
check "the note's line installs it (non-interactive)" \
  bash -ec "${leap/zypper install/zypper -n -q install --no-recommends} >/dev/null"
check_output "containerd --version (the note's next block)" '^containerd ' containerd --version
check_output "runc comes with it" 'runc version' runc --version
