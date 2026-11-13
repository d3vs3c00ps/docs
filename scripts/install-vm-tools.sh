#!/usr/bin/env bash
# Install QEMU and UEFI firmware, to boot the NixOS installer ISO in a VM
# (scripts/nixos-iso.sh test). Debian and Ubuntu only: it uses apt, and sudo when
# not root. The devcontainer runs it on creation; CI runs it before the ISO test.
#
# Usage: scripts/install-vm-tools.sh
set -euo pipefail

# The VM runs at full speed only for the machine's own architecture, with KVM.
# The other one is installed too, so an ISO for it can be booted, slowly.
pkgs=(qemu-utils qemu-system-x86 ovmf qemu-system-arm qemu-efi-aarch64)

sudo=()
((EUID == 0)) || sudo=(sudo)
missing=()
for p in "${pkgs[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
done
if ((${#missing[@]})); then
  "${sudo[@]}" apt-get update -qq
  DEBIAN_FRONTEND=noninteractive "${sudo[@]}" apt-get install -y -qq --no-install-recommends "${missing[@]}"
fi
qemu-system-"$(uname -m)" --version | head -1
if [[ -w /dev/kvm ]]; then
  echo "KVM: available"
else
  echo "KVM: not available here, VMs run in emulation (slow)"
fi
