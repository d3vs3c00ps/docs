#!/usr/bin/env bash
# note: linux/distributions/nixos/testing.md
# env: nixos
# timeout: 2400
# A flake with the note's blocks, locked to the pinned nixpkgs. VMs are built, not
# booted: that needs KVM, which only CI has.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/nixos.sh"

NOTE=linux/distributions/nixos/testing
SYS=$(uname -m)-linux
NIXPKGS=$(nix eval --impure --raw --expr '(builtins.getFlake "path:/repo/tests/nixos").inputs.nixpkgs.outPath')
cd "$(mktemp -d)"

mkdir -p modules
cat >modules/hardening.nix <<'EOF'
{ services.openssh.settings.PasswordAuthentication = false; }
EOF
cat >host.nix <<'EOF'
{
  boot.loader.grub.device = "nodev";
  fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
  users.users.alice = { isNormalUser = true; extraGroups = [ "wheel" ]; };
  system.stateVersion = "26.05";
}
EOF
note_block "$NOTE" "Throwaway VMs" 2 >vm-variant.nix
sed -i '1s/^/{\n/; $s/$/\n}/' vm-variant.nix
cat >flake.nix <<EOF
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  outputs = { self, nixpkgs }: {
    nixosConfigurations.workstation = nixpkgs.lib.nixosSystem {
      system = "$SYS";
      modules = [ ./host.nix ./vm-variant.nix { networking.hostName = "workstation"; } ];
    };
    nixosConfigurations.web-01 = nixpkgs.lib.nixosSystem {
      system = "$SYS";
      modules = [ ./host.nix { networking.hostName = "web-01"; } ];
    };
$(note_block "$NOTE" "Automated tests with" 1 | sed "s/x86_64-linux/$SYS/g")
  };
}
EOF
git init -q && git add -A
nix flake lock --override-input nixpkgs "path:$NIXPKGS" 2>/dev/null
git add flake.lock

section "The test ladder"
check "nix flake check --no-build evaluates every output" nix flake check --no-build
check "nixos-rebuild build --flake .#host" nixos-rebuild build --flake .#web-01
check_output "nixos-rebuild dry-activate --flake .#host says what would change" 'would' \
  bash -c 'nixos-rebuild dry-activate --flake .#web-01 2>&1'

section "Throwaway VMs with build-vm"
rm -f result
check "nixos-rebuild build-vm (from the note)" bash -ec "$(note_block "$NOTE" "Throwaway VMs" 1 | sed -n 1p)"
assert_file "it gives the run script the note names" result/bin/run-workstation-vm
run=$(cat result/bin/run-workstation-vm)
assert_match "the VM's disk is workstation.qcow2 in the current directory" 'workstation\.qcow2' "$run"
assert_match "vmVariant: memorySize 4096" '-m 4096' "$run"
assert_match "vmVariant: 4 cores" '-smp 4' "$run"
assert_match "the host's /nix/store is shared, not copied" 'nix-store|/nix/store' "$run"
ev() { nix eval --json ".#nixosConfigurations.workstation.config.$1"; }
check_output "the defaults are 1024 MiB and 1 core" '^\[1024,1\]$' \
  nix eval --json --impure --expr "let c = (builtins.getFlake \"path:/repo/tests/nixos\").lib.system { container = false; }; in [ c.config.virtualisation.vmVariant.virtualisation.memorySize c.config.virtualisation.vmVariant.virtualisation.cores ]"
check_output "alice's test password is set in the VM" '^"test"$' ev virtualisation.vmVariant.users.users.alice.initialPassword
check_output "and not on the real machine" '^null$' ev users.users.alice.initialPassword
check_output "the real machine has no virtualisation.memorySize at all" '^false$' \
  nix eval --impure --expr "(builtins.getFlake \"git+file://$PWD\").nixosConfigurations.workstation.config.virtualisation ? memorySize"
check_output "vmVariantWithBootLoader exists" '^true$' \
  nix eval --impure --expr "(builtins.getFlake \"git+file://$PWD\").nixosConfigurations.workstation.config.virtualisation ? vmVariantWithBootLoader"
skip "./result/bin/run-workstation-vm" "booting a VM needs KVM; QEMU without it is too slow here"

section "Automated tests with runNixOSTest"
check_output "the check evaluates (nix flake check runs it)" '\.drv"$' nix eval --json ".#checks.$SYS.ssh.drvPath"
check_output "driverInteractive can be started with nix run" '^"nixos-test-driver"$' nix eval --json ".#checks.$SYS.ssh.driverInteractive.meta.mainProgram"
if [[ -w /dev/kvm ]]; then
  check "nix build .#checks.<system>.ssh -L runs the VM test (from the note)" nix build ".#checks.$SYS.ssh" -L --no-link
else
  skip "nix build .#checks.<system>.ssh -L runs the VM test" "no /dev/kvm here; NixOS VM tests run where KVM is available (CI)"
fi

section "Building images"
out=$(bash -c "$(note_block "$NOTE" "Building images" 1 | sed -n 1p | sed 's/[[:space:]]*#.*$//')" 2>&1 || true)
for v in qemu-efi qemu iso iso-installer raw-efi proxmox vmware virtualbox hyperv amazon google-compute azure oci; do
  assert_match "build-image without a variant lists $v" "^- $v\$" "$out"
done
assert_no_match "there is no qcow2 variant" '^- qcow2$' "$out"
check_output "the flake output for CI evaluates (from the note)" '\.drv"$' \
  nix eval --json "$(note_block "$NOTE" "Building images" 2 | awk '{print $3}').drvPath"
skip "building the qemu-efi and iso images" "make-disk-image boots a VM to build the disk: needs KVM"
