#!/usr/bin/env bash
# note: linux/boot/grub.md
# env: rocky
# The RHEL side of the UEFI correction: the EFI grub.cfg is a stub, and
# grub2-mkconfig warns when asked to overwrite it.
source "$NOTES_ROOT/tests/lib/assert.sh"

dnf -y -q install --setopt=install_weak_deps=False grub2-tools >/dev/null

section "UEFI"
check "RHEL also regenerates with grub2-mkconfig" command -v grub2-mkconfig
check_output "grub2-mkconfig warns before it overwrites the EFI stub" 'will overwrite the GRUB wrapper' cat "$(command -v grub2-mkconfig)"
check_output "and names /boot/grub2/grub.cfg as the file to write" "grub2-mkconfig -o /boot/grub2/grub.cfg' instead" cat "$(command -v grub2-mkconfig)"
check_fails "there is no update-grub" command -v update-grub
