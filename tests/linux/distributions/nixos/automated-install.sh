#!/usr/bin/env bash
# note: linux/distributions/nixos/automated-install.md
# env: nix
# timeout: 1200
# The files and what they evaluate to. The install itself, in a VM, is
# `scripts/nixos-iso.sh test` (CI runs it where KVM is available).
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/distributions/nixos/automated-install
F=path:$NOTES_ROOT/nixos/autoinstall
SYS=$(nix eval --impure --raw --expr builtins.currentSystem)
ev() { nix eval --raw "$F#nixosConfigurations.target-$SYS.config.$1"; }
iso() { nix eval --raw --impure --expr "(builtins.getFlake \"$F\").packages.$SYS.iso.$1"; }

section "The files"
for f in flake.nix disk.nix target.nix installer.nix; do
  assert_eq "the note shows nixos/autoinstall/$f as it is" "$(cat "$NOTES_ROOT/nixos/autoinstall/$f")" "$(note_block "$NOTE" "### $f" 1)"
done

section "What they evaluate to"
check_output "the target is autoinstalled" '^autoinstalled$' ev networking.hostName
check_output "on the disk named in disk.nix" '^/dev/vda$' ev disko.devices.disk.main.device
check_output "with an EFI system partition on /boot" '^/boot$' ev fileSystems."/boot".mountPoint
check_output "systemd-boot is the boot loader" '^true$' nix eval "$F#nixosConfigurations.target-$SYS.config.boot.loader.systemd-boot.enable"
check_output "disko generates formatMount" '/nix/store/.*-disko-format-mount' ev system.build.formatMount
check_output "the ISO evaluates" '\.drv$' iso drvPath
script=$(nix eval --raw --impure --expr "let f = builtins.getFlake \"$F\"; in (f.inputs.nixpkgs.lib.nixosSystem {
  system = \"$SYS\"; specialArgs.target = f.nixosConfigurations.target-$SYS;
  modules = [ $NOTES_ROOT/nixos/autoinstall/installer.nix ]; }).config.systemd.services.autoinstall.script")
assert_match "the service stops on a non-empty disk by default (wipe = false)" 'is not empty\. Nothing was changed' "$script"
assert_match "and checks the disk exists" 'does not exist\. Nothing was changed' "$script"
assert_match "waits 30 seconds first" 'sleep 30' "$script"
assert_match "runs disko's format-and-mount script, not its directory" '/nix/store/[^ ]*-disko-format-mount/bin/disko-format-mount' "$script"
assert_match "installs from the ISO's store, with no channel copy" 'nixos-install --root /mnt --system /nix/store/[^ ]*-nixos-system-autoinstalled-[^ ]* --no-root-passwd --no-channel-copy' "$script"
assert_match "and powers off" 'systemctl poweroff' "$script"
assert_match "a failure is reported on the consoles, with the log" 'FAILED \(exit \$rc\)\. Last lines of journalctl -u autoinstall' "$script"
path=$(nix eval --raw --impure --expr "let f = builtins.getFlake \"$F\"; in toString (f.inputs.nixpkgs.lib.nixosSystem {
  system = \"$SYS\"; specialArgs.target = f.nixosConfigurations.target-$SYS;
  modules = [ $NOTES_ROOT/nixos/autoinstall/installer.nix ]; }).config.systemd.services.autoinstall.path")
assert_match "nix is on the service's PATH (nixos-install runs nix-env)" '/nix/store/[^ ]*-nix-2\.' "$path"
assert_match "the disk is checked by reading it (wipefs), not through udev (lsblk)" 'wipefs --noheadings /dev/vda' "$script"
assert_no_match "wipe = false: nothing wipes the disk" 'wipefs -a' "$script"

section "Build and test"
head -c 5000000 /dev/urandom >fake.iso
cmd=$(note_block "$NOTE" 'Build and test' 2 | sed 's/^sudo //; s|dist/nixos-autoinstall-x86_64-linux.iso|fake.iso|; s|/dev/sdX|stick.img|')
check "the dd command (to a file instead of a stick)" bash -ec "$cmd"
check "writes the ISO byte for byte" cmp fake.iso stick.img
