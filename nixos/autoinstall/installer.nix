# The installer ISO. It carries the finished target system, so the install needs no
# network, and a service that installs it at boot:
#   1. stop if the disk is missing, or not empty (unless wipe = true)
#   2. wait 30 seconds, with a warning on the console
#   3. partition and format with disko, then nixos-install the target
#   4. power off, so the machine does not boot the installer again
{ config, lib, pkgs, modulesPath, target, ... }:
let
  wipe = false;           # true: also install over a disk that has partitions
  delay = 30;             # seconds to power off before the disk is touched
  disk = target.config.disko.devices.disk.main.device;
  system = target.config.system.build.toplevel;
  formatMount = "${target.config.system.build.formatMount}/bin/disko-format-mount";
in
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  isoImage.storeContents = [ system target.config.system.build.formatMount ];
  boot.kernelParams = [ "console=ttyS0,115200" "console=ttyAMA0,115200" "console=tty0" ];

  systemd.services.autoinstall = {
    description = "Install NixOS on ${disk}, with no questions";
    wantedBy = [ "multi-user.target" ];
    path = [ config.system.build.nixos-install config.nix.package pkgs.util-linux pkgs.gptfdisk pkgs.systemd ];
    serviceConfig.Type = "oneshot";
    script = ''
      # /dev/console is only the last console= of the kernel line. Tell every one of
      # them, so the messages show on a screen and on a serial line alike.
      say() {
        echo "autoinstall: $*"
        for c in $(cat /sys/class/tty/console/active); do echo "autoinstall: $*" >"/dev/$c"; done
      }
      # Any failure: say so, with the end of the log, where someone can see it.
      trap 'rc=$?; [ $rc = 0 ] || { say "FAILED (exit $rc). Last lines of journalctl -u autoinstall:";
        journalctl -u autoinstall -n 15 -o cat --no-pager | while read -r l; do say "  $l"; done; }' EXIT
      if [ ! -b ${disk} ]; then
        say "${disk} does not exist. Nothing was changed."; exit 1
      fi
      # wipefs lists partition tables and file systems by reading the disk itself.
      # Not lsblk: it asks udev, which may not have probed the disk this early in boot.
      if [ -n "$(wipefs --noheadings ${disk})" ]; then
        if ${lib.boolToString wipe}; then
          say "${disk} has partitions. wipe = true: they will be destroyed."
        else
          say "${disk} is not empty. Nothing was changed. Set wipe = true to install over it."
          exit 1
        fi
      fi
      say "installing NixOS on ${disk} in ${toString delay} seconds. ALL DATA ON IT WILL BE LOST."
      say "power off now to stop."
      sleep ${toString delay}
      ${lib.optionalString wipe "wipefs -a ${disk}; sgdisk --zap-all ${disk}"}
      ${formatMount}
      nixos-install --root /mnt --system ${system} --no-root-passwd --no-channel-copy
      say "done. Powering off: remove the installer medium before the next boot."
      systemctl poweroff
    '';
  };
}
