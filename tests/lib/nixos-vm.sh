# shellcheck shell=bash
# NixOS VM tests, for what a container cannot show: the kernel, the initrd, boot.
# Use them from a test with `# env: nix`. The test module is a runNixOSTest module
# ({ name; nodes; testScript; }). Its nodes get `notes`, as in tests/nixos/notes.nix.
#
#   nixos_vm_check DESC NOTE TEST.nix
#       build the VM test, which runs it in QEMU. A check: passes when the test passes.
#       Without /dev/kvm it is skipped: QEMU without KVM is too slow to be useful.
#       TEST.nix is relative to the calling test's folder.

nixos_vm_check() {
  local desc=$1 note=${2%.md} test
  test=$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)/$3
  if [[ ! -w /dev/kvm ]]; then
    skip "$desc" "no /dev/kvm here; NixOS VM tests run where KVM is available (CI)"
    return 0
  fi
  check "$desc" nix build --impure --no-link --print-build-logs \
    --option system-features "nixos-test benchmark big-parallel kvm" --expr \
    "(builtins.getFlake \"path:/repo/tests/nixos\").lib.vmTest { test = $test; note = \"$note\"; }"
}
