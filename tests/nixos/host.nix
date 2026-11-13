# A stand-in for a real machine, for evaluation only: never built into an image.
# Tests use it to check what a note's configuration does on a normal host, where
# the container profile would change the answer (firewall, audit, kernel).
{
  boot.loader.grub.device = "nodev";
  fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
}
