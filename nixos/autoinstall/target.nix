# The system to install. Replace it with your own configuration.
{ modulesPath, ... }:
{
  # Drivers for a QEMU VM. On real hardware, use the hardware-configuration.nix that
  # nixos-generate-config writes, or nixos-facter.
  imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # A serial console too, so the test can watch the VM boot.
  boot.kernelParams = [ "console=ttyS0,115200" "console=ttyAMA0,115200" "console=tty0" ];

  networking.hostName = "autoinstalled";

  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyReplaceMe your.name@example.com"
  ];

  system.stateVersion = "26.05";
}
