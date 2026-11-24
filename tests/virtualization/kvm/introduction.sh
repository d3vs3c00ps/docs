#!/usr/bin/env bash
# note: virtualization/kvm/introduction.md
# env: leap-systemd
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=virtualization/kvm/introduction
cd "$(mktemp -d)"
# libvirt-daemon-qemu pulls the QEMU for this machine's architecture.
zypper -n -q install --no-recommends libvirt-daemon-qemu libvirt-client virt-install qemu-x86 qemu-seabios >/dev/null
for d in qemu network storage; do systemctl start "virt${d}d.socket"; done
native=qemu-system-$(uname -m)

section "Checking you can use it"
count=$(bash -c "$(note_block "$NOTE" 'Checking you can use it' 1 | sed -n 1p)" || true)
assert_match "grep -cE 'vmx|svm' prints a count (from the note)" '^[0-9]+$' "$count"
check "lscpu runs (from the note)" bash -c "$(note_block "$NOTE" 'Checking you can use it' 1 | sed -n 2p) || true"
if [[ $(uname -m) == aarch64 ]]; then
  assert_eq "an ARM64 CPU has neither flag" 0 "$count"
else
  skip "an ARM64 CPU has neither flag" "this host is $(uname -m)"
fi
check_output "systemd's udev rules give /dev/kvm mode 0666" 'KERNEL=="kvm".*MODE="0666"' \
  cat /usr/lib/udev/rules.d/50-udev-default.rules
check_output "virt-host-validate checks /dev/kvm (from the note)" "Checking if device '/dev/kvm' exists" \
  bash -c "$(note_block "$NOTE" 'Checking you can use it' 3) 2>&1; true"
check_output "and cgroups, not only the CPU" "cgroup 'memory' controller" bash -c 'virt-host-validate 2>&1; true'
if [[ -e /sys/module/kvm_intel || -e /sys/module/kvm_amd ]]; then
  check_output "the nested parameter reads Y, N, 1 or 0 (from the note)" '^(Y|N|1|0)$' \
    bash -c "$(note_block "$NOTE" 'Nested virtualisation' 1) 2>/dev/null; true"
else
  skip "the nested parameter (from the note)" "no kvm_intel or kvm_amd module in this kernel"
fi

section "Without /dev/kvm (the correction)"
if [[ -e /dev/kvm ]]; then
  skip "what each tool does without /dev/kvm" "this host has /dev/kvm"
else
  out=$(virt-install --print-xml --name n --memory 256 --osinfo generic --arch x86_64 --import --disk none --graphics none 2>&1)
  assert_match "virt-install writes <domain type=\"qemu\">" '<domain type="qemu"' "$out"
  # --print-xml hides warnings; --dry-run shows what an install prints.
  dry() { virt-install --dry-run --noautoconsole --name n --memory 256 --osinfo generic --import --disk none --graphics none "$@" 2>&1; }
  assert_match "for an x86 guest, with a one-line warning" "WARNING +KVM acceleration not available, using 'qemu'" "$(dry --arch x86_64)"
  if [[ $(uname -m) != x86_64 ]]; then
    out=$(virt-install --print-xml --name n --memory 256 --osinfo generic --import --disk none --graphics none 2>&1)
    assert_match "for a $(uname -m) guest, also type qemu" '<domain type="qemu"' "$out"
    assert_no_match "with no warning about KVM" 'KVM' "$(dry)"
  fi
  check_output "a bare QEMU with no -accel uses TCG" 'kvm support: disabled' \
    bash -c "printf 'info kvm\nquit\n' | $native -M none -nodefaults -display none -monitor stdio -S 2>&1"
  check_fails "QEMU with -accel kvm fails" timeout 20 "$native" -accel kvm -M none -nodefaults -display none -S
  cat >kvm.xml <<'EOF'
<domain type='kvm'>
  <name>needs-kvm</name>
  <memory unit='MiB'>128</memory>
  <os><type>hvm</type></os>
</domain>
EOF
  check_output "a type='kvm' libvirt domain is refused, naming type kvm" "type[= ]'?kvm" \
    bash -c 'virsh define kvm.xml 2>&1; true'
fi
