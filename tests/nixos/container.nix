# A NixOS system that boots in Docker, with systemd as PID 1.
# The profile turns off what cannot work in a container, like the firewall and audit:
# a test that needs one back uses lib.mkForce.
{ modulesPath, nixpkgsSource, ... }:
{
  imports = [ "${modulesPath}/virtualisation/docker-image.nix" ];

  # Docker bind-mounts /etc/resolv.conf, so resolvconf can only fail.
  networking.resolvconf.enable = false;

  # The pinned nixpkgs, so tests can evaluate the flake inside the container offline.
  system.extraDependencies = [ nixpkgsSource ];
}
