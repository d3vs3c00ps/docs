#!/usr/bin/env bash
# note: linux/distributions/nixos/hardening.md
# env: nix
# timeout: 3600
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/nixos-vm.sh"

section "Kernel and network (booted in a VM)"
nixos_vm_check "the kernel block boots and does what the note says" \
  linux/distributions/nixos/hardening hardening.vm.nix
