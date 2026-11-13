#!/usr/bin/env bash
# Build the unattended NixOS installer ISO from nixos/autoinstall, and test it in QEMU.
#
# Usage: scripts/nixos-iso.sh build [SYSTEM]   write dist/nixos-autoinstall-SYSTEM.iso
#        scripts/nixos-iso.sh test  [SYSTEM]   build, install into an empty VM disk,
#                                              boot the result, check the login prompt,
#                                              then check the ISO refuses that disk now
#   SYSTEM: x86_64-linux or aarch64-linux (default: this machine's). Building for the
#   other architecture needs CPU emulation in the build, which this script does not set
#   up: build an x86_64 ISO on an x86_64 machine or in CI.
#
# Builds run in the nix image with the notes-nix-store volume (tests/lib/nix-store.sh),
# so no Nix is needed here. The test needs QEMU: scripts/install-vm-tools.sh. Without
# KVM, or for the other architecture, QEMU emulates the CPU: the test then takes
# 20 minutes or more instead of 3.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export NOTES_ROOT=$ROOT
# shellcheck source=../tests/lib/nix-store.sh
source "$ROOT/tests/lib/nix-store.sh"

cmd=${1:-}
system=${2:-$(uname -m)-linux}
[[ $system == x86_64-linux || $system == aarch64-linux ]] || { echo "unknown system: $system" >&2; exit 1; }
DIST=$ROOT/dist
ISO=$DIST/nixos-autoinstall-$system.iso

build() {
  [[ $system == "$(uname -m)-linux" ]] || { echo "can only build for $(uname -m)-linux here" >&2; exit 1; }
  ensure_nix_store "$ROOT"
  local out
  out=$(in_nix nix build --no-link --print-out-paths "path:/repo/nixos/autoinstall#packages.$system.iso")
  mkdir -p "$DIST"
  in_nix sh -c "cat $out/iso/*.iso" >"$ISO.part"
  mv "$ISO.part" "$ISO"
  echo "$ISO ($(du -h "$ISO" | cut -f1))"
}

# vm DISK [ISO]: boot a VM on DISK, with ISO attached after it, serial on stdout.
vm() {
  local arch=${system%-linux} kvm=() fw vars
  [[ -w /dev/kvm && $arch == "$(uname -m)" ]] && kvm=(-enable-kvm -cpu host)
  if [[ $arch == aarch64 ]]; then
    fw=/usr/share/AAVMF/AAVMF_CODE.fd vars=/usr/share/AAVMF/AAVMF_VARS.fd
    set -- -M virt -cpu max "${kvm[@]}" "$@"
  else
    fw=/usr/share/OVMF/OVMF_CODE.fd vars=/usr/share/OVMF/OVMF_VARS.fd
    set -- -M q35 "${kvm[@]}" "$@"
  fi
  # The UEFI variables live next to the disk, so the boot entry the install writes
  # is still there when the installed system boots.
  [[ -f $WORK/vars.fd ]] || cp "$vars" "$WORK/vars.fd"
  # exec: the caller's $! is then QEMU itself, so kill stops the VM.
  exec "qemu-system-$arch" "$@" -m 2048 -smp 4 -nographic -no-reboot \
    -drive "if=pflash,format=raw,readonly=on,file=$fw" -drive "if=pflash,format=raw,file=$WORK/vars.fd"
}

# watch LOG PATTERN SECONDS PID: wait for PATTERN in LOG while the VM runs. Gives up
# early when the installer reports a failure.
watch() {
  local i
  for ((i = 0; i < $3; i++)); do
    grep -q -- "$2" "$1" && return 0
    grep -q 'autoinstall: FAILED' "$1" && return 1
    kill -0 "$4" 2>/dev/null || { grep -q -- "$2" "$1"; return; }
    sleep 1
  done
  return 1
}

test_iso() {
  command -v "qemu-system-${system%-linux}" >/dev/null || { echo "no QEMU: run scripts/install-vm-tools.sh" >&2; exit 1; }
  [[ -f $ISO ]] || build
  WORK=$(mktemp -d)
  # || true: under set -e a failing kill (the VM already gone) would skip the rm.
  trap 'kill "${pid:-}" 2>/dev/null || true; rm -rf "$WORK"' EXIT
  local slow=1
  [[ -w /dev/kvm && ${system%-linux} == "$(uname -m)" ]] && slow=0
  local limit=$((slow ? 3600 : 600))
  qemu-img create -q -f qcow2 "$WORK/disk.qcow2" 8G
  # The disk must be /dev/vda, as disk.nix says, and the ISO must boot even once the
  # install has put the disk first in the firmware's boot order. Fixed PCI addresses
  # give the naming, bootindex the boot choice.
  local with_iso=(
    -drive "file=$WORK/disk.qcow2,if=none,id=hd" -device "virtio-blk-pci,drive=hd,addr=0x4"
    -drive "file=$ISO,if=none,id=iso,format=raw,readonly=on" -device "virtio-blk-pci,drive=iso,addr=0x5,bootindex=0"
  )

  echo "1/3 installing from the ISO (up to $((limit / 60)) minutes)"
  vm "${with_iso[@]}" >"$WORK/install.log" 2>&1 &
  pid=$!
  if ! watch "$WORK/install.log" 'autoinstall: done' "$limit" "$pid"; then
    echo "FAIL: the install did not finish. Last lines:" >&2
    tail -30 "$WORK/install.log" >&2
    exit 1
  fi
  wait "$pid" || true   # it powers itself off
  grep 'autoinstall:' "$WORK/install.log" | tr -d '\r'

  echo "2/3 booting the installed disk, without the ISO"
  vm -drive "file=$WORK/disk.qcow2,if=virtio" >"$WORK/boot.log" 2>&1 &
  pid=$!
  if ! watch "$WORK/boot.log" 'autoinstalled login:' "$limit" "$pid"; then
    echo "FAIL: the installed system did not reach a login prompt. Last lines:" >&2
    tail -30 "$WORK/boot.log" >&2
    exit 1
  fi
  kill "$pid"; wait "$pid" 2>/dev/null || true

  echo "3/3 booting the ISO again: the disk is not empty now"
  local sum
  sum=$(qemu-img info -U "$WORK/disk.qcow2" --output=json | grep -o '"actual-size": [0-9]*')
  vm "${with_iso[@]}" >"$WORK/again.log" 2>&1 &
  pid=$!
  if ! watch "$WORK/again.log" 'is not empty. Nothing was changed' "$limit" "$pid"; then
    echo "FAIL: the ISO did not refuse a non-empty disk. Last lines:" >&2
    tail -30 "$WORK/again.log" >&2
    exit 1
  fi
  kill "$pid"; wait "$pid" 2>/dev/null || true
  [[ $(qemu-img info -U "$WORK/disk.qcow2" --output=json | grep -o '"actual-size": [0-9]*') == "$sum" ]] ||
    { echo "FAIL: the disk changed" >&2; exit 1; }
  echo "PASS: the ISO installed NixOS unattended, it boots, and it leaves a used disk alone"
}

case $cmd in
  build) build ;;
  test) test_iso ;;
  *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
